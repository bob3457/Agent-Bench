#!/usr/bin/env bash
#SBATCH --job-name=wa-verified-sites
#SBATCH --partition=normal
#SBATCH --nodes=1
#SBATCH --cpus-per-task=16
#SBATCH --mem=48G
#SBATCH --time=08:00:00
#SBATCH --output=%x_%j.out
#
# webarena_sites.sbatch - host one or more webarena-verified sites on a Hopper
# compute node for the duration of the job, restoring pristine seed state
# first, and publishing per-site URL fragments so multiple hosting jobs on
# different nodes compose into one config.
#
# Submit:
#   sbatch slurm/webarena_sites.sbatch                       # default set
#   sbatch slurm/webarena_sites.sbatch shopping reddit       # explicit sites
#   sbatch --mem=64G slurm/webarena_sites.sbatch map         # map on own node
#   sbatch --mem=32G slurm/webarena_sites.sbatch gitlab      # gitlab alone
# Then:
#   source $WA_SCRATCH/urls.env
#   # config at $WA_SCRATCH/config.hopper.json
#
# Default site set is everything except map (map needs its external data and
# ideally its own node) — and NEVER put gitlab and map on the same node: both
# use internal port 8080.
#
# Rough memory guide: magento pair ~20G, reddit ~4G, gitlab ~16G, map ~32G.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../wa_common.sh
source "$SCRIPT_DIR/wa_common.sh"
wa_ensure_dirs

SITES="${*:-shopping shopping_admin reddit gitlab}"

# refuse the known-bad co-location
case " $SITES " in
  *" gitlab "*)
    case " $SITES " in
      *" map "*)
        echo "[job] refusing to host gitlab and map on one node (both use internal port 8080)" >&2
        exit 1
        ;;
    esac
    ;;
esac

# Advertise this compute node
WA_HOST="${WA_HOST:-$(hostname -I | awk '{print $1}')}"
export WA_HOST

echo "[job] node=$(hostname) host=$WA_HOST sites=[$SITES]"

# Fresh state + published URL fragment per site
for site in $SITES; do
  "$SCRIPT_DIR/03_prepare_state.sh" restore "$site"
  upper="$(printf '%s' "$site" | tr '[:lower:]' '[:upper:]')"
  echo "export ${upper}=$(wa_site_url "$site")" > "$WA_URLS_DIR/$site.env"
done

# Regenerate the merged urls.env + harness config from all fragments
{
  echo "export WA_HOST=$WA_HOST"
  cat "$WA_URLS_DIR"/*.env 2>/dev/null || true
} > "$WA_SCRATCH/urls.env"
"$SCRIPT_DIR/make_config.sh" > "$WA_SCRATCH/config.hopper.json"
echo "[job] wrote $WA_SCRATCH/urls.env and $WA_SCRATCH/config.hopper.json"

# Launch all sites in the background
declare -a PIDS=()
for site in $SITES; do
  "$SCRIPT_DIR/wa_site.sh" "$site" start > "$WA_LOG_DIR/$site.launcher.log" 2>&1 &
  PIDS+=($!)
done

cleanup() {
  for site in $SITES; do
    "$SCRIPT_DIR/wa_site.sh" "$site" stop || true
  done
}
trap cleanup EXIT

# Wait for each site to answer HTTP (per-site budget; gitlab/map are slow)
wait_http() { # wait_http <site>
  local port path budget tries i=0 code=""
  port="$(wa_site_var "$1" HTTP_PORT)"
  path="$(wa_health_path "$1")"
  budget="$(wa_health_timeout "$1")"
  tries=$((budget / 5))
  while [ "$i" -lt "$tries" ]; do
    code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}${path}" || true)"
    case "$code" in 200 | 302)
      if [ -f "$WA_RUN_DIR/$1/webarena/ready" ]; then
        echo "[job] $1 ready ($code)"
        return 0
      fi
      ;;
    esac
    i=$((i + 1))
    sleep 5
  done
  echo "[job] $1 did not become ready within ${budget}s (last: ${code:-none})" >&2
  return 1
}

for site in $SITES; do
  wait_http "$site"
done

echo "[job] all sites up:"
for site in $SITES; do
  upper="$(printf '%s' "$site" | tr '[:lower:]' '[:upper:]')"
  echo "        ${upper} = $(wa_site_url "$site")"
done

# Block until a site launcher exits or the job is cancelled
wait -n "${PIDS[@]}"
echo "[job] a site launcher exited; shutting down" >&2
exit 1
