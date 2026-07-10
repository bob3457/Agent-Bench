#!/usr/bin/env bash
# 01_fetch_images.sh - pull the webarena-verified docker images from Docker Hub
# into user-owned Apptainer sandboxes.
#
# Run this somewhere with outbound network access (Hopper login node — compute
# nodes throttle egress to ~50 KiB/s). No root / no subuid needed: building a
# sandbox as a normal user makes every file user-owned, which is exactly what
# the rootless runtime wants.
#
# Approx compressed pull sizes (verified images are squashed): shopping /
# shopping_admin a few GB each, reddit a few GB, gitlab ~15-25 GB,
# map ~10-15 GB. Fetch gitlab and map one at a time.
#
# Usage:
#   ./01_fetch_images.sh                 # all sites (shopping shopping_admin reddit gitlab map)
#   ./01_fetch_images.sh reddit gitlab   # a subset

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=wa_common.sh
source "$SCRIPT_DIR/wa_common.sh"

wa_ensure_dirs

fetch_one() {
  local site="$1" src sandbox
  wa_check_site "$site"
  src="$(wa_site_docker "$site")"
  sandbox="$(wa_sandbox "$site")"

  if [ -d "$sandbox" ]; then
    echo "[fetch] sandbox already exists, skipping: $sandbox"
    echo "        (rm -rf it to re-pull)"
    return 0
  fi

  echo "[fetch] $src -> $sandbox"
  # --fix-perms makes all dirs user-writable so the patch step can edit configs.
  wa_require_apptainer || exit 1
  "$WA_APPTAINER" build --fix-perms --sandbox "$sandbox" "$src"
  echo "[fetch] done: $sandbox"
}

if [ "$#" -eq 0 ]; then
  for s in $WA_ALL_SITES; do fetch_one "$s"; done
else
  for s in "$@"; do fetch_one "$s"; done
fi
