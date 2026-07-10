#!/usr/bin/env bash
# wa_site.sh - run a webarena-verified site rootlessly on Hopper.
#
# Usage: ./wa_site.sh {shopping|shopping_admin|reddit|gitlab|map} <command>
#
# Commands:
#   start    Start the site (foreground; use tmux / srun / sbatch to keep alive)
#   stop     Kill the site's processes
#   reset    stop + restore seed state + start   (fresh env between runs)
#   smoke    Start, verify HTTP responds, then shut down
#   status   Show paths, URL, and port listen state
#
# Runs the SIF if present ($WA_IMAGE_DIR/<site>_verified_rootless.sif),
# otherwise the patched sandbox directly. No --fakeroot: everything runs as
# your uid, which is what the 02_patch_sandbox.sh changes are designed for.
#
# Placement notes:
#   - gitlab's puma listens on 127.0.0.1:8080 and map's apache uses internal
#     8080 (baked into rails assets) — do NOT run gitlab and map on one node.
#   - map also needs internal 3000, 5000-5002, 5432-5434 free, plus the data
#     from 05_fetch_map_data.sh. Give it its own node if you can.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=wa_common.sh
source "$SCRIPT_DIR/wa_common.sh"

SITE="${1:-}"
CMD="${2:-}"
wa_check_site "$SITE"
wa_ensure_dirs

KIND="$(wa_site_kind "$SITE")"
SANDBOX="$(wa_sandbox "$SITE")"
SIF="$(wa_sif "$SITE")"
STATE="$WA_STATE_DIR/$SITE"
RUN="$WA_RUN_DIR/$SITE"
LOGS="$WA_LOG_DIR/$SITE"

HTTP_PORT="$(wa_site_var "$SITE" HTTP_PORT)"
HEALTH_PATH="$(wa_health_path "$SITE")"
HEALTH_TIMEOUT="$(wa_health_timeout "$SITE")"
SITE_URL="$(wa_site_url "$SITE")"

case "$KIND" in
  magento) ENTRY="$SCRIPT_DIR/container/wa_magento_entry.sh" ;;
  reddit) ENTRY="$SCRIPT_DIR/container/wa_reddit_entry.sh" ;;
  gitlab) ENTRY="$SCRIPT_DIR/container/wa_gitlab_entry.sh" ;;
  map) ENTRY="$SCRIPT_DIR/container/wa_map_entry.sh" ;;
esac
ENTRY_BASENAME="$(basename "$ENTRY")"

runtime_image() {
  if [ -f "$SIF" ]; then printf '%s' "$SIF"; else printf '%s' "$SANDBOX"; fi
}

port_in_use() { ss -ltn "( sport = :$1 )" 2>/dev/null | grep -q ":$1"; }

# Ports each site needs free on the node (external + internal TCP)
site_ports() {
  case "$KIND" in
    magento)
      printf '%s %s %s %s %s %s' \
        "$HTTP_PORT" \
        "$(wa_site_var "$SITE" MYSQL_PORT)" \
        "$(wa_site_var "$SITE" REDIS_PORT)" \
        "$(wa_site_var "$SITE" FPM_PORT)" \
        "$(wa_site_var "$SITE" MAIL_SMTP_PORT)" \
        "$(wa_site_var "$SITE" MAIL_HTTP_PORT)"
      if [ "$(wa_site_var "$SITE" WITH_ES)" = "1" ]; then
        printf ' %s %s' \
          "$(wa_site_var "$SITE" ES_HTTP_PORT)" \
          "$(wa_site_var "$SITE" ES_TRANSPORT_PORT)"
      fi
      ;;
    reddit) printf '%s %s %s' "$HTTP_PORT" "$REDDIT_PG_PORT" "$REDDIT_FPM_PORT" ;;
    gitlab) printf '%s 8080' "$HTTP_PORT" ;; # omnibus puma pins 127.0.0.1:8080
    map) printf '%s 8080 8085 3000 5000 5001 5002 5432 5433 5434' "$HTTP_PORT" ;;
  esac
}

