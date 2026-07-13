#!/usr/bin/env bash
# 02_patch_sandbox.sh - patch a webarena-verified sandbox so every service runs
# rootless under Apptainer on Hopper (single-uid user namespace, no
# /etc/subuid, no privileged ports, no su/chpst user switching).
#
# Per site kind:
#   magento (shopping, shopping_admin) — the PoloWitty webarena-lite patch set:
#     * nginx:    drop `user` directive, listen on the external high port,
#                 proxy PHP over TCP instead of a socket
#     * php-fpm:  drop user/group directives, listen on 127.0.0.1:<fpm_port>
#     * mariadb:  TCP on 127.0.0.1:<mysql_port> (client + server defaults)
#     * redis:    port moved via launcher args; magento env.php updated
#     * magento:  env.php db/redis endpoints point at the new TCP ports
#   reddit (Postmill) —
#     * nginx:    drop `user`, listen 80 -> <http_port>, fastcgi -> tcp <fpm_port>
#     * php-fpm:  drop user/group, listen 127.0.0.1:<fpm_port>
#     * postgres: port/socket moved via launcher args (entry script)
#     * symfony:  .env DATABASE_URL points at 127.0.0.1:<pg_port>
#   gitlab (omnibus) —
#     * strip `chpst -u/-U <user>` from every runit run/log script so all
#       services run as the calling uid
#     * neuter chown in runsvdir-start and service scripts
#     * drop nginx `user` directive in the generated /var/opt config
#     * disable sshd (port 22 is privileged) and leftover monitoring services
#   map (OSM website) —
#     * apache: internal 8080 restricted to loopback (server-side URLs are
#       baked to localhost:8080), add external Listen on <http_port> and add
#       that port to the tile-server vhost
#     * postgres cluster configs: point data_directory at the runtime bind
#       locations, apply the tile-server custom config at patch time
#       (/etc is read-only at runtime)
#
# Idempotent: safe to re-run. Supervisord/runit configs shipped by the images
# are otherwise left in place; the runtime launchers (container/wa_*_entry.sh)
# start services directly (except gitlab, which keeps runit).
#
# Usage: ./02_patch_sandbox.sh {shopping|shopping_admin|reddit|gitlab|map} [sandbox_dir]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=wa_common.sh
source "$SCRIPT_DIR/wa_common.sh"

SITE="${1:-}"
wa_check_site "$SITE"
ROOT="${2:-$(wa_sandbox "$SITE")}"
KIND="$(wa_site_kind "$SITE")"

[ -d "$ROOT" ] || {
  echo "sandbox not found: $ROOT (run 01_fetch_images.sh first)" >&2
  exit 1
}

HTTP_PORT="$(wa_site_var "$SITE" HTTP_PORT)"

echo "[patch] site=$SITE kind=$KIND root=$ROOT http_port=$HTTP_PORT"

# ==============================================================================
# Shared: normalize a top-level nginx.conf for rootless single-uid runtime.
# Applied to every nginx-based site (magento, reddit): drop the user directive,
# drop the docker-ism daemon directive (all entry scripts pass -g 'daemon off;'
# — leaving it in the conf is a fatal duplicate), pin the pid path to /run/nginx.
wa_patch_nginx_top() { # wa_patch_nginx_top <nginx.conf path>
  [ -f "$1" ] || return 0
  sed -i 's/^user[[:space:]].*/# user disabled for rootless apptainer runtime/' "$1"
  sed -i -E 's/^[[:space:]]*daemon[[:space:]]+[a-z]+;.*/# daemon directive removed (entry passes -g)/' "$1"
  sed -i -E "s|^([[:space:]]*)pid[[:space:]]+[^;]+;|\1pid /run/nginx/nginx.pid;|" "$1"
}

patch_magento() {
  local MYSQL_PORT REDIS_PORT FPM_PORT ENV_PHP
  MYSQL_PORT="$(wa_site_var "$SITE" MYSQL_PORT)"
  REDIS_PORT="$(wa_site_var "$SITE" REDIS_PORT)"
  FPM_PORT="$(wa_site_var "$SITE" FPM_PORT)"
  ENV_PHP="$ROOT/var/www/magento2/app/etc/env.php"
  [ -f "$ENV_PHP" ] || {
    echo "sandbox incomplete; missing $ENV_PHP" >&2
    exit 1
  }
  echo "[patch] ports: http=$HTTP_PORT mysql=$MYSQL_PORT redis=$REDIS_PORT fpm=$FPM_PORT"

  # --- runtime dirs that must exist inside the image ---------------------------
  mkdir -p "$ROOT/run/nginx" "$ROOT/run/mysqld" "$ROOT/run/redis" \
    "$ROOT/var/tmp/nginx/client_body" "$ROOT/var/log/webarena" "$ROOT/run/webarena"

  # --- nginx --------------------------------------------------------------------
  wa_patch_nginx_top "$ROOT/etc/nginx/nginx.conf"

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
}

