#!/bin/sh
# wa_reddit_entry.sh - in-container launcher for webarena-verified reddit
# (Postmill: nginx + php-fpm + postgres) under rootless Apptainer.
#
# Replaces supervisord: starts postgres, php-fpm, and nginx directly as the
# calling user, waits for readiness, then applies what env-ctrl init would:
#   * set APP_SITE_NAME=<host>:<port> in /var/www/html/.env
#   * clear the Symfony cache
#
# Driven entirely by env vars set by wa_site.sh. POSIX sh.

set -eu

WA_HTTP_PORT="${WA_HTTP_PORT:?}"
WA_PG_PORT="${WA_PG_PORT:?}"
WA_FPM_PORT="${WA_FPM_PORT:?}"
WA_HOST="${WA_HOST:?}"
WA_PGDATA="${WA_PGDATA:?}" # in-container postgres data dir (bound from state)
WA_SKIP_INIT="${WA_SKIP_INIT:-0}"
WA_RUN_SECONDS="${WA_RUN_SECONDS:-0}"

APP=/var/www/html
LOG_DIR=/var/log/webarena
PID_DIR=/run/webarena
mkdir -p "$LOG_DIR" "$PID_DIR" /run/nginx /run/postgresql
rm -f /run/webarena/ready 2>/dev/null || true

cleanup() {
  for pid_file in "$PID_DIR"/*.pid; do
    [ -f "$pid_file" ] || continue
    pid="$(cat "$pid_file" 2>/dev/null || true)"
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  done
}
trap cleanup INT TERM EXIT

echo "[entry] site=reddit base_url=http://${WA_HOST}:${WA_HTTP_PORT}/"

# --- locate binaries ------------------------------------------------------------
PG_BIN=""
for d in /usr/local/pgsql/bin /usr/lib/postgresql/*/bin /usr/libexec/postgresql* /usr/bin; do
  [ -x "$d/postgres" ] && PG_BIN="$d" && break
done
[ -n "$PG_BIN" ] || { echo "[entry] postgres binary not found" >&2; exit 1; }

FPM_BIN=""
for b in php-fpm php-fpm8 php-fpm81 php-fpm82 php-fpm7 /usr/sbin/php-fpm8.1 /usr/sbin/php-fpm7.4; do
  command -v "$b" >/dev/null 2>&1 && FPM_BIN="$b" && break
done
[ -n "$FPM_BIN" ] || { echo "[entry] php-fpm binary not found" >&2; exit 1; }

# --- start services -----------------------------------------------------------
"$PG_BIN/postgres" -D "$WA_PGDATA" \
  -c listen_addresses=127.0.0.1 -c port="$WA_PG_PORT" \
  -c unix_socket_directories=/run/postgresql \
  >"$LOG_DIR/postgres.log" 2>&1 &
echo "$!" >"$PID_DIR/postgres.pid"

"$FPM_BIN" --nodaemonize >"$LOG_DIR/php_fpm.log" 2>&1 &
echo "$!" >"$PID_DIR/php_fpm.pid"

nginx -c /etc/nginx/nginx.conf -g "daemon off;" \
  >"$LOG_DIR/nginx.log" 2>&1 &
echo "$!" >"$PID_DIR/nginx.pid"

# --- wait for core services -----------------------------------------------------
ready=0
i=0
while [ "$i" -lt 90 ]; do
  if "$PG_BIN/pg_isready" -h 127.0.0.1 -p "$WA_PG_PORT" >/dev/null 2>&1 &&
    php -r "\$s=@fsockopen('127.0.0.1',${WA_FPM_PORT}); if(!\$s) exit(1); fclose(\$s);"; then
    ready=1
    break
  fi
  i=$((i + 1))
  sleep 2
done
if [ "$ready" != "1" ]; then
  echo "[entry] timed out waiting for Postgres/PHP-FPM" >&2
  tail -n 80 "$LOG_DIR"/*.log >&2 || true
  exit 1
fi
echo "[entry] core services up"

# --- postmill init (== env-ctrl init) -------------------------------------------
if [ "$WA_SKIP_INIT" != "1" ]; then
  # truncate-write: sed -i renames its temp file over the target, which fails
  # with EBUSY on a single-file bind mount (.env is bound from state)
  _tmp="$(mktemp)"
  sed "s|^APP_SITE_NAME=.*|APP_SITE_NAME=${WA_HOST}:${WA_HTTP_PORT}|" "$APP/.env" >"$_tmp"
  cat "$_tmp" >"$APP/.env"
  rm -f "$_tmp"
  rm -rf "$APP"/var/cache/* 2>/dev/null || true
  echo "[entry] APP_SITE_NAME=${WA_HOST}:${WA_HTTP_PORT}; symfony cache cleared"
  echo "[entry] (first request rebuilds the prod cache and is slow — that's normal)"
fi

echo "[entry] READY: http://${WA_HOST}:${WA_HTTP_PORT}/"
touch /run/webarena/ready  # signals launcher/smoke that init is complete
echo "[entry] internal ports: postgres=$WA_PG_PORT fpm=$WA_FPM_PORT"

if [ "$WA_RUN_SECONDS" != "0" ]; then
  sleep "$WA_RUN_SECONDS"
  exit 0
fi

# --- babysit -------------------------------------------------------------------
while true; do
  for pid_file in "$PID_DIR"/*.pid; do
    [ -f "$pid_file" ] || continue
    pid="$(cat "$pid_file" 2>/dev/null || true)"
    [ -n "$pid" ] || continue
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "[entry] service exited: $pid_file" >&2
      tail -n 80 "$LOG_DIR"/*.log >&2 || true
      exit 1
    fi
  done
  sleep 5
done
