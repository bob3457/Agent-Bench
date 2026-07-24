#!/usr/bin/env bash
set -euo pipefail
TAR_DIR="${1:-/scratch/czhai/tb-arm64/tars}"
SIF_DIR="${2:-/scratch/czhai/tb-arm64/sifs}"
export APPTAINER_CACHEDIR="${APPTAINER_CACHEDIR:-/scratch/czhai/apptainer-cache}"
mkdir -p "$SIF_DIR"
: > "$SIF_DIR/convert_failures.txt"
n=0; f=0
for tar in "$TAR_DIR"/*.tar; do
  task="$(basename "$tar" .tar)"
  sif="$SIF_DIR/$task.sif"
  [ -f "$sif" ] && { echo "[have] $task"; continue; }
  echo "[convert] $task"
  if apptainer build "$sif" "docker-archive://$tar" > /dev/null 2>&1; then
    A="$(apptainer exec "$sif" uname -m 2>/dev/null || echo broken)"
    [ "$A" = "aarch64" ] || { echo "$task wrong-arch:$A" >> "$SIF_DIR/convert_failures.txt"; rm -f "$sif"; f=$((f+1)); continue; }
    n=$((n+1))
  else
    echo "$task convert-failed" >> "$SIF_DIR/convert_failures.txt"
    rm -f "$sif"; f=$((f+1))
  fi
done
echo "converted=$n failed=$f"
[ -s "$SIF_DIR/convert_failures.txt" ] && cat "$SIF_DIR/convert_failures.txt"