# ==============================================================================
patch_reddit() {
  local PG_PORT FPM_PORT APP="$ROOT/var/www/html"
  PG_PORT="$(wa_site_var "$SITE" PG_PORT)"
  FPM_PORT="$(wa_site_var "$SITE" FPM_PORT)"
  echo "[patch] ports: http=$HTTP_PORT postgres=$PG_PORT fpm=$FPM_PORT"

  [ -d "$APP" ] || {
    echo "sandbox incomplete; missing $APP (Postmill app root)" >&2
    exit 1
  }

  mkdir -p "$ROOT/run/nginx" "$ROOT/run/postgresql" "$ROOT/run/php" \
    "$ROOT/var/log/webarena" "$ROOT/run/webarena" \
    "$ROOT/var/tmp/nginx/client_body"

  # --- locate postgres data dir (recorded for wa_site.sh binds) ----------------
  local pgdata="" cand
  for cand in "$ROOT/usr/local/pgsql/data" \
    "$ROOT/var/lib/postgresql/data" \
    "$ROOT"/var/lib/postgresql/*/data \
    "$ROOT"/var/lib/postgresql/*/main; do
    if [ -f "$cand/PG_VERSION" ]; then
      pgdata="$cand"
      break
    fi
  done
  [ -n "$pgdata" ] || {
    echo "[patch] ERROR: no postgres data dir with PG_VERSION found under sandbox" >&2
    exit 1
  }
  # container-side path == sandbox-relative path
  printf '%s\n' "${pgdata#"$ROOT"}" >"$ROOT/.wa_pgdata_path"
  echo "[patch] postgres data dir (in-container): $(cat "$ROOT/.wa_pgdata_path")"
  chmod 700 "$pgdata" || true

  # --- nginx --------------------------------------------------------------------
  local nconf
  for nconf in "$ROOT/etc/nginx/nginx.conf" "$ROOT"/etc/nginx/conf.d/*.conf \
    "$ROOT"/etc/nginx/http.d/*.conf "$ROOT"/etc/nginx/sites-enabled/*; do
    [ -f "$nconf" ] || continue
    sed -i 's/^user[[:space:]].*/# user disabled for rootless apptainer runtime/' "$nconf"
    # the entry script runs nginx with -g 'daemon off;'; a daemon directive in
    # the conf (typical for docker images) would be a fatal duplicate
    sed -i -E 's/^[[:space:]]*daemon[[:space:]]+[a-z]+;.*/# daemon directive removed (entry passes -g)/' "$nconf"
    # keep pid/log paths off the read-only overlay (lesson from wa_common EOVERFLOW)
    sed -i -E "s|^([[:space:]]*)pid[[:space:]]+[^;]+;|\1pid /run/nginx/nginx.pid;|" "$nconf"
    sed -i -E "s|fastcgi_pass[[:space:]]+[^;]+;|fastcgi_pass 127.0.0.1:${FPM_PORT};|g" "$nconf"
    # Postmill's REAL db config is a fastcgi_param injected into $_SERVER —
    # Symfony's Dotenv never overrides it, so this (not .env) is authoritative.
    # Rewrite host -> 127.0.0.1 (localhost may resolve ::1; postgres is v4-only)
    # and port -> moved PG_PORT, keeping credentials/dbname/serverVersion as shipped.
    sed -i -E "s|(fastcgi_param[[:space:]]+DATABASE_URL[[:space:]]+\"pgsql://[^@\"]+@)(localhost\|127\.0\.0\.1)(:[0-9]+)?/|\1127.0.0.1:${PG_PORT}/|" "$nconf"
    # Collapse ALL listen directives per server block to exactly one on
    # HTTP_PORT. The image ships v4+v6 pairs (listen 80; listen [::]:80 ...);
    # naive port rewriting turns those into fatal duplicates.
    awk -v port="$HTTP_PORT" '
      /^[[:space:]]*server[[:space:]]*\{/ { seen = 0 }
      /^[[:space:]]*listen[[:space:]]/ {
        if (!seen) { print "    listen " port ";"; seen = 1 }
        next
      }
      { print }
    ' "$nconf" >"$nconf.wa_tmp" && mv "$nconf.wa_tmp" "$nconf"
  done
  echo "[patch] nginx listen/fastcgi now:"
  grep -hnE 'listen |DATABASE_URL' "$ROOT"/etc/nginx/conf.d/*.conf 2>/dev/null || true

  # --- php-fpm ------------------------------------------------------------------
  local f found_fpm=0
  for f in "$ROOT"/etc/php*/php-fpm.d/*.conf "$ROOT"/etc/php/*/fpm/pool.d/*.conf \
    "$ROOT"/usr/local/etc/php-fpm.d/*.conf; do
    [ -f "$f" ] || continue
    found_fpm=1
    sed -i -E "s|^listen = .*|listen = 127.0.0.1:${FPM_PORT}|g" "$f"
    sed -i 's|^user = .*|; user disabled for rootless apptainer runtime|g' "$f"
    sed -i 's|^group = .*|; group disabled for rootless apptainer runtime|g' "$f"
    sed -i 's|^listen\.owner = .*|; listen.owner disabled (tcp listen)|g' "$f"
    sed -i 's|^listen\.group = .*|; listen.group disabled (tcp listen)|g' "$f"
  done
  [ "$found_fpm" = "1" ] || echo "[patch] WARNING: no php-fpm pool config matched; check image layout" >&2

  # --- symfony .env: secondary — the nginx fastcgi_param above is what the web
  # app actually sees; this covers `bin/console` CLI use inside the container.
  if [ -f "$APP/.env" ]; then
    sed -i -E "s|(DATABASE_URL=pgsql://[^@]+@)(localhost\|127\.0\.0\.1)(:[0-9]+)?/|\1127.0.0.1:${PG_PORT}/|" "$APP/.env"
    echo "[patch] .env now:"
    grep -nE 'DATABASE_URL|APP_SITE_NAME' "$APP/.env" || true
  else
    echo "[patch] WARNING: $APP/.env not found; DATABASE_URL not patched" >&2
  fi
}

# ==============================================================================
patch_gitlab() {
  local SV="$ROOT/opt/gitlab/sv"
  [ -d "$SV" ] || {
    echo "sandbox incomplete; missing $SV (gitlab omnibus runit tree)" >&2
    exit 1
  }

  mkdir -p "$ROOT/var/log/webarena" "$ROOT/run/webarena"

  # --- strip user switching from every runit script ------------------------------
  # chpst -u/-U <user[:group]> fails in a single-uid namespace; everything runs
  # as the calling user instead (all files are user-owned via --fix-perms).
  local f
  for f in "$SV"/*/run "$SV"/*/log/run "$SV"/*/finish "$SV"/*/control/*; do
    [ -f "$f" ] || continue
    sed -i -E 's/[[:space:]]-[uU][[:space:]]+[A-Za-z0-9_.:-]+//g' "$f"
    # `su - <user> -c` variants and chowns cannot succeed either
    sed -i -E 's/\bsu[[:space:]]+-?[[:space:]]*[A-Za-z0-9_.-]+[[:space:]]+-c[[:space:]]+/sh -c /g' "$f"
    sed -i -E 's/^([[:space:]]*)chown([[:space:]])/\1true chown\2/g' "$f"
    sed -i -E 's/(&&|;)([[:space:]]*)chown([[:space:]])/\1\2true chown\3/g' "$f"
  done

  # runsvdir-start does mkdir/chown/chmod setup as root; neuter the chowns.
  local RSS="$ROOT/opt/gitlab/embedded/bin/runsvdir-start"
  if [ -f "$RSS" ]; then
    sed -i -E 's/^([[:space:]]*)chown([[:space:]])/\1true chown\2/g' "$RSS"
    sed -i -E 's/(&&|;|\|\|)([[:space:]]*)chown([[:space:]])/\1\2true chown\3/g' "$RSS"
  fi

  # --- disable services that cannot or should not run rootless -------------------
  # sshd binds privileged port 22; monitoring is disabled in the verified image
  # but the sv dirs may still exist. A `down` file stops runsv from autostarting.
  local svc
  for svc in sshd crond logrotate alertmanager prometheus grafana \
    gitlab-exporter node-exporter postgres-exporter redis-exporter gitlab-kas; do
    [ -d "$SV/$svc" ] && touch "$SV/$svc/down"
  done

  # --- generated nginx config (lives in /var/opt, becomes writable state) --------
  local gnginx="$ROOT/var/opt/gitlab/nginx/conf/nginx.conf"
  if [ -f "$gnginx" ]; then
    sed -i 's/^user[[:space:]].*/# user disabled for rootless apptainer runtime/' "$gnginx"
  fi

  # postgres requires 0700 on its data dir
  [ -d "$ROOT/var/opt/gitlab/postgresql/data" ] &&
    chmod 700 "$ROOT/var/opt/gitlab/postgresql/data" || true

  echo "[patch] gitlab: user-switching stripped, sshd/monitoring disabled"
  echo "[patch] NOTE: external_url is fixed per-start by container/wa_gitlab_entry.sh"
  echo "[patch]       (edits gitlab.yml directly; gitlab-ctl reconfigure is never run)"
}

# ==============================================================================
patch_map() {
  local PORTS="$ROOT/etc/apache2/ports.conf"
  local VHOST="$ROOT/etc/apache2/sites-available/tile-server.conf"
  [ -f "$PORTS" ] && [ -f "$VHOST" ] || {
    echo "sandbox incomplete; missing apache config ($PORTS / $VHOST)" >&2
    exit 1
  }

  mkdir -p "$ROOT/var/log/webarena" "$ROOT/run/webarena" "$ROOT/run/postgresql" \
    "$ROOT/run/renderd" "$ROOT/run/apache2"

  # --- apache: keep internal 8080 on loopback, add the external port -------------
  # Server-side rails settings + precompiled assets reference localhost:8080, so
  # 8080 must stay; agents connect on MAP_HTTP_PORT.
  if ! grep -q "Listen ${MAP_HTTP_PORT}$" "$PORTS"; then
    sed -i "s|^Listen 8080$|Listen 127.0.0.1:8080\nListen ${MAP_HTTP_PORT}|" "$PORTS"
  fi
  grep -q "Listen 127.0.0.1:8085" "$PORTS" ||
    sed -i "s|^Listen 8085$|Listen 127.0.0.1:8085|" "$PORTS"
  if ! grep -q "\*:${MAP_HTTP_PORT}" "$VHOST"; then
    sed -i "s|<VirtualHost \*:8080>|<VirtualHost *:8080 *:${MAP_HTTP_PORT}>|" "$VHOST"
  fi

  # --- postgres clusters: data dirs at their runtime bind locations --------------
  # /etc is read-only at runtime (SIF), so all config edits happen now.
  # ssl=off in every cluster: --fix-perms leaves the snakeoil key group-readable
  # and postgres refuses to boot; TLS is pointless for a benchmark-local pg.
  local pgconf
  for pgconf in "$ROOT"/etc/postgresql/*/*/postgresql.conf; do
    [ -f "$pgconf" ] || continue
    sed -i -E 's/^([[:space:]]*)ssl[[:space:]]*=[[:space:]]*on/\1ssl = off/' "$pgconf"
  done
  # pg_hba: the image appends a 0.0.0.0/0 trust line, but stock Debian rules
  # above it win first-match and demand passwords on 127.0.0.1. Docker's
  # entrypoint dodged this via 'su - postgres' + unix-socket peer auth, which
  # rootless can't do. Blanket trust is fine for a loopback-only benchmark pg.
  local pghba
  for pghba in "$ROOT"/etc/postgresql/*/*/pg_hba.conf; do
    [ -f "$pghba" ] || continue
    cat >"$pghba" <<'EOF_HBA'
# rewritten for rootless apptainer runtime (single uid, TCP-only psql)
local   all   all                 trust
host    all   all   127.0.0.1/32  trust
host    all   all   ::1/128       trust
host    all   all   0.0.0.0/0     trust
EOF_HBA
  done
  local pg15="$ROOT/etc/postgresql/15/main"
  if [ -d "$pg15" ]; then
    sed -i "s|data_directory = '.*'|data_directory = '/data/database/postgres'|" \
      "$pg15/postgresql.conf"
    mkdir -p "$pg15/conf.d"
    if [ -f "$pg15/postgresql.custom.conf.tmpl" ] && [ ! -f "$pg15/conf.d/postgresql.custom.conf" ]; then
      cp "$pg15/postgresql.custom.conf.tmpl" "$pg15/conf.d/postgresql.custom.conf"
      echo "autovacuum = on" >>"$pg15/conf.d/postgresql.custom.conf"
    fi
  fi
  local pgnom="$ROOT/etc/postgresql/14/nominatim"
  [ -d "$pgnom" ] &&
    sed -i "s|data_directory = '.*'|data_directory = '/data/nominatim/postgres'|" \
      "$pgnom/postgresql.conf"

  echo "[patch] map: apache external port ${MAP_HTTP_PORT} added, pg data dirs pinned"
  echo "[patch] NOTE: map needs external data — run ./05_fetch_map_data.sh (login node)"
}

# ==============================================================================
case "$KIND" in
  magento) patch_magento ;;
  reddit) patch_reddit ;;
  gitlab) patch_gitlab ;;
  map) patch_map ;;
esac

echo "[patch] done. Next: ./03_prepare_state.sh prepare $SITE  (then optionally 04_pack_sif.sh)"
