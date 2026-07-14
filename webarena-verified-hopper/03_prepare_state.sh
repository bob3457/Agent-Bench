#!/usr/bin/env bash
# 03_prepare_state.sh - manage the writable state that gets bind-mounted over
# the read-only SIF at runtime.
#
# Per site the writable set differs (subdir -> in-container path; see
# wa_site.sh for the binds):
#   shopping / shopping_admin:
#     mysql        -> /var/lib/mysql
#     nginx-lib    -> /var/lib/nginx
#     magento-var  -> /var/www/magento2/var
#     es-data      -> /usr/share/java/elasticsearch/data   (shopping only)
#   reddit:
#     pgdata       -> <detected postgres data dir>  (path in sandbox/.wa_pgdata_path)
#     nginx-lib    -> /var/lib/nginx                (if present in image)
#     nginx-log    -> /var/log/nginx
#     app-var      -> /var/www/html/var
#     dot-env      -> /var/www/html/.env            (file bind; APP_SITE_NAME
#                                                    is rewritten per start)
#   gitlab:
#     etc-gitlab   -> /etc/gitlab
#     var-opt      -> /var/opt/gitlab               (repos + postgres + uploads;
#                                                    tens of GB — seed is big)
#     gitlab-log   -> /var/log/gitlab
#   map:
#     website-pg   -> /var/lib/postgresql/14/main
#     app-log      -> /app/log
#     app-tmp      -> /app/tmp
#     apache-log   -> /var/log/apache2
#     tiles        -> /data/tiles
#     renderd-cache-> /var/cache/renderd
#     style        -> /data/style
#     nominatim    -> /nominatim
#     (the big tile/nominatim/osrm data lives in $WA_MAP_DATA_DIR — see
#      05_fetch_map_data.sh — and is bound directly, not seeded)
#
# Commands:
#   prepare {site}   Extract writable state from the patched sandbox into
#                    $WA_STATE_DIR/{site} and snapshot it to $WA_SEED_DIR/{site}
#   restore {site}   Reset $WA_STATE_DIR/{site} from the seed (task reset)
#   seed    {site}   Re-snapshot the current live state as the new seed
#
# WA_SKIP_SEED=1 ./03_prepare_state.sh prepare gitlab   # skip the (huge) seed copy
#
# Usage: ./03_prepare_state.sh {prepare|restore|seed} {shopping|shopping_admin|reddit|gitlab|map}

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=wa_common.sh
source "$SCRIPT_DIR/wa_common.sh"

CMD="${1:-}"
SITE="${2:-}"
wa_check_site "$SITE"
wa_ensure_dirs

SANDBOX="$(wa_sandbox "$SITE")"
STATE="$WA_STATE_DIR/$SITE"
SEED="$WA_SEED_DIR/$SITE"
KIND="$(wa_site_kind "$SITE")"
WA_SKIP_SEED="${WA_SKIP_SEED:-0}"

copy_dir() { # copy_dir <src> <dst>
  rm -rf "$2"
  mkdir -p "$2"
  [ -d "$1" ] && cp -a --reflink=auto "$1"/. "$2"/ || true
}

sync_dir() { # sync_dir <src> <dst>
  if command -v rsync >/dev/null 2>&1; then
    mkdir -p "$2"
    rsync -a --delete "$1"/ "$2"/
  else
    copy_dir "$1" "$2"
  fi
}

sanitize_state() {
  case "$KIND" in
    magento | reddit)
      # Alpine nginx symlinks lib/nginx/{logs,tmp}; replace with real dirs so the
      # non-root process can write there.
      for p in logs tmp; do
        if [ -L "$STATE/nginx-lib/$p" ] || { [ -e "$STATE/nginx-lib/$p" ] && [ ! -d "$STATE/nginx-lib/$p" ]; }; then
          rm -f "$STATE/nginx-lib/$p"
        fi
      done
      mkdir -p "$STATE/nginx-lib/logs" "$STATE/nginx-lib/tmp/client_body"
      ;;
  esac
  case "$KIND" in
    reddit)
      [ -d "$STATE/pgdata" ] && chmod 700 "$STATE/pgdata"
      rm -f "$STATE/pgdata/postmaster.pid" 2>/dev/null || true
      mkdir -p "$STATE/nginx-log" "$STATE/app-var"
      ;;
    gitlab)
      [ -d "$STATE/var-opt/postgresql/data" ] && chmod 700 "$STATE/var-opt/postgresql/data"
      rm -f "$STATE/var-opt/postgresql/data/postmaster.pid" 2>/dev/null || true
      # stale runit/pid leftovers inside state
      find "$STATE/var-opt" -maxdepth 3 -name "*.pid" -delete 2>/dev/null || true
      ;;
    map)
      [ -d "$STATE/website-pg" ] && chmod 700 "$STATE/website-pg"
      rm -f "$STATE/website-pg/postmaster.pid" 2>/dev/null || true
      mkdir -p "$STATE/app-log" "$STATE/app-tmp" "$STATE/apache-log" \
        "$STATE/tiles" "$STATE/renderd-cache/tiles"
      ;;
  esac
  chmod -R u+rwX "$STATE"
}

