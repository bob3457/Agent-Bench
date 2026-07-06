#!/usr/bin/env bash
# wa_common.sh - shared configuration for webarena-verified on Hopper (rootless
# Apptainer, SLURM, no /etc/subuid). Source this from the other scripts.
#
# Everything is overridable via environment variables. Defaults follow the
# Agent-Bench layout: persistent artifacts under /projects, volatile runtime
# state under scratch.

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

# Apptainer cache/tmp on scratch (never $HOME on Hopper)
export APPTAINER_CACHEDIR="${APPTAINER_CACHEDIR:-$WA_SCRATCH/apptainer-cache}"
export APPTAINER_TMPDIR="${APPTAINER_TMPDIR:-$WA_SCRATCH/apptainer-tmp}"

# --- Images -----------------------------------------------------------------
WA_IMG_TAG="${WA_IMG_TAG:-latest}"
WA_SHOPPING_DOCKER="${WA_SHOPPING_DOCKER:-docker://am1n3e/webarena-verified-shopping:$WA_IMG_TAG}"
WA_SHOPPING_ADMIN_DOCKER="${WA_SHOPPING_ADMIN_DOCKER:-docker://am1n3e/webarena-verified-shopping_admin:$WA_IMG_TAG}"

# --- Host / URL -------------------------------------------------------------
# Hostname/IP that agents will use to reach the sites. Under SLURM, run the
# launcher on the compute node so this resolves to that node.
WA_HOST="${WA_HOST:-$(hostname -I 2>/dev/null | awk '{print $1}')}"

# --- Ports (all >1024, all distinct so both sites share one node) -----------
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

# --- Resource tuning (mirrors the verified images' custom entrypoint) --------
WA_ES_JAVA_OPTS="${WA_ES_JAVA_OPTS:--Xms512m -Xmx512m}"
WA_MYSQL_BUFFER_POOL="${WA_MYSQL_BUFFER_POOL:-512M}"
WA_MYSQL_MAX_CONNECTIONS="${WA_MYSQL_MAX_CONNECTIONS:-50}"

# --- Helpers ------------------------------------------------------------------
wa_site_var() {
  # wa_site_var <site> <SUFFIX> -> value of e.g. SHOPPING_ADMIN_HTTP_PORT
  local prefix
  case "$1" in
    shopping) prefix=SHOPPING ;;
    shopping_admin) prefix=SHOPPING_ADMIN ;;
    *)
      echo "unknown site: $1" >&2
      return 1
      ;;
  esac
  eval "printf '%s' \"\$${prefix}_$2\""
}

wa_sandbox() { printf '%s' "$WA_SANDBOX_DIR/${1}_verified_rootless"; }
wa_sif() { printf '%s' "$WA_IMAGE_DIR/${1}_verified_rootless.sif"; }

wa_check_site() {
  case "$1" in
    shopping | shopping_admin) ;;
    *)
      echo "usage: $0 ... {shopping|shopping_admin}" >&2
      exit 1
      ;;
  esac
}

wa_ensure_dirs() {
  mkdir -p "$WA_SANDBOX_DIR" "$WA_IMAGE_DIR" "$WA_SEED_DIR" \
    "$WA_STATE_DIR" "$WA_RUN_DIR" "$WA_LOG_DIR" \
    "$APPTAINER_CACHEDIR" "$APPTAINER_TMPDIR"
}
