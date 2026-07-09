#!/bin/bash
# prebake_harbor_sifs.sh (v2) -- bake Harbor's in-container runtime deps into
# cached SIFs so trials on Hopper don't depend on apt egress or the 64 MiB
# --writable-tmpfs overlay at bootstrap time.
#
# v2 rewrite: uses `apptainer build --fakeroot` with a generated def file,
# which requires the self-installed apptainer >= 1.5 (bundled FUSE tools) and
# conda-forge `fakeroot` on PATH. Under the fakeroot command, dpkg's chown
# calls succeed at build time, so v1's entire sandbox-extract -> in-sandbox
# apt -> chgrp/setgid normalize -> repack cycle collapses into one build, and
# the dpkg-deb -x fallback for tmux/libutempter0 is no longer needed.
#
# Harbor cache contract (verified in harbor 0.15.0 + 0.16.1 source):
#   cache file = <image with '/' and ':' -> '_'>.sif ; if the file exists it
#   is used verbatim, guarded by flock on <file>.lock. We take the same lock
#   and replace the file atomically.
#
# Usage (run where egress works -- login node or egress-enabled compute node,
# with the conda env active so `fakeroot` is on PATH):
#   bash setup/prebake_harbor_sifs.sh alexgshaw/adaptive-rejection-sampler:20251031
#   bash setup/prebake_harbor_sifs.sh --all-cached          # rebake every SIF in cache
#   bash setup/prebake_harbor_sifs.sh --from-tasks ~/.cache/harbor/tasks
#   FORCE=1 bash setup/prebake_harbor_sifs.sh ...           # rebake even if baked

set -uo pipefail

SCRATCH_DIR="${SCRATCH_DIR:-/scratch/czhai}"
APPTAINER="${APPTAINER:-/scratch/czhai/apptainer/bin/apptainer}"
SIF_CACHE_DIR="${SIF_CACHE_DIR:-$SCRATCH_DIR/.harbor_sif_cache}"
export APPTAINER_CACHEDIR="${APPTAINER_CACHEDIR:-$SCRATCH_DIR/.apptainer_cache}"
export APPTAINER_TMPDIR="${APPTAINER_TMPDIR:-$SCRATCH_DIR/tmp}"
FORCE="${FORCE:-0}"

# All deps in one list now -- fakeroot builds install libutempter0/tmux
# cleanly (verified 2026-07-08), so nothing is "best-effort" anymore.
APT_PKGS="python3 python3-venv python3-pip curl procps ripgrep ca-certificates tmux asciinema"

mkdir -p "$SIF_CACHE_DIR" "$APPTAINER_TMPDIR"

# Site modules export APPTAINER_BINDPATH (/groups etc.); those mounts fail
# during builds. Clear the env vars; the def file's %setup also pre-creates
# /groups in the rootfs as belt-and-suspenders (and the self-install's own
# apptainer.conf should have site bind paths commented out).
unset APPTAINER_BINDPATH SINGULARITY_BINDPATH APPTAINER_BIND SINGULARITY_BIND 2>/dev/null || true

[ -x "$APPTAINER" ] || {
  echo "ERROR: $APPTAINER not found/executable"
  exit 1
}
command -v fakeroot >/dev/null 2>&1 || {
  echo "ERROR: fakeroot not on PATH (conda install -c conda-forge fakeroot; activate the env)"
  exit 1
}

# Host CA bundle: some TB images ship NO trust roots, and fixing that
# in-image is a chicken-and-egg (apt over https needs certs to fetch
# ca-certificates). Seed the host's bundle via %setup before %post runs.
HOST_BUNDLE=""
for c in /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem \
  /etc/pki/tls/certs/ca-bundle.crt \
  /etc/ssl/certs/ca-certificates.crt \
  /etc/ssl/certs/ca-bundle.crt; do
  [ -r "$c" ] && HOST_BUNDLE="$c" && break
done
[ -n "$HOST_BUNDLE" ] || {
  echo "FATAL: no readable host CA bundle on $(hostname)"
  exit 1
}

