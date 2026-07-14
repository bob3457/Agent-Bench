#!/bin/bash
# wa_map_entry.sh - in-container launcher for webarena-verified map (OSM
# website) under rootless Apptainer.
#
# Replaces supervisord + the image entrypoint: starts three postgres clusters,
# the rails website, apache (tiles + nominatim + routing proxy + external
# vhost), renderd, and three osrm-routed instances directly as the calling
# user, replicating the image entrypoint's one-time init (website db creation
# + rails migrations, nominatim project setup) without su/sudo/chown.
#
# The site uses relative URLs client-side and localhost:8080 server-side, so
# no base-url init is needed (matches MapOps._init in webarena-verified).
#
# Fixed internal ports (baked into the image): rails 3000, apache 8080/8085
# (loopback), osrm 5000-5002, postgres 5432 (tiles) / 5433 (website) /
# 5434 (nominatim). External: WA_HTTP_PORT (default 3030).

set -eu

WA_HTTP_PORT="${WA_HTTP_PORT:?}"
WA_HOST="${WA_HOST:?}"
WA_RUN_SECONDS="${WA_RUN_SECONDS:-0}"

LOG_DIR=/var/log/webarena
PID_DIR=/run/webarena
mkdir -p "$LOG_DIR" "$PID_DIR" /run/postgresql /run/renderd /run/apache2
# debian cluster confs point stats_temp_directory at /var/run/postgresql/<c>.pg_stat_tmp;
# pg_ctlcluster would create these, raw pg_ctl does not
mkdir -p /run/postgresql/14-main.pg_stat_tmp /run/postgresql/14-nominatim.pg_stat_tmp \
  /run/postgresql/15-main.pg_stat_tmp
rm -f /run/webarena/ready 2>/dev/null || true

PG14=/usr/lib/postgresql/14/bin
PG15=/usr/lib/postgresql/15/bin
PG14_DATA=/var/lib/postgresql/14/main
PG14_CONF=/etc/postgresql/14/main/postgresql.conf
PG15_DATA=/data/database/postgres
PG15_CONF=/etc/postgresql/15/main/postgresql.conf
NOM_DATA=/data/nominatim/postgres
NOM_CONF=/etc/postgresql/14/nominatim/postgresql.conf

export RAILS_ENV=production
export RAILS_SERVE_STATIC_FILES=true
export SECRET_KEY_BASE="${SECRET_KEY_BASE:-1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b}"

