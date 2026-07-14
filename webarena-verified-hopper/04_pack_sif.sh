#!/usr/bin/env bash
# 04_pack_sif.sh - pack a patched sandbox into a SIF for fast, low-metadata
# startup on the parallel filesystem. Optional but recommended.
#
# Run on a compute node (srun -c 16 ...) — mksquashfs is CPU hungry.
#
# Usage: ./04_pack_sif.sh <site>   (any of the sites in wa_common.sh)
#
# Notes:
#   - gitlab's sandbox is very large (tens of GB); packing takes a while and
#     the resulting SIF is still big. Since SIF FUSE mounting is broken on
#     Hopper compute nodes, running the sandbox directly is a fine choice —
#     wa_site.sh falls back to the sandbox automatically if no SIF exists.
#   - Do NOT pack the writable state (mysql/pg data etc.) — that lives in
#     $WA_STATE_DIR and is bind-mounted; 03_prepare_state.sh moved it out.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=wa_common.sh
source "$SCRIPT_DIR/wa_common.sh"

SITE="${1:-}"
wa_check_site "$SITE"
wa_ensure_dirs

SANDBOX="$(wa_sandbox "$SITE")"
SIF="$(wa_sif "$SITE")"
CPUS="${WA_PACK_CPUS:-${SLURM_CPUS_PER_TASK:-8}}"

[ -d "$SANDBOX" ] || {
  echo "sandbox not found: $SANDBOX" >&2
  exit 1
}

export APPTAINER_MKSQUASHFS_OPTS="${APPTAINER_MKSQUASHFS_OPTS:--processors $CPUS}"
export SINGULARITY_MKSQUASHFS_OPTS="${SINGULARITY_MKSQUASHFS_OPTS:--processors $CPUS}"

echo "[pack] $SANDBOX -> $SIF (cpus=$CPUS)"
apptainer build --force "$SIF" "$SANDBOX"
echo "[pack] done: $SIF"
