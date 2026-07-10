#!/bin/sh
# wa_magento_entry.sh - in-container launcher for webarena-verified
# shopping / shopping_admin under rootless Apptainer.
#
# Replaces supervisord + env-ctrl: starts redis, mariadb, php-fpm, nginx (and
# optionally mailcatcher / elasticsearch) directly as the calling user, waits
# for readiness, then applies the exact same initialization env-ctrl would:
#   * magento setup:store-config:set --base-url=...
#   * UPDATE core_config_data ... web/secure/base_url
#   * (admin only) disable admin password expiry/forcing
#   * magento cache:flush
#
# Driven entirely by env vars set by wa_site.sh. POSIX sh (Alpine).

set -eu

WA_SITE="${WA_SITE:?}" # shopping | shopping_admin
WA_HTTP_PORT="${WA_HTTP_PORT:?}"
WA_MYSQL_PORT="${WA_MYSQL_PORT:?}"
WA_REDIS_PORT="${WA_REDIS_PORT:?}"
WA_FPM_PORT="${WA_FPM_PORT:?}"
WA_MAIL_SMTP_PORT="${WA_MAIL_SMTP_PORT:-0}"
WA_MAIL_HTTP_PORT="${WA_MAIL_HTTP_PORT:-0}"
WA_ES_HTTP_PORT="${WA_ES_HTTP_PORT:-0}"
WA_ES_TRANSPORT_PORT="${WA_ES_TRANSPORT_PORT:-0}"
WA_WITH_ES="${WA_WITH_ES:-0}"
WA_WITH_MAIL="${WA_WITH_MAIL:-1}"
WA_HOST="${WA_HOST:?}"
WA_SKIP_INIT="${WA_SKIP_INIT:-0}"     # 1 = don't touch base_url (already set)
WA_RUN_SECONDS="${WA_RUN_SECONDS:-0}" # >0 = smoke mode, exit after N seconds
ES_JAVA_OPTS="${ES_JAVA_OPTS:--Xms512m -Xmx512m}"

MAGENTO=/var/www/magento2
BASE_URL="http://${WA_HOST}:${WA_HTTP_PORT}/"
LOG_DIR=/var/log/webarena
PID_DIR=/run/webarena
mkdir -p "$LOG_DIR" "$PID_DIR" /run/nginx /run/mysqld /run/redis
rm -f /run/webarena/ready 2>/dev/null || true

cleanup() {
  for pid_file in "$PID_DIR"/*.pid; do
    [ -f "$pid_file" ] || continue
    pid="$(cat "$pid_file" 2>/dev/null || true)"
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  done
}
trap cleanup INT TERM EXIT

echo "[entry] site=$WA_SITE base_url=$BASE_URL"

# --- start services -----------------------------------------------------------
mkdir -p "$PID_DIR/redis"
redis-server /etc/redis.conf --bind 127.0.0.1 --port "$WA_REDIS_PORT" \
  --daemonize no --logfile "" --dir "$PID_DIR/redis" \
  >"$LOG_DIR/redis.log" 2>&1 &
echo "$!" >"$PID_DIR/redis.pid"

mysqld --skip-networking=0 --bind-address=127.0.0.1 --port="$WA_MYSQL_PORT" \
  >"$LOG_DIR/mysql.log" 2>&1 &
echo "$!" >"$PID_DIR/mysql.pid"

php-fpm --nodaemonize --fpm-config /usr/local/etc/php-fpm.conf \
  >"$LOG_DIR/php_fpm.log" 2>&1 &
echo "$!" >"$PID_DIR/php_fpm.pid"

nginx -c /etc/nginx/nginx.conf -g "daemon off;" \
  >"$LOG_DIR/nginx.log" 2>&1 &
echo "$!" >"$PID_DIR/nginx.pid"

if [ "$WA_WITH_MAIL" = "1" ] && command -v mailcatcher >/dev/null 2>&1; then
  mailcatcher --foreground --ip=127.0.0.1 \
    --smtp-port="$WA_MAIL_SMTP_PORT" --http-port="$WA_MAIL_HTTP_PORT" \
    >"$LOG_DIR/mailcatcher.log" 2>&1 &
  echo "$!" >"$PID_DIR/mailcatcher.pid"
fi

if [ "$WA_WITH_ES" = "1" ] && command -v elasticsearch >/dev/null 2>&1; then
  ES_JAVA_HOME=/usr ES_JAVA_OPTS="$ES_JAVA_OPTS" elasticsearch \
    -Ehttp.port="$WA_ES_HTTP_PORT" -Etransport.port="$WA_ES_TRANSPORT_PORT" \
    -Enetwork.host=127.0.0.1 \
    >"$LOG_DIR/elasticsearch.log" 2>&1 &
  echo "$!" >"$PID_DIR/elasticsearch.pid"
fi

# --- wait for core services -----------------------------------------------------
ready=0
i=0
while [ "$i" -lt 90 ]; do
  if mysqladmin -h 127.0.0.1 -P "$WA_MYSQL_PORT" -u magentouser -pMyPassword ping >/dev/null 2>&1 &&
    php -r "\$s=@fsockopen('127.0.0.1',${WA_REDIS_PORT}); if(!\$s) exit(1); fclose(\$s);" &&
    php -r "\$s=@fsockopen('127.0.0.1',${WA_FPM_PORT}); if(!\$s) exit(1); fclose(\$s);"; then
    ready=1
    break
  fi
  i=$((i + 1))
  sleep 2
done
if [ "$ready" != "1" ]; then
  echo "[entry] timed out waiting for MariaDB/Redis/PHP-FPM" >&2
  tail -n 80 "$LOG_DIR"/*.log >&2 || true
  exit 1
fi
echo "[entry] core services up"

# --- magento init (== env-ctrl init) -------------------------------------------
if [ "$WA_SKIP_INIT" != "1" ]; then
  php "$MAGENTO/bin/magento" setup:store-config:set --base-url="$BASE_URL"
  mysql -h 127.0.0.1 -P "$WA_MYSQL_PORT" -u magentouser -pMyPassword magentodb \
    -e "UPDATE core_config_data SET value='${BASE_URL}' WHERE path = 'web/secure/base_url';"
  if [ "$WA_SITE" = "shopping_admin" ]; then
    php "$MAGENTO/bin/magento" config:set admin/security/password_is_forced 0
    php "$MAGENTO/bin/magento" config:set admin/security/password_lifetime 0
  fi
  php "$MAGENTO/bin/magento" cache:flush
fi

echo "[entry] READY: ${BASE_URL}$([ "$WA_SITE" = shopping_admin ] && echo admin)"
touch /run/webarena/ready  # signals launcher/smoke that init is complete
echo "[entry] internal ports: mysql=$WA_MYSQL_PORT redis=$WA_REDIS_PORT fpm=$WA_FPM_PORT"

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
      # Elasticsearch is best-effort: storefront browsing works without it
      # (only catalog search degrades). Everything else is load-bearing.
      case "$pid_file" in
        */elasticsearch.pid)
          if [ "${WA_ES_FATAL:-0}" != "1" ]; then
            echo "[entry] WARNING: elasticsearch exited; continuing without it (WA_ES_FATAL=1 to make fatal)" >&2
            tail -n 40 "$LOG_DIR/elasticsearch.log" >&2 || true
            rm -f "$pid_file"
            continue
          fi
          ;;
      esac
      echo "[entry] service exited: $pid_file" >&2
      tail -n 80 "$LOG_DIR"/*.log >&2 || true
      exit 1
    fi
  done
  sleep 5
done
