#!/bin/bash
# setup_hopper_deps.sh (v2) -- dependency install + preflight for
# run_terminalbench_harbor.sh on Hopper (rootless SLURM, no Docker, no root).
#
# v2 changes: the system apptainer/1.4.1 module is retired in favor of the
# self-installed apptainer >= 1.5 (bundled squashfuse_ll/fuse2fs/
# fuse-overlayfs), and conda-forge fakeroot is now a build-time dependency
# (def-file --fakeroot prebakes). The old conda squashfuse hack is gone.
#
# Usage:
#   bash setup_hopper_deps.sh              # install + local preflight
#   bash setup_hopper_deps.sh --net        # also probe network egress (from a COMPUTE node)
#   bash setup_hopper_deps.sh --check-only # no installs, preflight only
#
# Everything is idempotent; rerun freely.

set -uo pipefail

# --- knobs (match run_terminalbench_harbor.sh / prebake_harbor_sifs.sh) -------
SCRATCH_DIR="${SCRATCH_DIR:-/scratch/czhai}"
REPO_DIR="${REPO_DIR:-/scratch/czhai/Agent-Bench}"
APPTAINER_PREFIX="${APPTAINER_PREFIX:-/scratch/czhai/apptainer}" # move to /projects when relocated
CONDA_ENV="${CONDA_ENV:-bench}"
PYTHON_VERSION="${PYTHON_VERSION:-3.12}"
HARBOR_MIN_VERSION="${HARBOR_MIN_VERSION:-0.16.1}"

APPTAINER_CACHEDIR="${APPTAINER_CACHEDIR:-$SCRATCH_DIR/.apptainer_cache}"
APPTAINER_TMPDIR="${APPTAINER_TMPDIR:-$SCRATCH_DIR/tmp}"
SIF_CACHE_DIR="${SIF_CACHE_DIR:-$SCRATCH_DIR/.harbor_sif_cache}"
JOBS_DIR="${JOBS_DIR:-$REPO_DIR/data/harbor_jobs}"
MIN_SCRATCH_FREE_GB="${MIN_SCRATCH_FREE_GB:-100}"

CHECK_ONLY=0
DO_NET=0
for arg in "$@"; do
  case "$arg" in
    --check-only) CHECK_ONLY=1 ;;
    --net) DO_NET=1 ;;
    *)
      echo "unknown arg: $arg (expected --check-only and/or --net)"
      exit 1
      ;;
  esac
done

PASS=0
FAIL=0
WARN=0
ok() {
  echo "  [ OK ] $*"
  PASS=$((PASS + 1))
}
bad() {
  echo "  [FAIL] $*"
  FAIL=$((FAIL + 1))
}
warn() {
  echo "  [WARN] $*"
  WARN=$((WARN + 1))
}

echo "== Hopper Harbor/terminal-bench dependency setup v2 ($(hostname)) =="