extract_state() {
  case "$KIND" in
    magento)
      [ -d "$SANDBOX/var/lib/mysql/mysql" ] || {
        echo "sandbox missing MySQL data: $SANDBOX/var/lib/mysql" >&2
        exit 1
      }
      copy_dir "$SANDBOX/var/lib/mysql" "$STATE/mysql"
      copy_dir "$SANDBOX/var/lib/nginx" "$STATE/nginx-lib"
      copy_dir "$SANDBOX/var/www/magento2/var" "$STATE/magento-var"
      if [ "$(wa_site_var "$SITE" WITH_ES)" = "1" ]; then
        copy_dir "$SANDBOX/usr/share/java/elasticsearch/data" "$STATE/es-data"
      fi
      ;;
    reddit)
      [ -f "$SANDBOX/.wa_pgdata_path" ] || {
        echo "sandbox not patched (missing .wa_pgdata_path); run 02_patch_sandbox.sh first" >&2
        exit 1
      }
      local pgpath
      pgpath="$(cat "$SANDBOX/.wa_pgdata_path")"
      copy_dir "$SANDBOX$pgpath" "$STATE/pgdata"
      printf '%s\n' "$pgpath" >"$STATE/.wa_pgdata_path"
      [ -d "$SANDBOX/var/lib/nginx" ] && copy_dir "$SANDBOX/var/lib/nginx" "$STATE/nginx-lib" ||
        mkdir -p "$STATE/nginx-lib"
      copy_dir "$SANDBOX/var/www/html/var" "$STATE/app-var"
      mkdir -p "$STATE/nginx-log"
      rm -rf "$STATE/dot-env" && mkdir -p "$STATE/dot-env"
      cp "$SANDBOX/var/www/html/.env" "$STATE/dot-env/.env"
      ;;
    gitlab)
      [ -d "$SANDBOX/var/opt/gitlab/postgresql/data" ] || {
        echo "sandbox missing gitlab postgres data: $SANDBOX/var/opt/gitlab/postgresql/data" >&2
        exit 1
      }
      echo "[state] gitlab /var/opt is tens of GB; this copy takes a while..."
      copy_dir "$SANDBOX/etc/gitlab" "$STATE/etc-gitlab"
      copy_dir "$SANDBOX/var/opt/gitlab" "$STATE/var-opt"
      copy_dir "$SANDBOX/var/log/gitlab" "$STATE/gitlab-log"
      ;;
    map)
      copy_dir "$SANDBOX/var/lib/postgresql/14/main" "$STATE/website-pg"
      copy_dir "$SANDBOX/home/renderer/src/openstreetmap-carto-backup" "$STATE/style"
      if [ -d "$SANDBOX/nominatim-base" ]; then
        copy_dir "$SANDBOX/nominatim-base" "$STATE/nominatim"
      else
        copy_dir "$SANDBOX/nominatim" "$STATE/nominatim"
      fi
      mkdir -p "$STATE/app-log" "$STATE/app-tmp" "$STATE/apache-log" \
        "$STATE/tiles" "$STATE/renderd-cache/tiles"
      ;;
  esac
}

cmd_prepare() {
  echo "[state] extracting writable state from $SANDBOX"
  extract_state
  sanitize_state
  if [ "$WA_SKIP_SEED" = "1" ]; then
    echo "[state] WA_SKIP_SEED=1: skipping seed snapshot (reset will not work until you run 'seed')"
  else
    echo "[state] snapshotting seed -> $SEED"
    rm -rf "$SEED"
    mkdir -p "$SEED"
    cp -a --reflink=auto "$STATE"/. "$SEED"/
  fi
  echo "[state] done"
}

cmd_restore() {
  [ -d "$SEED" ] && [ -n "$(ls -A "$SEED" 2>/dev/null)" ] || {
    echo "no seed at $SEED; run prepare first" >&2
    exit 1
  }
  echo "[state] restoring $STATE from seed"
  sync_dir "$SEED" "$STATE"
  sanitize_state
  echo "[state] done"
}

cmd_seed() {
  [ -d "$STATE" ] && [ -n "$(ls -A "$STATE" 2>/dev/null)" ] || {
    echo "no live state at $STATE" >&2
    exit 1
  }
  echo "[state] re-seeding from live state (stop the site first!)"
  rm -rf "$SEED"
  mkdir -p "$SEED"
  cp -a --reflink=auto "$STATE"/. "$SEED"/
  echo "[state] done"
}

case "$CMD" in
  prepare) cmd_prepare ;;
  restore) cmd_restore ;;
  seed) cmd_seed ;;
  *)
    echo "usage: $0 {prepare|restore|seed} {$WA_ALL_SITES}" >&2
    exit 1
    ;;
esac
