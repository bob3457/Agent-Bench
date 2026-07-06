#!/usr/bin/env bash
# 03_prepare_state.sh - manage the writable state that gets bind-mounted over
# the read-only SIF at runtime (MySQL data, Magento var/, nginx lib,
# Elasticsearch data).
#
# Commands:
#   prepare {site}   Extract writable state from the patched sandbox into
#                    $WA_STATE_DIR/{site} and snapshot it to $WA_SEED_DIR/{site}
#   restore {site}   Reset $WA_STATE_DIR/{site} from the seed (task reset)
#   seed    {site}   Re-snapshot the current live state as the new seed
#
# Usage: ./03_prepare_state.sh {prepare|restore|seed} {shopping|shopping_admin}

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

# state subdirs -> in-container paths (see wa_site.sh for the binds)
#   mysql        -> /var/lib/mysql
#   nginx-lib    -> /var/lib/nginx
#   magento-var  -> /var/www/magento2/var
#   es-data      -> /usr/share/java/elasticsearch/data

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
  # Alpine nginx symlinks lib/nginx/{logs,tmp}; replace with real dirs so the
  # non-root process can write there.
  for p in logs tmp; do
    if [ -L "$STATE/nginx-lib/$p" ] || { [ -e "$STATE/nginx-lib/$p" ] && [ ! -d "$STATE/nginx-lib/$p" ]; }; then
      rm -f "$STATE/nginx-lib/$p"
    fi
  done
  mkdir -p "$STATE/nginx-lib/logs" "$STATE/nginx-lib/tmp/client_body"
  chmod -R u+rwX "$STATE"
}

cmd_prepare() {
  [ -d "$SANDBOX/var/lib/mysql/mysql" ] || {
    echo "sandbox missing MySQL data: $SANDBOX/var/lib/mysql" >&2
    exit 1
  }
  echo "[state] extracting writable state from $SANDBOX"
  copy_dir "$SANDBOX/var/lib/mysql" "$STATE/mysql"
  copy_dir "$SANDBOX/var/lib/nginx" "$STATE/nginx-lib"
  copy_dir "$SANDBOX/var/www/magento2/var" "$STATE/magento-var"
  if [ "$(wa_site_var "$SITE" WITH_ES)" = "1" ]; then
    copy_dir "$SANDBOX/usr/share/java/elasticsearch/data" "$STATE/es-data"
  fi
  sanitize_state
  echo "[state] snapshotting seed -> $SEED"
  rm -rf "$SEED"
  mkdir -p "$SEED"
  cp -a --reflink=auto "$STATE"/. "$SEED"/
  echo "[state] done"
}

cmd_restore() {
  [ -d "$SEED/mysql/mysql" ] || {
    echo "no seed at $SEED; run prepare first" >&2
    exit 1
  }
  echo "[state] restoring $STATE from seed"
  sync_dir "$SEED" "$STATE"
  sanitize_state
  echo "[state] done"
}

cmd_seed() {
  [ -d "$STATE/mysql/mysql" ] || {
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
    echo "usage: $0 {prepare|restore|seed} {shopping|shopping_admin}" >&2
    exit 1
    ;;
esac
