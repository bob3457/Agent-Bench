#!/bin/bash
# prebake_harbor_sifs.sh (v2.3) -- bake Harbor's in-container runtime deps into
# cached SIFs so trials on Hopper don't depend on apt egress or the 64 MiB
# --writable-tmpfs overlay at bootstrap time.
#
# v2.3: bake AGENT runtimes too (node + @openai/codex + claude-code).
#   Verified failure without this (job 8882353, 2026-07-10): no npm in the
#   image -> harbor's codex installer falls back to the nvm curl|bash
#   bootstrap, which dies in-container ("Error: NVM failed to load") -- and
#   even with node baked, the stock path would re-`npm install -g` at trial
#   time (registry egress + un-pins the version). With the BINARIES baked,
#   harbor's own _installed_*_satisfies_version() check (verified in 0.16.1
#   agents/installed/codex.py: install() returns early when `codex --version`
#   exits 0) makes trial-time install a zero-network no-op. The node dist
#   tarball is staged once on the host and extracted into the rootfs at
#   %setup, so builds need npmjs egress only (for the agent packages).
#   Knobs: BAKE_AGENTS=0 to disable; NODE_VERSION / CODEX_VERSION /
#   CLAUDE_CODE_VERSION to pin (PIN for benchmark runs -- 'latest' drifts).
#   NOTE: v2.3's is_baked also checks the agent binaries, so every pre-v2.3
#   SIF reports "not baked" until a --all-cached pass rebakes it.
#
# v2 rewrite: uses `apptainer build --fakeroot` with a generated def file,
# which requires the self-installed apptainer >= 1.5 (bundled FUSE tools) and
# `fakeroot` on PATH. Under the fakeroot command, dpkg's chown calls succeed
# at build time, so v1's entire sandbox-extract -> in-sandbox apt -> chgrp/
# setgid normalize -> repack cycle collapses into one build, and the
# dpkg-deb -x fallback for tmux/libutempter0 is no longer needed.
#
# v2.2: route archive+security (both schemes) to mirrors.edge.kernel.org.
#   Canonical's 91.189.92.x pool stalls/drops from Hopper under load ("Could
#   not wait for server fd - select (11)") regardless of fakeroot variant;
#   localimage rebakes carry https:// sources from prior bakes, so the
#   rewrite must match https too. sysv tripwire made comment-aware.
#
# v2.1 changes:
#   - apt: try https mirrors first (kernel.org for archive; compute-node
#     egress may be 443-only), FALL BACK to stock http if https update fails
#     (login nodes have http; archive.ubuntu.com https is chronically flaky).
#   - apt: retries=5 + 30s timeouts on update/install.
#   - fakeroot: MUST be the -tcp variant. The sysv variant's SysV IPC breaks
#     apt's method-handler IPC inside apptainer build namespaces with
#     "Could not wait for server fd - select (11: EAGAIN)". On Hopper use the
#     wrapper at /projects/kzhou6/czhai/tools/bin/fakeroot (EPEL rpm2cpio
#     extract, execs fakeroot-tcp/faked-tcp). conda-forge does NOT package
#     fakeroot -- the old hint was wrong.
#
# Harbor cache contract (verified in harbor 0.15.0 + 0.16.1 source):
#   cache file = <image with '/' and ':' -> '_'>.sif ; if the file exists it
#   is used verbatim, guarded by flock on <file>.lock. We take the same lock
#   and replace the file atomically.
#
# Usage (run where egress works -- login node or egress-enabled compute node,
# with /projects/kzhou6/czhai/tools/bin on PATH so `fakeroot` resolves):
#   bash setup/prebake_harbor_sifs.sh alexgshaw/adaptive-rejection-sampler:20251031
#   bash setup/prebake_harbor_sifs.sh --all-cached          # rebake every SIF in cache
#   bash setup/prebake_harbor_sifs.sh --from-tasks ~/.cache/harbor/tasks
#   FORCE=1 bash setup/prebake_harbor_sifs.sh ...           # rebake even if baked

set -uo pipefail

SCRATCH_DIR="${SCRATCH_DIR:-/scratch/czhai}"
APPTAINER="${APPTAINER:-/projects/kzhou6/czhai/apptainer/bin/apptainer}"
TOOLS_BIN="${TOOLS_BIN:-/projects/kzhou6/czhai/tools/bin}"
SIF_CACHE_DIR="${SIF_CACHE_DIR:-$SCRATCH_DIR/.harbor_sif_cache}"
export APPTAINER_CACHEDIR="${APPTAINER_CACHEDIR:-$SCRATCH_DIR/.apptainer_cache}"
export APPTAINER_TMPDIR="${APPTAINER_TMPDIR:-$SCRATCH_DIR/tmp}"
FORCE="${FORCE:-0}"

