#!/bin/sh
# wa_gitlab_entry.sh - in-container launcher for webarena-verified gitlab
# (omnibus) under rootless Apptainer.
#
# Keeps the omnibus runit stack (runsvdir-start) — 02_patch_sandbox.sh has
# already stripped all chpst/su user switching so every service runs as the
# calling uid. gitlab-ctl reconfigure is NEVER run (needs root + chef);
# instead the generated rails config is patched directly each start:
#   * gitlab.yml  production.gitlab.host / port -> WA_HOST / WA_HTTP_PORT
#
# Driven by env vars set by wa_site.sh. POSIX sh (image is Ubuntu-based).

set -eu

WA_HTTP_PORT="${WA_HTTP_PORT:?}"
WA_HOST="${WA_HOST:?}"
WA_SKIP_INIT="${WA_SKIP_INIT:-0}"
WA_RUN_SECONDS="${WA_RUN_SECONDS:-0}"

LOG_DIR=/var/log/webarena
PID_DIR=/run/webarena
GITLAB_YML=/var/opt/gitlab/gitlab-rails/etc/gitlab.yml
mkdir -p "$LOG_DIR" "$PID_DIR"

echo "[entry] site=gitlab base_url=http://${WA_HOST}:${WA_HTTP_PORT}/"

# --- point generated rails config at this node ----------------------------------
if [ "$WA_SKIP_INIT" != "1" ] && [ -f "$GITLAB_YML" ]; then
  # first host:/port: pair in the file is production.gitlab.{host,port}
  sed -i "0,/^\([[:space:]]*\)host:.*/s//\1host: ${WA_HOST}/" "$GITLAB_YML"
  sed -i "0,/^\([[:space:]]*\)port:.*/s//\1port: ${WA_HTTP_PORT}/" "$GITLAB_YML"
  echo "[entry] gitlab.yml now:"
  grep -nE '^\s*(host|port):' "$GITLAB_YML" | head -4 || true
fi

# stale pid cleanup (runit + postgres)
rm -f /var/opt/gitlab/postgresql/data/postmaster.pid 2>/dev/null || true

cleanup() {
  gitlab-ctl stop >/dev/null 2>&1 || true
  [ -n "${RUNSVDIR_PID:-}" ] && kill "$RUNSVDIR_PID" 2>/dev/null || true
}
trap cleanup INT TERM EXIT

# --- start runit ----------------------------------------------------------------
echo "[entry] starting runsvdir..."
/opt/gitlab/embedded/bin/runsvdir-start >"$LOG_DIR/runsvdir.log" 2>&1 &
RUNSVDIR_PID=$!
echo "$RUNSVDIR_PID" >"$PID_DIR/runsvdir.pid"

# wait until gitlab-ctl can talk to runit, then make sure services are up
i=0
while [ "$i" -lt 60 ]; do
  gitlab-ctl status >/dev/null 2>&1 && break
  i=$((i + 1))
  sleep 5
done
gitlab-ctl start >"$LOG_DIR/gitlab-ctl-start.log" 2>&1 || true

# --- wait for HTTP (puma boot is slow: several minutes on first start) -----------
ready=0
i=0
while [ "$i" -lt 180 ]; do
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${WA_HTTP_PORT}/users/sign_in" || true)"
  case "$code" in 200 | 302)
    ready=1
    break
    ;;
  esac
  i=$((i + 1))
  sleep 5
done
if [ "$ready" != "1" ]; then
  echo "[entry] gitlab did not answer HTTP (last: ${code:-none})" >&2
  gitlab-ctl status >&2 || true
  tail -n 40 /var/log/gitlab/nginx/*.log /var/log/gitlab/puma/*.log 2>/dev/null >&2 || true
  exit 1
fi

echo "[entry] READY: http://${WA_HOST}:${WA_HTTP_PORT}/"
echo "[entry] login: byteblaze / hello1234"

if [ "$WA_RUN_SECONDS" != "0" ]; then
  sleep "$WA_RUN_SECONDS"
  exit 0
fi

# --- babysit runsvdir ------------------------------------------------------------
while kill -0 "$RUNSVDIR_PID" 2>/dev/null; do
  sleep 10
done
echo "[entry] runsvdir exited" >&2
exit 1
