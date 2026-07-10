#!/usr/bin/env bash
# wa_common.sh - shared configuration for webarena-verified on Hopper (rootless
# Apptainer, SLURM, no /etc/subuid). Source this from the other scripts.
#
# Everything is overridable via environment variables. Defaults follow the
# Agent-Bench layout: persistent artifacts under /projects, volatile runtime
# state under scratch.
#
# Covered sites (everything in WebArena except wikipedia):
#   shopping, shopping_admin  (Magento; the original two-site setup)
#   reddit                    (Postmill: nginx + php-fpm + postgres)
#   gitlab                    (GitLab omnibus under runit, user-switch stripped)
#   map                       (OSM website: rails + apache/mod_tile + renderd
#                              + 3x postgres + 3x osrm; needs external data)

# --- Roots ------------------------------------------------------------------
# For now everything lives under /scratch/czhai for testing. When this is
# stable, move WA_BASE_PERSIST (sandboxes/SIFs/seed) to
# /projects/kzhou6/czhai/webarena-verified-hopper — scratch may be purged.
WA_BASE="${WA_BASE:-/scratch/${USER:-czhai}/webarena-verified}"
WA_ROOT="${WA_ROOT:-$WA_BASE/persist}"       # sandboxes, SIFs, seed state
WA_SCRATCH="${WA_SCRATCH:-$WA_BASE/runtime}" # live state, run dirs, logs, caches

WA_SANDBOX_DIR="${WA_SANDBOX_DIR:-$WA_ROOT/sandboxes}" # patched apptainer sandboxes
WA_IMAGE_DIR="${WA_IMAGE_DIR:-$WA_ROOT/images}"        # packed SIFs
WA_SEED_DIR="${WA_SEED_DIR:-$WA_ROOT/seed}"            # pristine writable state (for reset)
WA_STATE_DIR="${WA_STATE_DIR:-$WA_SCRATCH/state}"      # live writable state (mysql, magento var, ...)
WA_RUN_DIR="${WA_RUN_DIR:-$WA_SCRATCH/run}"            # pid files, sockets
WA_LOG_DIR="${WA_LOG_DIR:-$WA_SCRATCH/logs}"
WA_URLS_DIR="${WA_URLS_DIR:-$WA_SCRATCH/urls.d}"       # per-site URL fragments

# Map external data (tile db, nominatim db, osrm graphs) - large, download once.
# Lives under persist (candidate for /projects once stable).
WA_MAP_DATA_DIR="${WA_MAP_DATA_DIR:-$WA_ROOT/mapdata}"

# Apptainer cache/tmp on scratch (never $HOME on Hopper)
export APPTAINER_CACHEDIR="${APPTAINER_CACHEDIR:-$WA_SCRATCH/apptainer-cache}"
export APPTAINER_TMPDIR="${APPTAINER_TMPDIR:-$WA_SCRATCH/apptainer-tmp}"

# --- Apptainer binary ---------------------------------------------------------
# Self-installed apptainer >= 1.5 (Agent-Bench standard): bundled squashfuse_ll
# /fuse2fs/fusermount3 mean SIF FUSE-mounting WORKS on Hopper nodes (it did
# not under the retired 1.4.1 module -- the old "SIFs broken, use sandboxes"
# note is obsolete). Conda env activation rebuilds PATH, so prepend here:
# every toolkit script sources this file.
APPTAINER_BINDIR="${APPTAINER_BINDIR:-/projects/kzhou6/czhai/apptainer/bin}"
[ -d "$APPTAINER_BINDIR" ] && case ":$PATH:" in
  *":$APPTAINER_BINDIR:"*) ;;
  *) export PATH="$APPTAINER_BINDIR:$PATH" ;;
esac
WA_APPTAINER="${WA_APPTAINER:-apptainer}"
wa_require_apptainer() {
  command -v "$WA_APPTAINER" >/dev/null 2>&1 && return 0
  # Failsafe: retired system module (slow: no bundled FUSE -> sandbox unpacks)
  if command -v module >/dev/null 2>&1 || [ -f /etc/profile.d/lmod.sh ]; then
    set +u
    [ -f /etc/profile.d/lmod.sh ] && source /etc/profile.d/lmod.sh
    module load hosts/hopper apptainer/1.4.1 2>/dev/null || true
    set -u
  fi
  command -v "$WA_APPTAINER" >/dev/null 2>&1 && {
    echo "[wa] WARNING: using fallback $($WA_APPTAINER --version 2>/dev/null); self-install missing at $APPTAINER_BINDIR" >&2
    return 0
  }
  echo "[wa] ERROR: apptainer not found (checked $APPTAINER_BINDIR and the 1.4.1 module)." >&2
  echo "[wa]   Fix: install-unprivileged.sh $APPTAINER_BINDIR/.. or set APPTAINER_BINDIR=" >&2
  return 1
}