# --- v2.3: agent runtime baking ----------------------------------------------
BAKE_AGENTS="${BAKE_AGENTS:-1}"
NODE_VERSION="${NODE_VERSION:-22.14.0}"                            # needs glibc >= 2.28 (Ubuntu 20.04+)
NODE_DIST_DIR="${NODE_DIST_DIR:-/projects/kzhou6/czhai/node_dist}" # NOT scratch
NODE_TARBALL="$NODE_DIST_DIR/node-v$NODE_VERSION-linux-x64.tar.gz"
# PIN these for benchmark sweeps: 'latest' resolves at BAKE time, so SIFs
# baked on different days can carry different agent versions.
CODEX_VERSION="${CODEX_VERSION:-latest}"
CLAUDE_CODE_VERSION="${CLAUDE_CODE_VERSION:-latest}"

# All deps in one list now -- fakeroot builds install libutempter0/tmux
# cleanly (verified 2026-07-08), so nothing is "best-effort" anymore.
APT_PKGS="python3 python3-venv python3-pip curl procps ripgrep ca-certificates tmux asciinema"

mkdir -p "$SIF_CACHE_DIR" "$APPTAINER_TMPDIR"

# Site modules export APPTAINER_BINDPATH (/groups etc.); those mounts fail
# during builds. Clear the env vars; the def file's %setup also pre-creates
# /groups in the rootfs as belt-and-suspenders (and the self-install's own
# apptainer.conf should have site bind paths commented out).
unset APPTAINER_BINDPATH SINGULARITY_BINDPATH APPTAINER_BIND SINGULARITY_BIND 2>/dev/null || true

# fakeroot wrapper dir (see v2.1 note in header)
[ -d "$TOOLS_BIN" ] && export PATH="$TOOLS_BIN:$PATH"

[ -x "$APPTAINER" ] || {
  echo "ERROR: $APPTAINER not found/executable"
  exit 1
}
command -v fakeroot >/dev/null 2>&1 || {
  echo "ERROR: fakeroot not on PATH."
  echo "  On Hopper: use the wrapper at $TOOLS_BIN/fakeroot (fakeroot-tcp from"
  echo "  EPEL rpm2cpio extract). conda-forge does NOT package fakeroot."
  exit 1
}
fakeroot whoami 2>/dev/null | grep -q '^root$' || {
  echo "ERROR: 'fakeroot whoami' did not report root -- wrapper broken?"
  echo "  ($(command -v fakeroot))"
  exit 1
}
# sysv-variant tripwire: apt inside the build dies with
# "Could not wait for server fd - select (11)" under fakeroot-sysv.
if grep -q '^[^#]*fakeroot-sysv' "$(command -v fakeroot)" 2>/dev/null; then
  echo "WARNING: fakeroot wrapper appears to use the -sysv variant; apt will"
  echo "  likely fail inside the build. Switch the wrapper to fakeroot-tcp."
fi

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

# Node dist tarball: staged ONCE on the host, then host-extracted into every
# rootfs at %setup -- no in-container tooling or network needed for node
# itself. Lives under /projects (scratch is purge-eligible).
if [ "$BAKE_AGENTS" = "1" ] && [ ! -f "$NODE_TARBALL" ]; then
  mkdir -p "$NODE_DIST_DIR"
  echo "staging node v$NODE_VERSION -> $NODE_TARBALL"
  curl -fL --retry 3 -o "$NODE_TARBALL.part" \
    "https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION-linux-x64.tar.gz" &&
    mv "$NODE_TARBALL.part" "$NODE_TARBALL" || {
    rm -f "$NODE_TARBALL.part"
    echo "FATAL: node tarball download failed (needs nodejs.org egress ONCE;"
    echo "  run from a login node, or pre-place the tarball at $NODE_TARBALL,"
    echo "  or BAKE_AGENTS=0 to skip agent baking)"
    exit 1
  }
fi

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
  local checks='command -v python3 >/dev/null 2>&1 &&
        [ -x /opt/harbor-server/bin/python3 ] &&
        /opt/harbor-server/bin/python3 -c "import uvicorn, fastapi" 2>/dev/null &&
        command -v curl >/dev/null 2>&1'
  if [ "$BAKE_AGENTS" = "1" ]; then
    # v2.3: agent runtimes too. Pre-v2.3 SIFs fail this -> get rebaked.
    checks="$checks &&
        command -v node >/dev/null 2>&1 &&
        command -v npm >/dev/null 2>&1 &&
        command -v codex >/dev/null 2>&1 &&
        command -v claude >/dev/null 2>&1"
  fi
  "$APPTAINER" exec --no-mount bind-paths --containall "$1" bash -c "$checks" >/dev/null 2>&1
}

