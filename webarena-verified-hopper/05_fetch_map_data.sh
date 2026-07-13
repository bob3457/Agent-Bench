#!/usr/bin/env bash
# 05_fetch_map_data.sh - download and extract the map site's external data
# (tile postgres db, nominatim db + flatnode, osrm routing graphs) into
# $WA_MAP_DATA_DIR. Only needed for the `map` site.
#
# RUN THIS ON THE LOGIN NODE: Hopper compute nodes throttle egress to
# ~50 KiB/s, and these tarballs are huge (hundreds of GB total). Check the
# sizes first if you're short on space:
#
#   ./05_fetch_map_data.sh sizes
#
# Layout produced (mirrors the docker volumes of webarena-verified):
#   $WA_MAP_DATA_DIR/downloads/            the raw .tar files (delete after)
#   $WA_MAP_DATA_DIR/tile-db/              -> /data/database        (rw)
#   $WA_MAP_DATA_DIR/routing/car/          -> /data/routing/car     (ro)
#   $WA_MAP_DATA_DIR/routing/bike/         -> /data/routing/bike    (ro)
#   $WA_MAP_DATA_DIR/routing/foot/         -> /data/routing/foot    (ro)
#   $WA_MAP_DATA_DIR/nominatim-db/         -> /data/nominatim/postgres (rw)
#   $WA_MAP_DATA_DIR/nominatim-flatnode/   -> /data/nominatim/flatnode
#
# Note: tile-db holds the *postgres data dir* that the container expects at
# /data/database/postgres; the tarball's osm-data volume contains a postgres/
# subdirectory, so extracting the volume into tile-db/ gives tile-db/postgres.
#
# Usage:
#   ./05_fetch_map_data.sh            # download (resume-capable) + extract
#   ./05_fetch_map_data.sh sizes      # just print remote Content-Length
#   ./05_fetch_map_data.sh download   # download only
#   ./05_fetch_map_data.sh extract    # extract only (tars already present)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=wa_common.sh
source "$SCRIPT_DIR/wa_common.sh"

DL="$WA_MAP_DATA_DIR/downloads"
CMD="${1:-all}"

fetch_tool() {
  if command -v aria2c >/dev/null 2>&1; then
    printf 'aria2c'
  elif command -v wget >/dev/null 2>&1; then
    printf 'wget'
  else
    printf 'curl'
  fi
}

cmd_sizes() {
  local url len
  for url in $WA_MAP_DATA_URLS; do
    len="$(curl -sI "$url" | tr -d '\r' | awk 'tolower($1)=="content-length:"{print $2}')"
    if [ -n "${len:-}" ]; then
      printf '%12.1f GiB  %s\n' "$(echo "$len" | awk '{print $1/1024/1024/1024}')" "$url"
    else
      printf '%16s  %s\n' "unknown" "$url"
    fi
  done
  echo
  echo "Extraction roughly doubles the peak footprint while a tarball and its"
  echo "extracted copy coexist; delete $DL when done."
}

cmd_download() {
  mkdir -p "$DL"
  local url f tool
  tool="$(fetch_tool)"
  for url in $WA_MAP_DATA_URLS; do
    f="$DL/$(basename "$url")"
    if [ -f "$f" ] && [ ! -f "$f.aria2" ]; then
      echo "[map-data] SKIP (exists): $(basename "$f")"
      continue
    fi
    echo "[map-data] downloading $(basename "$f") via $tool ..."
    case "$tool" in
      aria2c) aria2c -x 8 -s 8 -c --file-allocation=none -d "$DL" -o "$(basename "$f")" "$url" ;;
      wget) wget -c -O "$f" "$url" ;;
      curl) curl -L -C - -o "$f" "$url" ;;
    esac
  done
}

extract_one() { # extract_one <tar> <destdir> <strip> <member>
  local tarball="$1" dest="$2" strip="$3" member="$4"
  if [ -n "$(ls -A "$dest" 2>/dev/null)" ]; then
    echo "[map-data] SKIP (not empty): $dest"
    return 0
  fi
  [ -f "$tarball" ] || {
    echo "[map-data] missing tarball: $tarball (run download first)" >&2
    return 1
  }
  mkdir -p "$dest"
  echo "[map-data] extracting $(basename "$tarball") -> $dest"
  tar -xf "$tarball" -C "$dest" --strip-components="$strip" "$member"
  # Everything must be traversable/writable by our uid for rootless apptainer.
  chmod -R u+rwX "$dest"
}

cmd_extract() {
  mkdir -p "$WA_MAP_DATA_DIR"
  local tile="$DL/osm_tile_server.tar"
  local nom="$DL/nominatim_volumes.tar"
  local osrm="$DL/osrm_routing.tar"

  # tile-db: the docker volume 'osm-data' -> mounted at /data/database.
  # The volume contains a postgres/ subdir (the PG15 tile cluster).
  extract_one "$tile" "$WA_MAP_DATA_DIR/tile-db" 6 \
    'projects/ogma3/docker/volumes/osm-data/_data'

  # osrm routing graphs, one dir per profile
  extract_one "$osrm" "$WA_MAP_DATA_DIR/routing/car" 1 'car'
  extract_one "$osrm" "$WA_MAP_DATA_DIR/routing/bike" 1 'bike'
  extract_one "$osrm" "$WA_MAP_DATA_DIR/routing/foot" 1 'foot'

  # nominatim postgres cluster + flatnode file
  extract_one "$nom" "$WA_MAP_DATA_DIR/nominatim-db" 7 \
    'projects/metis2/docker/docker/volumes/nominatim-data/_data'
  extract_one "$nom" "$WA_MAP_DATA_DIR/nominatim-flatnode" 7 \
    'projects/metis2/docker/docker/volumes/nominatim-flatnode/_data'

  # postgres refuses group/world-accessible data dirs
  chmod 700 "$WA_MAP_DATA_DIR/tile-db/postgres" 2>/dev/null || true
  chmod 700 "$WA_MAP_DATA_DIR/nominatim-db" 2>/dev/null || true

  echo "[map-data] done. You can now delete $DL to reclaim space."
}

case "$CMD" in
  sizes) cmd_sizes ;;
  download) cmd_download ;;
  extract) cmd_extract ;;
  all)
    cmd_download
    cmd_extract
    ;;
  *)
    echo "usage: $0 {all|sizes|download|extract}" >&2
    exit 1
    ;;
esac
