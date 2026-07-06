#!/usr/bin/env bash
# wa_site.sh - run a webarena-verified site rootlessly on Hopper.
#
# Usage: ./wa_site.sh {shopping|shopping_admin} <command>
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

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=wa_common.sh
source "$SCRIPT_DIR/wa_common.sh"

SITE="${1:-}"
CMD="${2:-}"
wa_check_site "$SITE"
wa_ensure_dirs

SANDBOX="$(wa_sandbox "$SITE")"
SIF="$(wa_sif "$SITE")"
STATE="$WA_STATE_DIR/$SITE"
RUN="$WA_RUN_DIR/$SITE"
LOGS="$WA_LOG_DIR/$SITE"
ENTRY="$SCRIPT_DIR/container/wa_magento_entry.sh"

HTTP_PORT="$(wa_site_var "$SITE" HTTP_PORT)"
MYSQL_PORT="$(wa_site_var "$SITE" MYSQL_PORT)"
REDIS_PORT="$(wa_site_var "$SITE" REDIS_PORT)"
FPM_PORT="$(wa_site_var "$SITE" FPM_PORT)"
MAIL_SMTP_PORT="$(wa_site_var "$SITE" MAIL_SMTP_PORT)"
MAIL_HTTP_PORT="$(wa_site_var "$SITE" MAIL_HTTP_PORT)"
ES_HTTP_PORT="$(wa_site_var "$SITE" ES_HTTP_PORT)"
ES_TRANSPORT_PORT="$(wa_site_var "$SITE" ES_TRANSPORT_PORT)"
WITH_ES="$(wa_site_var "$SITE" WITH_ES)"

if [ "$SITE" = "shopping" ]; then
  HEALTH_PATH="/customer/account/login"
  SITE_URL="http://${WA_HOST}:${HTTP_PORT}"
else
  HEALTH_PATH="/admin"
  SITE_URL="http://${WA_HOST}:${HTTP_PORT}/admin"
fi

runtime_image() {
  if [ -f "$SIF" ]; then printf '%s' "$SIF"; else printf '%s' "$SANDBOX"; fi
}

port_in_use() { ss -ltn "( sport = :$1 )" 2>/dev/null | grep -q ":$1"; }

check_ports_free() {
  local busy=0 p
  for p in "$HTTP_PORT" "$MYSQL_PORT" "$REDIS_PORT" "$FPM_PORT" \
    "$MAIL_SMTP_PORT" "$MAIL_HTTP_PORT"; do
    if port_in_use "$p"; then
      echo "port already in use: $p" >&2
      busy=1
    fi
  done
  if [ "$WITH_ES" = "1" ]; then
    for p in "$ES_HTTP_PORT" "$ES_TRANSPORT_PORT"; do
      if port_in_use "$p"; then
        echo "port already in use: $p" >&2
        busy=1
      fi
    done
  fi
  [ "$busy" -eq 0 ] || exit 1
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
  if [ ! -d "$STATE/mysql/mysql" ]; then
    "$SCRIPT_DIR/03_prepare_state.sh" restore "$SITE"
  fi
  mkdir -p "$RUN/mysqld" "$RUN/redis" "$RUN/nginx" "$RUN/webarena" "$RUN/tmp" "$LOGS"
  chmod -R u+rwX "$STATE" "$RUN" "$LOGS"
  check_ports_free

  local binds=(
    --bind "$LOGS:/var/log/webarena"
    --bind "$RUN/webarena:/run/webarena"
    --bind "$RUN/mysqld:/run/mysqld"
    --bind "$RUN/redis:/run/redis"
    --bind "$RUN/nginx:/run/nginx"
    --bind "$STATE/mysql:/var/lib/mysql"
    --bind "$STATE/nginx-lib:/var/lib/nginx"
    --bind "$STATE/magento-var:/var/www/magento2/var"
    --bind "$ENTRY:/wa_magento_entry.sh:ro"
  )
  if [ "$WITH_ES" = "1" ]; then
    binds+=(--bind "$STATE/es-data:/usr/share/java/elasticsearch/data")
  fi

  echo "[site] starting $SITE -> $SITE_URL"
  exec apptainer exec \
    --cleanenv \
    --writable-tmpfs \
    "${binds[@]}" \
    --env "WA_SITE=$SITE" \
    --env "WA_HOST=$WA_HOST" \
    --env "WA_HTTP_PORT=$HTTP_PORT" \
    --env "WA_MYSQL_PORT=$MYSQL_PORT" \
    --env "WA_REDIS_PORT=$REDIS_PORT" \
    --env "WA_FPM_PORT=$FPM_PORT" \
    --env "WA_MAIL_SMTP_PORT=$MAIL_SMTP_PORT" \
    --env "WA_MAIL_HTTP_PORT=$MAIL_HTTP_PORT" \
    --env "WA_ES_HTTP_PORT=$ES_HTTP_PORT" \
    --env "WA_ES_TRANSPORT_PORT=$ES_TRANSPORT_PORT" \
    --env "WA_WITH_ES=$WITH_ES" \
    --env "ES_JAVA_OPTS=$WA_ES_JAVA_OPTS" \
    --env "WA_RUN_SECONDS=${WA_RUN_SECONDS:-0}" \
    --env "WA_SKIP_INIT=${WA_SKIP_INIT:-0}" \
    "$(runtime_image)" \
    /bin/sh /wa_magento_entry.sh
}

cmd_stop() {
  local pid_file pid
  for pid_file in "$RUN/webarena"/*.pid; do
    [ -f "$pid_file" ] || continue
    pid="$(cat "$pid_file" 2>/dev/null || true)"
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  done
  pkill -f "wa_magento_entry.sh" 2>/dev/null || true
  pkill -f "apptainer exec .*$(basename "$(runtime_image)")" 2>/dev/null || true
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
  (WA_RUN_SECONDS=30 cmd_start) &
  local runner=$!
  local ok=0 i=0
  while [ "$i" -lt 60 ]; do
    code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${HTTP_PORT}${HEALTH_PATH}" || true)"
    case "$code" in 200 | 302)
      ok=1
      break
      ;;
    esac
    i=$((i + 1))
    sleep 3
  done
  if [ "$ok" = "1" ]; then
    echo "[smoke] OK: http://127.0.0.1:${HTTP_PORT}${HEALTH_PATH} -> $code"
  else
    echo "[smoke] FAILED (last code: ${code:-none}); see $LOGS" >&2
  fi
  wait "$runner" 2>/dev/null || true
  cmd_stop
  [ "$ok" = "1" ]
}

cmd_status() {
  echo "site:     $SITE"
  echo "url:      $SITE_URL"
  echo "image:    $(runtime_image)"
  echo "state:    $STATE"
  echo "seed:     $WA_SEED_DIR/$SITE"
  echo "logs:     $LOGS"
  local p
  for p in "$HTTP_PORT" "$MYSQL_PORT" "$REDIS_PORT" "$FPM_PORT"; do
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
    echo "usage: $0 {shopping|shopping_admin} {start|stop|reset|smoke|status}" >&2
    exit 1
    ;;
esac