write_def() { # <def path> <bootstrap: localimage|docker> <from>
  # v2.3 conditional sections. Escaping convention matches the heredoc below:
  # values expanded NOW are unescaped; text that must survive into the def
  # for build-time execution escapes its \$ (and \${APPTAINER_ROOTFS}).
  local NODE_SETUP="" AGENT_POST=""
  if [ "$BAKE_AGENTS" = "1" ]; then
    NODE_SETUP="
    # v2.3: node v$NODE_VERSION host-extracted into /usr/local (npm -g's
    # default prefix), zero in-build egress. musl images swap it in %post.
    mkdir -p \${APPTAINER_ROOTFS}/usr/local
    tar -xzf \"$NODE_TARBALL\" --no-same-owner --strip-components=1 -C \${APPTAINER_ROOTFS}/usr/local"
    AGENT_POST="
    # --- v2.3: bake agent runtimes. With the binaries present, harbor's
    # _installed_*_satisfies_version() short-circuits install() at trial
    # time -> no nvm bootstrap, no npm registry egress from compute nodes.
    if ldd --version 2>&1 | grep -qi musl || [ -f /etc/alpine-release ]; then
        # glibc node tarball can't run on musl -- swap for apk's nodejs
        rm -f /usr/local/bin/node /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack
        rm -rf /usr/local/lib/node_modules /usr/local/include/node
        apk add --no-cache nodejs npm
    fi
    export PATH=\"/usr/local/bin:\$PATH\"
    if ! node --version >/dev/null 2>&1; then
        echo '[prebake] WARNING: node not runnable (glibc < 2.28?) -- agents will need network installs at trial time' >&2
    else
        npm install -g --prefix /usr/local \"@openai/codex@$CODEX_VERSION\" \"@anthropic-ai/claude-code@$CLAUDE_CODE_VERSION\"
        codex --version && claude --version
    fi"
  fi
  cat >"$1" <<EOF
Bootstrap: $2
From: $3

%setup
    # Runs on the host against the extracted rootfs, before any mounts.
    # CA bundle seed (see header) + /groups mount point for site binds.
    mkdir -p \${APPTAINER_ROOTFS}/etc/ssl/certs \${APPTAINER_ROOTFS}/usr/lib/ssl \${APPTAINER_ROOTFS}/groups
    cat "$HOST_BUNDLE" > \${APPTAINER_ROOTFS}/etc/ssl/certs/ca-certificates.crt
    [ -e \${APPTAINER_ROOTFS}/usr/lib/ssl/certs ] || ln -sfn /etc/ssl/certs \${APPTAINER_ROOTFS}/usr/lib/ssl/certs
$NODE_SETUP

%post
    set -e
    export DEBIAN_FRONTEND=noninteractive
    if command -v apt-get >/dev/null 2>&1; then
        # Runtime apt (harbor bootstrap, agent installers, task commands)
        # still runs in the single-uid userns: persist the _apt sandbox
        # disable. Harmless during this fakeroot build; essential later.
        mkdir -p /etc/apt/apt.conf.d
        echo 'APT::Sandbox::User "root";' > /etc/apt/apt.conf.d/99harbor-userns
        # Baked-in retry/timeout defaults (apply to runtime apt too).
        printf 'Acquire::Retries "5";\nAcquire::http::Timeout "30";\nAcquire::https::Timeout "30";\n' \
            > /etc/apt/apt.conf.d/99harbor-net
        # Mirror strategy: prefer https (compute-node egress may be 443-only;
        # archive.ubuntu.com https is chronically flaky, so archive -> kernel
        # .org edge mirror), but FALL BACK to stock http mirrors if the https
        # update fails (login nodes have working http).
        sed -i -E 's#https?://(archive|security)\.ubuntu\.com/ubuntu#https://mirrors.edge.kernel.org/ubuntu#g' /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources 2>/dev/null || true
        sed -i 's|http://|https://|g' /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources 2>/dev/null || true
        if ! apt-get update; then
            echo "[prebake] https mirrors failed; reverting to stock http mirrors" >&2
            sed -i 's|https://mirrors.edge.kernel.org/ubuntu|http://archive.ubuntu.com/ubuntu|g; s|https://archive.ubuntu.com|http://archive.ubuntu.com|g; s|https://security.ubuntu.com|http://security.ubuntu.com|g' \
                /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources 2>/dev/null || true
            apt-get update
        fi
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
$AGENT_POST
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
    # %post exit 42 = no python3 and no package manager -> EXCLUDE_TASKS.
    # "Could not wait for server fd - select (11)" during apt = fakeroot-sysv
    # in use; switch the wrapper to the -tcp variant (see header).
    echo "[$name] build FAILED (rc=$rc) -- 'exit status 42' => EXCLUDE_TASKS;"
    echo "[$name]   'Could not wait for server fd' => fakeroot-tcp needed (see header)"
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