check_ports_free() {
  local busy=0 p
  for p in $(site_ports); do
    if port_in_use "$p"; then
      echo "port already in use: $p" >&2
      busy=1
    fi
  done
  [ "$busy" -eq 0 ] || exit 1
}

state_ready() {
  case "$KIND" in
    magento) [ -d "$STATE/mysql/mysql" ] ;;
    reddit) [ -f "$STATE/.wa_pgdata_path" ] && [ -d "$STATE/pgdata" ] ;;
    gitlab) [ -d "$STATE/var-opt" ] ;;
    map) [ -d "$STATE/website-pg" ] ;;
  esac
}

# --- per-kind bind + env assembly --------------------------------------------
BINDS=()
ENVS=(
  --env "WA_SITE=$SITE"
  --env "WA_HOST=$WA_HOST"
  --env "WA_HTTP_PORT=$HTTP_PORT"
  --env "WA_RUN_SECONDS=${WA_RUN_SECONDS:-0}"
  --env "WA_SKIP_INIT=${WA_SKIP_INIT:-0}"
)

setup_magento() {
  mkdir -p "$RUN/mysqld" "$RUN/redis" "$RUN/nginx" "$RUN/webarena" "$RUN/tmp"
  BINDS+=(
    --bind "$LOGS:/var/log/webarena"
    --bind "$RUN/webarena:/run/webarena"
    --bind "$RUN/mysqld:/run/mysqld"
    --bind "$RUN/redis:/run/redis"
    --bind "$RUN/nginx:/run/nginx"
    --bind "$STATE/mysql:/var/lib/mysql"
    --bind "$STATE/nginx-lib:/var/lib/nginx"
    --bind "$STATE/magento-var:/var/www/magento2/var"
  )
  local with_es
  with_es="$(wa_site_var "$SITE" WITH_ES)"
  if [ "$with_es" = "1" ]; then
    BINDS+=(--bind "$STATE/es-data:/usr/share/java/elasticsearch/data")
  fi
  ENVS+=(
    --env "WA_MYSQL_PORT=$(wa_site_var "$SITE" MYSQL_PORT)"
    --env "WA_REDIS_PORT=$(wa_site_var "$SITE" REDIS_PORT)"
    --env "WA_FPM_PORT=$(wa_site_var "$SITE" FPM_PORT)"
    --env "WA_MAIL_SMTP_PORT=$(wa_site_var "$SITE" MAIL_SMTP_PORT)"
    --env "WA_MAIL_HTTP_PORT=$(wa_site_var "$SITE" MAIL_HTTP_PORT)"
    --env "WA_ES_HTTP_PORT=$(wa_site_var "$SITE" ES_HTTP_PORT)"
    --env "WA_ES_TRANSPORT_PORT=$(wa_site_var "$SITE" ES_TRANSPORT_PORT)"
    --env "WA_WITH_ES=$with_es"
    --env "ES_JAVA_OPTS=$WA_ES_JAVA_OPTS"
  )
}

setup_reddit() {
  mkdir -p "$RUN/webarena" "$RUN/postgresql" "$RUN/nginx"
  local pgdata_path
  pgdata_path="$(cat "$STATE/.wa_pgdata_path")"
  BINDS+=(
    --bind "$LOGS:/var/log/webarena"
    --bind "$RUN/webarena:/run/webarena"
    --bind "$RUN/postgresql:/run/postgresql"
    --bind "$RUN/nginx:/run/nginx"
    --bind "$STATE/pgdata:$pgdata_path"
    --bind "$STATE/nginx-log:/var/log/nginx"
    --bind "$STATE/app-var:/var/www/html/var"
    --bind "$STATE/dot-env/.env:/var/www/html/.env"
  )
  # nginx-lib only exists if the image had /var/lib/nginx
  if [ -d "$STATE/nginx-lib" ]; then
    BINDS+=(--bind "$STATE/nginx-lib:/var/lib/nginx")
  fi
  ENVS+=(
    --env "WA_PG_PORT=$REDDIT_PG_PORT"
    --env "WA_FPM_PORT=$REDDIT_FPM_PORT"
    --env "WA_PGDATA=$pgdata_path"
  )
}