cleanup() {
  for pid_file in "$PID_DIR"/*.pid; do
    [ -f "$pid_file" ] || continue
    pid="$(cat "$pid_file" 2>/dev/null || true)"
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  done
  "$PG14/pg_ctl" -D "$PG14_DATA" stop -m fast >/dev/null 2>&1 || true
  "$PG15/pg_ctl" -D "$PG15_DATA" stop -m fast >/dev/null 2>&1 || true
  "$PG14/pg_ctl" -D "$NOM_DATA" stop -m fast >/dev/null 2>&1 || true
}
trap cleanup INT TERM EXIT

pg_start() { # pg_start <bindir> <datadir> <conf> <name>
  chmod 700 "$2" 2>/dev/null || true
  rm -f "$2/postmaster.pid" 2>/dev/null || true
  "$1/pg_ctl" -D "$2" \
    -o "-c config_file=$3 -c unix_socket_directories=/run/postgresql" \
    -l "$LOG_DIR/$4.log" start -w -t 120
}

echo "[entry] site=map url=http://${WA_HOST}:${WA_HTTP_PORT}/"

# --- postgres: website (5433), tiles (5432), nominatim (5434) --------------------
pg_start "$PG14" "$PG14_DATA" "$PG14_CONF" pg14-website

if [ -f "$PG15_DATA/PG_VERSION" ]; then
  pg_start "$PG15" "$PG15_DATA" "$PG15_CONF" pg15-tiles
else
  echo "[entry] WARNING: no tile db at $PG15_DATA (tiles disabled) — run 05_fetch_map_data.sh" >&2
fi

if [ -f "$NOM_DATA/PG_VERSION" ]; then
  pg_start "$PG14" "$NOM_DATA" "$NOM_CONF" pg14-nominatim
else
  echo "[entry] WARNING: no nominatim db at $NOM_DATA (geocoding disabled)" >&2
fi

# --- one-time init: website db + migrations (mirrors image entrypoint, no su) -----
if ! psql -h 127.0.0.1 -p 5433 -U postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='openstreetmap'" 2>/dev/null | grep -q 1; then
  echo "[entry] creating openstreetmap role..."
  psql -h 127.0.0.1 -p 5433 -U postgres -c "CREATE USER openstreetmap SUPERUSER PASSWORD 'openstreetmap';" ||
    psql -h 127.0.0.1 -p 5433 -c "CREATE USER openstreetmap SUPERUSER PASSWORD 'openstreetmap';"
fi
if ! psql -h 127.0.0.1 -p 5433 -U openstreetmap -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='openstreetmap'" 2>/dev/null | grep -q 1; then
  echo "[entry] creating openstreetmap database..."
  createdb -h 127.0.0.1 -p 5433 -U openstreetmap openstreetmap
fi
cd /app
if ! psql -h 127.0.0.1 -p 5433 -U openstreetmap -d openstreetmap -tAc "SELECT 1 FROM information_schema.tables WHERE table_name='users'" 2>/dev/null | grep -q 1; then
  echo "[entry] running rails db:migrate (first start only)..."
  bundle exec rails db:migrate >"$LOG_DIR/rails-migrate.log" 2>&1
fi

# --- nominatim project ------------------------------------------------------------
if [ -f "$NOM_DATA/PG_VERSION" ] && [ -d /nominatim ]; then
  grep -q "NOMINATIM_DATABASE_DSN" /nominatim/.env 2>/dev/null ||
    echo 'NOMINATIM_DATABASE_DSN="pgsql:host=/run/postgresql;port=5434;dbname=nominatim"' >>/nominatim/.env
  if [ ! -f /nominatim/website/search.php ]; then
    (cd /nominatim && nominatim refresh --website --functions >"$LOG_DIR/nominatim-refresh.log" 2>&1) ||
      echo "[entry] WARNING: nominatim refresh failed (geocoding may not work)" >&2
  fi
fi

# --- tile style --------------------------------------------------------------------
if [ ! -f /data/style/mapnik.xml ] && [ -f /data/style/project.mml ] && command -v carto >/dev/null 2>&1; then
  (cd /data/style && carto project.mml >mapnik.xml) || echo "[entry] WARNING: carto build failed" >&2
fi

# --- rails ------------------------------------------------------------------------
bundle exec rails server -b 127.0.0.1 -p 3000 >"$LOG_DIR/rails.log" 2>&1 &
echo "$!" >"$PID_DIR/rails.pid"

# --- apache (tiles + proxies + external vhost) --------------------------------------
export APACHE_RUN_DIR=/run/apache2 APACHE_PID_FILE=/run/apache2/apache2.pid
export APACHE_LOCK_DIR=/run/apache2 APACHE_LOG_DIR=/var/log/apache2
export APACHE_RUN_USER="$(id -un)" APACHE_RUN_GROUP="$(id -gn)"
apache2 -d /etc/apache2 -D FOREGROUND >"$LOG_DIR/apache2.log" 2>&1 &
echo "$!" >"$PID_DIR/apache2.pid"

# --- renderd ------------------------------------------------------------------------
if [ -f /data/style/mapnik.xml ] && [ -f "$PG15_DATA/PG_VERSION" ]; then
  renderd -f -c /etc/renderd.conf >"$LOG_DIR/renderd.log" 2>&1 &
  echo "$!" >"$PID_DIR/renderd.pid"
fi

# --- osrm ---------------------------------------------------------------------------
for profile in car:5000 bike:5001 foot:5002; do
  name="${profile%%:*}"
  port="${profile##*:}"
  data="/data/routing/$name/us-northeast-latest.osrm"
  if [ -f "$data.mldgr" ]; then
    /usr/local/bin/osrm-routed --algorithm mld --mmap --max-table-size 1000 -t 4 \
      --port "$port" "$data" >"$LOG_DIR/osrm-$name.log" 2>&1 &
    echo "$!" >"$PID_DIR/osrm-$name.pid"
  else
    echo "[entry] WARNING: no $name routing data at $data.* (routing-$name disabled)" >&2
  fi
done

# --- wait for HTTP -------------------------------------------------------------------
ready=0
i=0
while [ "$i" -lt 120 ]; do
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${WA_HTTP_PORT}/" || true)"
  case "$code" in 200 | 302)
    ready=1
    break
    ;;
  esac
  i=$((i + 1))
  sleep 5
done
if [ "$ready" != "1" ]; then
  echo "[entry] map did not answer HTTP (last: ${code:-none})" >&2
  tail -n 60 "$LOG_DIR"/*.log >&2 || true
  exit 1
fi

echo "[entry] READY: http://${WA_HOST}:${WA_HTTP_PORT}/"
touch /run/webarena/ready  # signals launcher/smoke that init is complete
echo "[entry] internal: rails=3000 apache=8080/8085(loopback) osrm=5000-5002 pg=5432/5433/5434"

if [ "$WA_RUN_SECONDS" != "0" ]; then
  sleep "$WA_RUN_SECONDS"
  exit 0
fi

# --- babysit ---------------------------------------------------------------------------
while true; do
  for pid_file in "$PID_DIR"/*.pid; do
    [ -f "$pid_file" ] || continue
    pid="$(cat "$pid_file" 2>/dev/null || true)"
    [ -n "$pid" ] || continue
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "[entry] service exited: $pid_file" >&2
      tail -n 60 "$LOG_DIR"/*.log >&2 || true
      exit 1
    fi
  done
  sleep 5
done