# --- Sites ------------------------------------------------------------------
# All supported sites (wikipedia intentionally excluded).
WA_ALL_SITES="shopping shopping_admin reddit gitlab map"

wa_site_kind() {
  # wa_site_kind <site> -> magento | reddit | gitlab | map
  case "$1" in
    shopping | shopping_admin) printf 'magento' ;;
    reddit) printf 'reddit' ;;
    gitlab) printf 'gitlab' ;;
    map) printf 'map' ;;
    *)
      echo "unknown site: $1" >&2
      return 1
      ;;
  esac
}

# --- Images -----------------------------------------------------------------
WA_IMG_TAG="${WA_IMG_TAG:-latest}"
WA_SHOPPING_DOCKER="${WA_SHOPPING_DOCKER:-docker://am1n3e/webarena-verified-shopping:$WA_IMG_TAG}"
WA_SHOPPING_ADMIN_DOCKER="${WA_SHOPPING_ADMIN_DOCKER:-docker://am1n3e/webarena-verified-shopping_admin:$WA_IMG_TAG}"
WA_REDDIT_DOCKER="${WA_REDDIT_DOCKER:-docker://am1n3e/webarena-verified-reddit:$WA_IMG_TAG}"
WA_GITLAB_DOCKER="${WA_GITLAB_DOCKER:-docker://am1n3e/webarena-verified-gitlab:$WA_IMG_TAG}"
WA_MAP_DOCKER="${WA_MAP_DOCKER:-docker://am1n3e/webarena-verified-map:$WA_IMG_TAG}"

wa_site_docker() {
  case "$1" in
    shopping) printf '%s' "$WA_SHOPPING_DOCKER" ;;
    shopping_admin) printf '%s' "$WA_SHOPPING_ADMIN_DOCKER" ;;
    reddit) printf '%s' "$WA_REDDIT_DOCKER" ;;
    gitlab) printf '%s' "$WA_GITLAB_DOCKER" ;;
    map) printf '%s' "$WA_MAP_DOCKER" ;;
    *)
      echo "unknown site: $1" >&2
      return 1
      ;;
  esac
}

# Map external data tarballs (same sources webarena-verified uses)
WA_MAP_DATA_URLS="${WA_MAP_DATA_URLS:-\
https://webarena-map-server-data.s3.amazonaws.com/osm_tile_server.tar \
https://webarena-map-server-data.s3.amazonaws.com/nominatim_volumes.tar \
https://webarena-map-server-data.s3.amazonaws.com/osrm_routing.tar}"

# --- Host / URL -------------------------------------------------------------
# Hostname/IP that agents will use to reach the sites. Under SLURM, run the
# launcher on the compute node so this resolves to that node.
WA_HOST="${WA_HOST:-$(hostname -I 2>/dev/null | awk '{print $1}')}"

# --- Ports (all >1024, all distinct so sites can share one node) -------------
# shopping (storefront): external HTTP kept at the webarena-verified default 7770
SHOPPING_HTTP_PORT="${SHOPPING_HTTP_PORT:-7770}"
SHOPPING_MYSQL_PORT="${SHOPPING_MYSQL_PORT:-17771}"
SHOPPING_REDIS_PORT="${SHOPPING_REDIS_PORT:-17772}"
SHOPPING_FPM_PORT="${SHOPPING_FPM_PORT:-17773}"
SHOPPING_MAIL_SMTP_PORT="${SHOPPING_MAIL_SMTP_PORT:-17774}"
SHOPPING_MAIL_HTTP_PORT="${SHOPPING_MAIL_HTTP_PORT:-17775}"
SHOPPING_ES_HTTP_PORT="${SHOPPING_ES_HTTP_PORT:-17776}"
SHOPPING_ES_TRANSPORT_PORT="${SHOPPING_ES_TRANSPORT_PORT:-17777}"
SHOPPING_WITH_ES="${SHOPPING_WITH_ES:-1}" # storefront search needs ES

