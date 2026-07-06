#!/usr/bin/env bash
# 01_fetch_images.sh - pull the webarena-verified docker images from Docker Hub
# into user-owned Apptainer sandboxes.
#
# Run this somewhere with outbound network access (Hopper login node, or a
# compute node if egress is allowed). No root / no subuid needed: building a
# sandbox as a normal user makes every file user-owned, which is exactly what
# the rootless runtime wants.
#
# Usage:
#   ./01_fetch_images.sh                # both sites
#   ./01_fetch_images.sh shopping_admin # one site

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=wa_common.sh
source "$SCRIPT_DIR/wa_common.sh"

wa_ensure_dirs

fetch_one() {
  local site="$1" src sandbox
  case "$site" in
    shopping) src="$WA_SHOPPING_DOCKER" ;;
    shopping_admin) src="$WA_SHOPPING_ADMIN_DOCKER" ;;
    *)
      echo "unknown site: $site" >&2
      exit 1
      ;;
  esac
  sandbox="$(wa_sandbox "$site")"

  if [ -d "$sandbox" ]; then
    echo "[fetch] sandbox already exists, skipping: $sandbox"
    echo "        (rm -rf it to re-pull)"
    return 0
  fi

  echo "[fetch] $src -> $sandbox"
  # --fix-perms makes all dirs user-writable so the patch step can edit configs.
  apptainer build --fix-perms --sandbox "$sandbox" "$src"
  echo "[fetch] done: $sandbox"
}

if [ "$#" -eq 0 ]; then
  fetch_one shopping
  fetch_one shopping_admin
else
  for s in "$@"; do fetch_one "$s"; done
fi
