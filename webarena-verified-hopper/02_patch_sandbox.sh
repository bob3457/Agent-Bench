#!/usr/bin/env bash
# 02_patch_sandbox.sh - patch a webarena-verified shopping/shopping_admin
# sandbox so every service runs rootless under Apptainer on Hopper
# (single-uid user namespace, no /etc/subuid, no privileged ports, no su).
#
# This is the PoloWitty webarena-lite-for-rootless-slurm patch set, ported to
# the ServiceNow webarena-verified images (same underlying Alpine/Magento
# layout, so the patches map 1:1). Changes:
#   * nginx:    drop `user` directive, listen on the external high port,
#               proxy PHP over TCP instead of a socket
#   * php-fpm:  drop user/group directives, listen on 127.0.0.1:<fpm_port>
#   * mariadb:  TCP on 127.0.0.1:<mysql_port> (client + server defaults)
#   * redis:    port moved via launcher args; magento env.php updated
#   * magento:  env.php db/redis endpoints point at the new TCP ports
#
# Idempotent: safe to re-run. Supervisord configs are left in place but unused;
# the runtime launcher (container/wa_magento_entry.sh) starts services directly.
#
# Usage: ./02_patch_sandbox.sh {shopping|shopping_admin} [sandbox_dir]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=wa_common.sh
source "$SCRIPT_DIR/wa_common.sh"

SITE="${1:-}"
wa_check_site "$SITE"
ROOT="${2:-$(wa_sandbox "$SITE")}"

HTTP_PORT="$(wa_site_var "$SITE" HTTP_PORT)"
MYSQL_PORT="$(wa_site_var "$SITE" MYSQL_PORT)"
REDIS_PORT="$(wa_site_var "$SITE" REDIS_PORT)"
FPM_PORT="$(wa_site_var "$SITE" FPM_PORT)"

[ -d "$ROOT" ] || {
  echo "sandbox not found: $ROOT (run 01_fetch_images.sh first)" >&2
  exit 1
}
ENV_PHP="$ROOT/var/www/magento2/app/etc/env.php"
[ -f "$ENV_PHP" ] || {
  echo "sandbox incomplete; missing $ENV_PHP" >&2
  exit 1
}

echo "[patch] site=$SITE root=$ROOT"
echo "[patch] ports: http=$HTTP_PORT mysql=$MYSQL_PORT redis=$REDIS_PORT fpm=$FPM_PORT"

# --- runtime dirs that must exist inside the image ---------------------------
mkdir -p "$ROOT/run/nginx" "$ROOT/run/mysqld" "$ROOT/run/redis" \
  "$ROOT/var/tmp/nginx/client_body" "$ROOT/var/log/webarena" "$ROOT/run/webarena"

# --- nginx --------------------------------------------------------------------
if [ -f "$ROOT/etc/nginx/nginx.conf" ]; then
  sed -i 's/^user[[:space:]].*/# user disabled for rootless apptainer runtime/' \
    "$ROOT/etc/nginx/nginx.conf"
fi

if [ -d "$ROOT/etc/nginx/conf.d" ]; then
  cat >"$ROOT/etc/nginx/conf.d/default.conf" <<EOF_NGINX
upstream fastcgi_backend {
  server 127.0.0.1:${FPM_PORT};
}

server {
  listen ${HTTP_PORT} default_server;
  server_name _;
  set \$MAGE_ROOT /var/www/magento2;
  include /var/www/magento2/nginx.conf.sample;
}
EOF_NGINX
fi

# Alpine ships a default 80-listener in http.d on some builds; neutralize it.
if [ -d "$ROOT/etc/nginx/http.d" ]; then
  cat >"$ROOT/etc/nginx/http.d/default.conf" <<'EOF_HTTPD'
# disabled for rootless apptainer runtime (server block lives in conf.d)
EOF_HTTPD
fi

# --- php-fpm ------------------------------------------------------------------
for f in "$ROOT"/usr/local/etc/php-fpm.d/*.conf "$ROOT"/usr/local/etc/php-fpm.d/*.default; do
  [ -f "$f" ] || continue
  sed -i "s|^listen = .*|listen = 127.0.0.1:${FPM_PORT}|g" "$f"
  sed -i 's|^user = .*|; user disabled for rootless apptainer runtime|g' "$f"
  sed -i 's|^group = .*|; group disabled for rootless apptainer runtime|g' "$f"
  sed -i 's|^listen\.owner = .*|; listen.owner disabled (tcp listen)|g' "$f"
  sed -i 's|^listen\.group = .*|; listen.group disabled (tcp listen)|g' "$f"
done

# --- mariadb ------------------------------------------------------------------
mkdir -p "$ROOT/etc/my.cnf.d"
cat >"$ROOT/etc/my.cnf.d/webarena-rootless.cnf" <<EOF_MYSQL
[client]
host=127.0.0.1
port=${MYSQL_PORT}

[mysqld]
skip-networking=0
bind-address=127.0.0.1
port=${MYSQL_PORT}
innodb_buffer_pool_size=${WA_MYSQL_BUFFER_POOL}
max_connections=${WA_MYSQL_MAX_CONNECTIONS}
EOF_MYSQL

# --- magento env.php ------------------------------------------------------------
# Point redis and mysql at the new TCP endpoints. The verified images inherit
# the CMU env.php (db host 127.0.0.1 or localhost, redis on 6379).
# (Same seds PoloWitty uses on the identical upstream env.php.)
sed -i "s|'port' => '6379'|'port' => '${REDIS_PORT}'|g" "$ENV_PHP"
if grep -q "'host' => '127.0.0.1:${MYSQL_PORT}'" "$ENV_PHP"; then
  echo "[patch] env.php db host already patched"
elif grep -q "'host' => '127.0.0.1'" "$ENV_PHP"; then
  sed -i "s|'host' => '127.0.0.1'|'host' => '127.0.0.1:${MYSQL_PORT}'|" "$ENV_PHP"
elif grep -q "'host' => 'localhost'" "$ENV_PHP"; then
  sed -i "s|'host' => 'localhost'|'host' => '127.0.0.1:${MYSQL_PORT}'|" "$ENV_PHP"
else
  echo "[patch] WARNING: no db host entry matched in env.php; inspect manually:" >&2
fi

echo "[patch] env.php endpoints now:"
grep -n "host' =>\|port' =>" "$ENV_PHP" | head -12 || true

echo "[patch] done. Next: ./03_prepare_state.sh $SITE  (then optionally 04_pack_sif.sh)"
