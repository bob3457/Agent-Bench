#!/usr/bin/env bash
#SBATCH --job-name=wa-verified-sites
#SBATCH --partition=normal
#SBATCH --nodes=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=24G
#SBATCH --time=08:00:00
#SBATCH --output=%x_%j.out
#
# webarena_sites.sbatch - host shopping + shopping_admin on one Hopper compute
# node for the duration of the job, restoring pristine seed state first.
#
# Submit:   sbatch slurm/webarena_sites.sbatch
# Then:     source $WA_SCRATCH/urls.env   # SHOPPING / SHOPPING_ADMIN URLs
#
# Adjust partition/mem/time for Hopper as needed. 24G is comfortable for
# Magento x2 + one Elasticsearch; 16G is a workable floor.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../wa_common.sh
source "$SCRIPT_DIR/wa_common.sh"
wa_ensure_dirs

# Advertise this compute node
WA_HOST="${WA_HOST:-$(hostname -I | awk '{print $1}')}"
export WA_HOST

echo "[job] node=$(hostname) host=$WA_HOST"

# Fresh state for both sites
"$SCRIPT_DIR/03_prepare_state.sh" restore shopping
"$SCRIPT_DIR/03_prepare_state.sh" restore shopping_admin

# Publish URLs + a ready-made harness config for other jobs/agents
URLS_ENV="$WA_SCRATCH/urls.env"
{
    echo "export WA_HOST=$WA_HOST"
    echo "export SHOPPING=http://${WA_HOST}:${SHOPPING_HTTP_PORT}"
    echo "export SHOPPING_ADMIN=http://${WA_HOST}:${SHOPPING_ADMIN_HTTP_PORT}/admin"
} > "$URLS_ENV"
"$SCRIPT_DIR/make_config.sh" > "$WA_SCRATCH/config.hopper.json"
echo "[job] wrote $URLS_ENV and $WA_SCRATCH/config.hopper.json"

# Launch both sites; if either dies, kill the job so SLURM notices.
"$SCRIPT_DIR/wa_site.sh" shopping start        > "$WA_LOG_DIR/shopping.launcher.log" 2>&1 &
PID_SHOP=$!
"$SCRIPT_DIR/wa_site.sh" shopping_admin start  > "$WA_LOG_DIR/shopping_admin.launcher.log" 2>&1 &
PID_ADMIN=$!

cleanup() {
    "$SCRIPT_DIR/wa_site.sh" shopping stop || true
    "$SCRIPT_DIR/wa_site.sh" shopping_admin stop || true
}
trap cleanup EXIT

# Wait for both to answer HTTP
wait_http() { # wait_http <port> <path> <name>
    local i=0 code=""
    while [ "$i" -lt 120 ]; do
        code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${1}${2}" || true)"
        case "$code" in 200|302) echo "[job] $3 ready ($code)"; return 0 ;; esac
        i=$((i+1)); sleep 5
    done
    echo "[job] $3 did not become ready (last: ${code:-none})" >&2
    return 1
}
wait_http "$SHOPPING_HTTP_PORT" "/customer/account/login" shopping
wait_http "$SHOPPING_ADMIN_HTTP_PORT" "/admin" shopping_admin

echo "[job] both sites up:"
echo "        SHOPPING       = http://${WA_HOST}:${SHOPPING_HTTP_PORT}"
echo "        SHOPPING_ADMIN = http://${WA_HOST}:${SHOPPING_ADMIN_HTTP_PORT}/admin"

# Block until a site process exits or the job is cancelled
wait -n "$PID_SHOP" "$PID_ADMIN"
echo "[job] a site launcher exited; shutting down" >&2
exit 1