setup_gitlab() {
  mkdir -p "$RUN/webarena"
  BINDS+=(
    --bind "$LOGS:/var/log/webarena"
    --bind "$RUN/webarena:/run/webarena"
    --bind "$STATE/etc-gitlab:/etc/gitlab"
    --bind "$STATE/var-opt:/var/opt/gitlab"
    --bind "$STATE/gitlab-log:/var/log/gitlab"
  )
}

setup_map() {
  mkdir -p "$RUN/webarena" "$RUN/postgresql" "$RUN/renderd" "$RUN/apache2"
  # sanity: external data must be present (05_fetch_map_data.sh)
  if [ ! -d "$WA_MAP_DATA_DIR/tile-db" ]; then
    echo "[site] WARNING: $WA_MAP_DATA_DIR/tile-db missing — tiles/geocoding" >&2
    echo "[site]          will be disabled. Run 05_fetch_map_data.sh first." >&2
  fi
  BINDS+=(
    --bind "$LOGS:/var/log/webarena"
    --bind "$RUN/webarena:/run/webarena"
    --bind "$RUN/postgresql:/run/postgresql"
    --bind "$RUN/renderd:/run/renderd"
    --bind "$RUN/apache2:/run/apache2"
    --bind "$STATE/website-pg:/var/lib/postgresql/14/main"
    --bind "$STATE/app-log:/app/log"
    --bind "$STATE/app-tmp:/app/tmp"
    --bind "$STATE/apache-log:/var/log/apache2"
    --bind "$STATE/tiles:/data/tiles"
    --bind "$STATE/renderd-cache:/var/cache/renderd"
    --bind "$STATE/style:/data/style"
    --bind "$STATE/nominatim:/nominatim"
  )
  # NB: if-form, not '[ ] &&' — a false test as a function's last statement
  # makes the function return nonzero, which set -e turns into a silent exit.
  if [ -d "$WA_MAP_DATA_DIR/tile-db" ]; then
    BINDS+=(--bind "$WA_MAP_DATA_DIR/tile-db:/data/database")
  fi
  local prof
  for prof in car bike foot; do
    if [ -d "$WA_MAP_DATA_DIR/routing/$prof" ]; then
      BINDS+=(--bind "$WA_MAP_DATA_DIR/routing/$prof:/data/routing/$prof:ro")
    fi
  done
  if [ -d "$WA_MAP_DATA_DIR/nominatim-db" ]; then
    BINDS+=(--bind "$WA_MAP_DATA_DIR/nominatim-db:/data/nominatim/postgres")
  fi
  if [ -d "$WA_MAP_DATA_DIR/nominatim-flatnode" ]; then
    BINDS+=(--bind "$WA_MAP_DATA_DIR/nominatim-flatnode:/data/nominatim/flatnode")
  fi
}