# --- collect target images -------------------------------------------------
declare -a IMAGES=()
mode="${1:-}"
case "$mode" in
  --all-cached)
    for sif in "$SIF_CACHE_DIR"/*.sif; do
      [ -e "$sif" ] && IMAGES+=("sif:$sif")
    done
    ;;
  --from-tasks)
    task_dir="${2:?--from-tasks needs a directory of harbor task dirs}"
    while IFS= read -r img; do IMAGES+=("$img"); done < <(
      grep -rh '^docker_image' "$task_dir" --include=task.toml 2>/dev/null |
        sed 's/.*=\s*"\(.*\)"/\1/' | sort -u
    )
    ;;
  "")
    echo "usage: $0 <image[:tag] ...> | --all-cached | --from-tasks <dir>"
    exit 1
    ;;
  *) IMAGES=("$@") ;;
esac
[ "${#IMAGES[@]}" -gt 0 ] || {
  echo "no images to bake"
  exit 1
}
echo "baking ${#IMAGES[@]} image(s) into $SIF_CACHE_DIR"

# --- helpers -----------------------------------------------------------------
sif_path_for() { # image -> cache path (harbor's safe_name scheme)
  local img="$1"
  case "$img" in *:*) ;; *) img="$img:latest" ;; esac
  echo "$SIF_CACHE_DIR/$(echo "$img" | tr '/:' '__').sif"
}

is_baked() { # sif -> 0 if all runtime deps present
  "$APPTAINER" exec --no-mount bind-paths --containall "$1" bash -c '
        command -v python3 >/dev/null 2>&1 &&
        [ -x /opt/harbor-server/bin/python3 ] &&
        /opt/harbor-server/bin/python3 -c "import uvicorn, fastapi" 2>/dev/null &&
        command -v curl >/dev/null 2>&1' >/dev/null 2>&1
}

write_def() { # <def path> <bootstrap: localimage|docker> <from>
  cat >"$1" <<EOF
Bootstrap: $2
From: $3

%setup
    # Runs on the host against the extracted rootfs, before any mounts.
    # CA bundle seed (see header) + /groups mount point for site binds.
    mkdir -p \${APPTAINER_ROOTFS}/etc/ssl/certs \${APPTAINER_ROOTFS}/usr/lib/ssl \${APPTAINER_ROOTFS}/groups
    cat "$HOST_BUNDLE" > \${APPTAINER_ROOTFS}/etc/ssl/certs/ca-certificates.crt
    [ -e \${APPTAINER_ROOTFS}/usr/lib/ssl/certs ] || ln -sfn /etc/ssl/certs \${APPTAINER_ROOTFS}/usr/lib/ssl/certs

%post
    set -e
    export DEBIAN_FRONTEND=noninteractive
    if command -v apt-get >/dev/null 2>&1; then
        # Runtime apt (harbor bootstrap, agent installers, task commands)
        # still runs in the single-uid userns: persist the _apt sandbox
        # disable. Harmless during this fakeroot build; essential later.
        mkdir -p /etc/apt/apt.conf.d
        echo 'APT::Sandbox::User "root";' > /etc/apt/apt.conf.d/99harbor-userns
        # Mirrors default to plain http :80; compute-node egress may be 443-only.
        sed -i "s|http://|https://|g" /etc/apt/sources.list 2>/dev/null || true
        sed -i "s|http://|https://|g" /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources 2>/dev/null || true
        apt-get -o Acquire::Retries=3 update
        apt-get install -y --no-install-recommends $APT_PKGS
        update-ca-certificates 2>/dev/null || true
        rm -rf /var/lib/apt/lists/*
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y python3 python3-pip tmux curl procps-ng ripgrep || dnf install -y python3 curl
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache python3 py3-pip tmux curl procps ripgrep bash
    else
        echo "NO PACKAGE MANAGER -- this image belongs in EXCLUDE_TASKS" >&2
        command -v python3 >/dev/null 2>&1 || exit 42
    fi
    # /usr/bin/python3 must exist by that literal path (bootstrap checks it)
    command -v python3 >/dev/null 2>&1 || exit 42
    [ -x /usr/bin/python3 ] || ln -sf "\$(command -v python3)" /usr/bin/python3
    # Pre-create the harbor server venv exactly where bootstrap expects it
    /usr/bin/python3 -m venv /opt/harbor-server
    /opt/harbor-server/bin/python3 -m pip install --quiet --upgrade pip
    /opt/harbor-server/bin/python3 -m pip install --quiet uvicorn fastapi
    /opt/harbor-server/bin/python3 -c "import uvicorn, fastapi"
    command -v asciinema >/dev/null 2>&1 \\
        || /opt/harbor-server/bin/python3 -m pip install --quiet asciinema || true
EOF
}

bake_one() { # <sif path> [image name for pull]
  local sif="$1" img="${2:-}" name rc=0
  name="$(basename "$sif")"

  if [ "$FORCE" != "1" ] && [ -f "$sif" ] && is_baked "$sif"; then
    echo "[$name] already baked -- skip"
    return 0
  fi

  local work="$APPTAINER_TMPDIR/bake.$name.$$"
  mkdir -p "$work"
  trap 'rm -rf "$work"' RETURN

  # Existing SIF -> rebake in place (localimage); missing -> pull+bake in one
  # step straight from Docker Hub (no separate `apptainer pull`).
  if [ -f "$sif" ]; then
    write_def "$work/bake.def" localimage "$sif"
  else
    [ -n "$img" ] || {
      echo "[$name] missing and no image name to pull"
      return 1
    }
    write_def "$work/bake.def" docker "$img"
  fi

  echo "[$name] building (fakeroot def-file build)..."
  "$APPTAINER" build --fakeroot "$work/new.sif" "$work/bake.def" || rc=$?
  if [ "$rc" -ne 0 ]; then
    # %post exit 42 = no python3 and no package manager -> EXCLUDE_TASKS
    echo "[$name] build FAILED (rc=$rc) -- if the log above shows 'exit status 42', add to EXCLUDE_TASKS"
    return 1
  fi

  # Replace under harbor's own lock so a concurrently starting trial never
  # sees a half-written file.
  (
    exec 9>"$sif.lock"
    flock 9
    mv -f "$work/new.sif" "$sif"
  )
  is_baked "$sif" && echo "[$name] baked OK" || {
    echo "[$name] verify FAILED"
    return 1
  }
}

# --- main loop ---------------------------------------------------------------
fail=0
for entry in "${IMAGES[@]}"; do
  if [[ "$entry" == sif:* ]]; then
    bake_one "${entry#sif:}" || fail=$((fail + 1))
  else
    bake_one "$(sif_path_for "$entry")" "$entry" || fail=$((fail + 1))
  fi
done

echo
echo "done: $((${#IMAGES[@]} - fail)) baked, $fail failed"
[ "$fail" -eq 0 ] || exit 1