# shopping_admin: external HTTP kept at the webarena-verified default 7780
SHOPPING_ADMIN_HTTP_PORT="${SHOPPING_ADMIN_HTTP_PORT:-7780}"
SHOPPING_ADMIN_MYSQL_PORT="${SHOPPING_ADMIN_MYSQL_PORT:-17781}"
SHOPPING_ADMIN_REDIS_PORT="${SHOPPING_ADMIN_REDIS_PORT:-17782}"
SHOPPING_ADMIN_FPM_PORT="${SHOPPING_ADMIN_FPM_PORT:-17783}"
SHOPPING_ADMIN_MAIL_SMTP_PORT="${SHOPPING_ADMIN_MAIL_SMTP_PORT:-17784}"
SHOPPING_ADMIN_MAIL_HTTP_PORT="${SHOPPING_ADMIN_MAIL_HTTP_PORT:-17785}"
SHOPPING_ADMIN_ES_HTTP_PORT="${SHOPPING_ADMIN_ES_HTTP_PORT:-17786}"
SHOPPING_ADMIN_ES_TRANSPORT_PORT="${SHOPPING_ADMIN_ES_TRANSPORT_PORT:-17787}"
SHOPPING_ADMIN_WITH_ES="${SHOPPING_ADMIN_WITH_ES:-0}" # webarena-verified drops ES for admin

# reddit (Postmill): external HTTP kept at the WebArena default 9999.
# Internal services moved to 1999x so reddit can share a node with the others.
REDDIT_HTTP_PORT="${REDDIT_HTTP_PORT:-9999}"
REDDIT_PG_PORT="${REDDIT_PG_PORT:-19991}"
REDDIT_FPM_PORT="${REDDIT_FPM_PORT:-19992}"

# gitlab (omnibus): external HTTP kept at the WebArena default 8023.
# Internal endpoints are the omnibus defaults, mostly unix sockets under
# /var/opt/gitlab, EXCEPT puma which also listens on 127.0.0.1:8080.
# => do not co-locate gitlab with map (apache internal 8080) on one node.
GITLAB_HTTP_PORT="${GITLAB_HTTP_PORT:-8023}"

# map (OSM website): external HTTP kept at the WebArena convention 3030.
# The image internally hard-wires: apache 8080 (loopback, server-side URLs are
# baked into rails settings/assets), nominatim vhost 8085, rails 3000,
# osrm 5000-5002, postgres 5432/5433/5434. These are NOT remapped (too many
# baked references) — run map on a node where those ports are free, ideally
# its own node.
MAP_HTTP_PORT="${MAP_HTTP_PORT:-3030}"
MAP_INTERNAL_HTTP_PORT=8080 # do not change: baked into rails assets/settings

# --- Resource tuning (mirrors the verified images' custom entrypoint) --------
WA_ES_JAVA_OPTS="${WA_ES_JAVA_OPTS:--Xms512m -Xmx512m}"
WA_MYSQL_BUFFER_POOL="${WA_MYSQL_BUFFER_POOL:-512M}"
WA_MYSQL_MAX_CONNECTIONS="${WA_MYSQL_MAX_CONNECTIONS:-50}"

# --- Helpers ------------------------------------------------------------------
wa_site_var() {
  # wa_site_var <site> <SUFFIX> -> value of e.g. SHOPPING_ADMIN_HTTP_PORT
  local prefix
  prefix="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
  eval "printf '%s' \"\${${prefix}_$2:-}\""
}

wa_sandbox() { printf '%s' "$WA_SANDBOX_DIR/${1}_verified_rootless"; }
wa_sif() { printf '%s' "$WA_IMAGE_DIR/${1}_verified_rootless.sif"; }

wa_check_site() {
  local s
  for s in $WA_ALL_SITES; do
    [ "$1" = "$s" ] && return 0
  done
  echo "usage: $0 ... {${WA_ALL_SITES// /|}}" >&2
  exit 1
}

wa_ensure_dirs() {
  mkdir -p "$WA_SANDBOX_DIR" "$WA_IMAGE_DIR" "$WA_SEED_DIR" \
    "$WA_STATE_DIR" "$WA_RUN_DIR" "$WA_LOG_DIR" "$WA_URLS_DIR" \
    "$APPTAINER_CACHEDIR" "$APPTAINER_TMPDIR"
}

wa_site_url() {
  # wa_site_url <site> -> the URL agents should use
  local port
  port="$(wa_site_var "$1" HTTP_PORT)"
  case "$1" in
    shopping_admin) printf 'http://%s:%s/admin' "$WA_HOST" "$port" ;;
    *) printf 'http://%s:%s' "$WA_HOST" "$port" ;;
  esac
}

wa_health_path() {
  # health-check path per site (against 127.0.0.1:<http_port>)
  case "$1" in
    shopping) printf '/customer/account/login' ;;
    shopping_admin) printf '/admin' ;;
    reddit) printf '/' ;;
    gitlab) printf '/users/sign_in' ;;
    map) printf '/' ;;
  esac
}

wa_health_timeout() {
  # per-site startup budget in seconds (gitlab/map are slow to come up)
  case "$1" in
    gitlab) printf '900' ;;
    map) printf '600' ;;
    *) printf '300' ;;
  esac
}