cmd_start() {
  [ -e "$(runtime_image)" ] || {
    echo "no SIF or sandbox for $SITE" >&2
    exit 1
  }
  [ -f "$ENTRY" ] || {
    echo "missing entry script: $ENTRY" >&2
    exit 1
  }
  if ! state_ready; then
    "$SCRIPT_DIR/03_prepare_state.sh" restore "$SITE"
  fi
  mkdir -p "$RUN" "$LOGS"
  "setup_$KIND"
  chmod -R u+rwX "$STATE" "$RUN" "$LOGS" 2>/dev/null || true
  # postgres insists on 0700 data dirs
  if [ -d "$STATE/pgdata" ]; then chmod 700 "$STATE/pgdata"; fi
  if [ -d "$STATE/website-pg" ]; then chmod 700 "$STATE/website-pg"; fi
  check_ports_free

  BINDS+=(--bind "$ENTRY:/$ENTRY_BASENAME:ro")

  wa_require_apptainer || exit 1
  echo "[site] starting $SITE ($KIND) -> $SITE_URL ($($WA_APPTAINER --version 2>/dev/null))"
  exec "$WA_APPTAINER" exec \
    --cleanenv \
    --writable-tmpfs \
    "${BINDS[@]}" \
    "${ENVS[@]}" \
    "$(runtime_image)" \
    /bin/sh "/$ENTRY_BASENAME"
}

cmd_stop() {
  local pid_file pid
  for pid_file in "$RUN/webarena"/*.pid; do
    [ -f "$pid_file" ] || continue
    pid="$(cat "$pid_file" 2>/dev/null || true)"
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  done
  pkill -f "$ENTRY_BASENAME" 2>/dev/null || true
  pkill -f "apptainer.* exec .*$(basename "$(runtime_image)")" 2>/dev/null || true
  sleep 1
  for pid_file in "$RUN/webarena"/*.pid; do
    [ -f "$pid_file" ] || continue
    pid="$(cat "$pid_file" 2>/dev/null || true)"
    [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null || true
  done
  rm -f "$RUN/webarena"/*.pid 2>/dev/null || true
  echo "[site] $SITE stopped"
}

cmd_reset() {
  cmd_stop
  rm -rf "$RUN"
  "$SCRIPT_DIR/03_prepare_state.sh" restore "$SITE"
  cmd_start
}

cmd_smoke() {
  local budget tries
  budget="$HEALTH_TIMEOUT"
  tries=$((budget / 5))
  (WA_RUN_SECONDS=$((budget + 60)) cmd_start) &
  local runner=$!
  local ok=0 i=0 code=""
  while [ "$i" -lt "$tries" ]; do
    # if our launcher already died (e.g. port-in-use abort), any HTTP answer
    # is from a FOREIGN listener — do not let it produce a false OK
    if ! kill -0 "$runner" 2>/dev/null; then
      echo "[smoke] launcher exited before the site came up" >&2
      break
    fi
    code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${HTTP_PORT}${HEALTH_PATH}" || true)"
    case "$code" in 200 | 302)
      # HTTP answering is necessary but not sufficient: the entry may still be
      # running init (magento's setup:store-config:set answered 302 mid-init).
      # Require the ready marker so we never tear down a half-configured site.
      if [ -f "$RUN/webarena/ready" ]; then
        ok=1
        break
      fi
      ;;
    esac
    i=$((i + 1))
    sleep 5
  done
  if [ "$ok" = "1" ]; then
    echo "[smoke] OK: http://127.0.0.1:${HTTP_PORT}${HEALTH_PATH} -> $code"
  else
    echo "[smoke] FAILED (last code: ${code:-none}); see $LOGS" >&2
  fi
  cmd_stop
  wait "$runner" 2>/dev/null || true
  [ "$ok" = "1" ]
}

cmd_status() {
  echo "site:     $SITE ($KIND)"
  echo "url:      $SITE_URL"
  echo "image:    $(runtime_image)"
  echo "state:    $STATE"
  echo "seed:     $WA_SEED_DIR/$SITE"
  echo "logs:     $LOGS"
  local p
  for p in $(site_ports); do
    port_in_use "$p" && echo "port_$p: listening" || echo "port_$p: not_listening"
  done
}

case "$CMD" in
  start) cmd_start ;;
  stop) cmd_stop ;;
  reset) cmd_reset ;;
  smoke) cmd_smoke ;;
  status) cmd_status ;;
  *)
    echo "usage: $0 {${WA_ALL_SITES// /|}} {start|stop|reset|smoke|status}" >&2
    exit 1
    ;;
esac