# ==============================================================================
echo
echo "-- 1. Self-installed apptainer (replaces the 1.4.1 module)"
export PATH="$APPTAINER_PREFIX/bin:$PATH"
if command -v apptainer >/dev/null 2>&1 && [ "$(command -v apptainer)" = "$APPTAINER_PREFIX/bin/apptainer" ]; then
  aver="$(apptainer --version | awk '{print $3}')"
  printf '%s\n1.5.0\n' "$aver" | sort -V -C && bad "apptainer $aver < 1.5" || ok "apptainer $aver at $APPTAINER_PREFIX"
  # bundled FUSE tools are the whole point of the self-install
  tooldir="$APPTAINER_PREFIX/x86_64/libexec/apptainer/bin"
  missing=""
  for t in squashfuse_ll fuse2fs fuse-overlayfs; do
    [ -x "$tooldir/$t" ] || missing="$missing $t"
  done
  [ -z "$missing" ] && ok "bundled FUSE tools present (direct SIF mount + overlays)" ||
    bad "missing bundled tools:$missing (reinstall: install-unprivileged.sh $APPTAINER_PREFIX)"
  # site bind paths (/groups) break builds; env vars are cleared by the
  # prebake script, but flag stale conf entries here
  grep -Eq '^\s*bind path\s*=\s*/groups' "$APPTAINER_PREFIX"/x86_64/etc/apptainer/apptainer.conf 2>/dev/null &&
    warn "apptainer.conf still binds /groups -- comment it out or builds will FATAL" ||
    ok "no /groups bind in self-install apptainer.conf"
  case "$APPTAINER_PREFIX" in
    /scratch/*) warn "apptainer lives on /scratch (purge-eligible) -- relocate to /projects/kzhou6/czhai" ;;
    *) ok "apptainer prefix outside /scratch" ;;
  esac
else
  bad "self-installed apptainer not found at $APPTAINER_PREFIX -- install with:
       curl -s https://raw.githubusercontent.com/apptainer/apptainer/main/tools/install-unprivileged.sh \\
         | bash -s -- $APPTAINER_PREFIX"
fi

# ==============================================================================
echo
echo "-- 2. Lmod modules (git only now; apptainer module retired)"
set +u
[ -f /etc/profile.d/lmod.sh ] && source /etc/profile.d/lmod.sh
[ -n "${MODULESHOME:-}" ] && [ -f "$MODULESHOME/init/bash" ] && source "$MODULESHOME/init/bash"
if command -v module >/dev/null 2>&1; then
  module load hosts/hopper gnu10/10.3.0-ya git/2.39.1-vd 2>/dev/null && ok "module git/2.39.1-vd" ||
    warn "git module load failed (fine off-cluster; check Lmod 'Inactive Modules' on Hopper)"
else
  warn "no Lmod on this host (skipping module loads)"
fi
set -u

# ==============================================================================
echo
echo "-- 3. Conda env '$CONDA_ENV': python>=$PYTHON_VERSION, harbor>=$HARBOR_MIN_VERSION, fakeroot"
if ! command -v conda >/dev/null 2>&1; then
  bad "conda not on PATH -- install miniforge first (to scratch/projects, not home)"
else
  source "$(conda info --base)/etc/profile.d/conda.sh"
  if ! conda env list | awk '{print $1}' | grep -qx "$CONDA_ENV"; then
    if [ "$CHECK_ONLY" -eq 1 ]; then
      bad "conda env '$CONDA_ENV' missing (rerun without --check-only to create)"
    else
      conda create -y -n "$CONDA_ENV" "python=$PYTHON_VERSION" >/dev/null &&
        ok "created env $CONDA_ENV" || bad "conda create failed"
    fi
  fi
  if conda activate "$CONDA_ENV" 2>/dev/null; then
    python -c 'import sys; sys.exit(0 if sys.version_info >= (3,12) else 1)' &&
      ok "python $(python -V | awk '{print $2}') (>= 3.12)" ||
      bad "python < 3.12 -- harbor won't install"
    if [ "$CHECK_ONLY" -eq 0 ]; then
      pip install -q --upgrade "harbor>=$HARBOR_MIN_VERSION" &&
        ok "pip install harbor" || bad "pip install harbor failed (egress?)"
      command -v fakeroot >/dev/null 2>&1 ||
        conda install -y -c conda-forge fakeroot >/dev/null 2>&1
    fi
    command -v harbor >/dev/null 2>&1 && ok "harbor on PATH ($(harbor --version 2>/dev/null || echo '?'))" ||
      bad "harbor not on PATH"
    # fakeroot: required by prebake def-file builds (--fakeroot fallback chain)
    command -v fakeroot >/dev/null 2>&1 && ok "fakeroot on PATH (prebake builds)" ||
      bad "fakeroot missing: conda install -c conda-forge fakeroot"
    # REMINDER: harbor patches live outside pip -- rerun after upgrades
    warn "if harbor was upgraded just now, rerun patch_harbor_hopper.sh"
  else
    bad "could not activate conda env '$CONDA_ENV'"
  fi
fi

# ==============================================================================
echo
echo "-- 4. Scratch cache/dir layout"
for d in "$APPTAINER_CACHEDIR" "$APPTAINER_TMPDIR" "$SIF_CACHE_DIR" "$JOBS_DIR" "$REPO_DIR/logs"; do
  if [ "$CHECK_ONLY" -eq 1 ]; then
    [ -d "$d" ] && ok "$d" || warn "$d missing"
  else
    mkdir -p "$d" && ok "$d" || bad "cannot create $d"
  fi
done
free_gb="$(df -BG --output=avail "$SCRATCH_DIR" 2>/dev/null | tail -1 | tr -dc '0-9')"
if [ -n "$free_gb" ]; then
  [ "$free_gb" -ge "$MIN_SCRATCH_FREE_GB" ] &&
    ok "scratch free: ${free_gb}G (>= ${MIN_SCRATCH_FREE_GB}G)" ||
    warn "scratch free: ${free_gb}G < ${MIN_SCRATCH_FREE_GB}G (full tb2 sweep wants 50-150+)"
fi

# ==============================================================================
echo
echo "-- 5. Host preflight"
if command -v git >/dev/null 2>&1; then
  gitver="$(git --version | awk '{print $3}')"
  printf '%s\n2.19.0\n' "$gitver" | sort -V -C && bad "git $gitver < 2.19 (no partial clone)" ||
    ok "git $gitver"
else
  bad "git not on PATH (module chain broken?)"
fi
ns_max="$(cat /proc/sys/user/max_user_namespaces 2>/dev/null || echo 0)"
[ "${ns_max:-0}" -gt 0 ] && ok "unprivileged user namespaces enabled (max=$ns_max)" ||
  bad "user namespaces disabled on $(hostname) -- check on a COMPUTE node"
# functional check beats configuration checks: mount any cached SIF
first_sif="$(ls "$SIF_CACHE_DIR"/*.sif 2>/dev/null | head -1)"
if [ -n "$first_sif" ] && command -v apptainer >/dev/null 2>&1; then
  apptainer exec --no-mount bind-paths --containall "$first_sif" true >/dev/null 2>&1 &&
    ok "direct SIF mount works ($(basename "$first_sif"))" ||
    bad "SIF mount failed -- FUSE tools or namespace problem"
fi

# ==============================================================================
echo
echo "-- 6. Credentials (export before sbatch; consumed via host env, never argv)"
[ -n "${OPENAI_API_KEY:-}" ] && ok "OPENAI_API_KEY set" || warn "OPENAI_API_KEY not set (codex/openhands-sdk)"
[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && ok "CLAUDE_CODE_OAUTH_TOKEN set" ||
  warn "CLAUDE_CODE_OAUTH_TOKEN not set (claude-code; 'claude setup-token')"
[ -n "${ANTHROPIC_API_KEY:-}" ] && warn "ANTHROPIC_API_KEY set -- harmless (run script forces OAuth)" || true

# ==============================================================================
if [ "$DO_NET" -eq 1 ]; then
  echo
  echo "-- 7. Egress probes (run from an salloc'd COMPUTE node)"
  probe() { # <label> <url>
    local code
    code="$(curl -s -o /dev/null --connect-timeout 8 --max-time 15 -w '%{http_code}' "$2" 2>/dev/null)"
    if [ -n "$code" ] && [ "$code" != "000" ]; then ok "$1 ($2 -> $code)"; else bad "$1 ($2 unreachable)"; fi
  }
  echo "  [harbor host process]"
  probe "dataset registry" "https://raw.githubusercontent.com/laude-institute/harbor/main/registry.json"
  probe "task repo (github)" "https://github.com/laude-institute/terminal-bench-2"
  probe "pypi index" "https://pypi.org/simple/harbor/"
  probe "pypi files" "https://files.pythonhosted.org"
  echo "  [image pulls + prebake builds]"
  probe "docker hub registry" "https://registry-1.docker.io/v2/"
  probe "docker hub CDN" "https://production.cloudflare.docker.com"
  probe "ubuntu archive" "https://archive.ubuntu.com/ubuntu/"
  probe "ubuntu security" "https://security.ubuntu.com/ubuntu/"
  probe "debian mirror" "https://deb.debian.org"
  echo "  [agent installs + runtime APIs]"
  probe "npm registry (codex)" "https://registry.npmjs.org/@openai/codex"
  probe "claude-code bootstrap" "https://downloads.claude.ai/claude-code-releases/bootstrap.sh"
  probe "OpenAI API" "https://api.openai.com/v1/models"
  probe "Anthropic API" "https://api.anthropic.com/v1/messages"
fi

# ==============================================================================
echo
echo "== summary: $PASS ok, $WARN warn, $FAIL fail =="
if [ "$FAIL" -gt 0 ]; then
  echo "Fix FAILs before submitting. WARNs are context-dependent."
  exit 1
fi
echo "Ready. Smoke test:"
echo "  cd $REPO_DIR && N_TASKS=1 sbatch run_terminalbench_harbor.sh"
exit 0
