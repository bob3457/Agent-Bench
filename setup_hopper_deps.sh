#!/bin/bash
# setup_hopper_deps.sh -- one-shot dependency install + preflight for running
# run_terminalbench_harbor.sh on Hopper (rootless SLURM, no Docker, no root).
#
# What it does:
#   1. Loads the required Lmod modules in the ORDER that keeps git alive
#   2. Creates/updates the conda env with Python >= 3.12 and pip-installs harbor
#   3. Creates all scratch cache dirs (apptainer cache/tmp, persistent SIF cache)
#   4. Preflight: binaries, versions, rootless userns, disk headroom
#   5. Optional --net: probes every egress endpoint the pipeline needs
#      (run this part from an salloc'd COMPUTE node -- login-node egress lies)
#
# Usage:
#   bash setup_hopper_deps.sh              # install + local preflight
#   bash setup_hopper_deps.sh --net        # also probe network egress
#   bash setup_hopper_deps.sh --check-only # no installs, preflight only
#
# Everything is idempotent; rerun freely.

set -uo pipefail

# --- knobs (match run_terminalbench_harbor.sh) ---------------------------------
SCRATCH_DIR="${SCRATCH_DIR:-/scratch/czhai}"
REPO_DIR="${REPO_DIR:-/scratch/czhai/Agent-Bench}"
CONDA_ENV="${CONDA_ENV:-bench}"
PYTHON_VERSION="${PYTHON_VERSION:-3.12}"     # harbor requires >= 3.12
HARBOR_MIN_VERSION="${HARBOR_MIN_VERSION:-0.16.1}"

APPTAINER_CACHEDIR="${APPTAINER_CACHEDIR:-$SCRATCH_DIR/.apptainer_cache}"
APPTAINER_TMPDIR="${APPTAINER_TMPDIR:-$SCRATCH_DIR/tmp}"
SIF_CACHE_DIR="${SIF_CACHE_DIR:-$SCRATCH_DIR/.harbor_sif_cache}"
JOBS_DIR="${JOBS_DIR:-$REPO_DIR/data/harbor_jobs}"
MIN_SCRATCH_FREE_GB="${MIN_SCRATCH_FREE_GB:-100}"   # full tb2 sweep wants 50-150+

CHECK_ONLY=0; DO_NET=0
for arg in "$@"; do
    case "$arg" in
        --check-only) CHECK_ONLY=1 ;;
        --net)        DO_NET=1 ;;
        *) echo "unknown arg: $arg (expected --check-only and/or --net)"; exit 1 ;;
    esac
done

PASS=0; FAIL=0; WARN=0
ok()   { echo "  [ OK ] $*"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }
warn() { echo "  [WARN] $*"; WARN=$((WARN+1)); }

echo "== Hopper Harbor/terminal-bench dependency setup ($(hostname)) =="

# ================================================================================
echo
echo "-- 1. Lmod modules (order matters: hosts/hopper ONCE, apptainer first, git LAST)"
set +u
[ -f /etc/profile.d/lmod.sh ] && source /etc/profile.d/lmod.sh
[ -n "${MODULESHOME:-}" ] && [ -f "$MODULESHOME/init/bash" ] && source "$MODULESHOME/init/bash"
if command -v module >/dev/null 2>&1; then
    module load hosts/hopper apptainer/1.4.1 2>/dev/null && ok "module apptainer/1.4.1" \
        || warn "apptainer module load failed (fine off-cluster; fatal on Hopper)"
    # gnu10 chain LAST -- a later hosts/hopper reload flips gnu10->gnu9 and
    # silently inactivates git/2.39.1-vd.
    module load gnu10/10.3.0-ya git/2.39.1-vd 2>/dev/null && ok "module git/2.39.1-vd (gnu10 chain)" \
        || warn "git module load failed (fine off-cluster; check Lmod 'Inactive Modules' on Hopper)"
else
    warn "no Lmod on this host (skipping module loads)"
fi
set -u
[ -n "${GIT_BINDIR:-}" ]       && export PATH="$GIT_BINDIR:$PATH"
[ -n "${APPTAINER_BINDIR:-}" ] && export PATH="$APPTAINER_BINDIR:$PATH"

# ================================================================================
echo
echo "-- 2. Conda env '$CONDA_ENV' with Python >= $PYTHON_VERSION + harbor >= $HARBOR_MIN_VERSION"
if ! command -v conda >/dev/null 2>&1; then
    bad "conda not on PATH -- install miniforge/miniconda first:
       curl -fsSLo Miniforge3.sh https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh
       bash Miniforge3.sh -b -p \$SCRATCH_DIR/miniforge3   # scratch, not home (quota)"
else
    source "$(conda info --base)/etc/profile.d/conda.sh"
    if ! conda env list | awk '{print $1}' | grep -qx "$CONDA_ENV"; then
        if [ "$CHECK_ONLY" -eq 1 ]; then
            bad "conda env '$CONDA_ENV' missing (rerun without --check-only to create)"
        else
            echo "  creating conda env '$CONDA_ENV' (python=$PYTHON_VERSION)..."
            conda create -y -n "$CONDA_ENV" "python=$PYTHON_VERSION" >/dev/null \
                && ok "created env $CONDA_ENV" || bad "conda create failed"
        fi
    fi
    if conda activate "$CONDA_ENV" 2>/dev/null; then
        pyver="$(python -c 'import sys; print(".".join(map(str, sys.version_info[:3])))')"
        python -c 'import sys; sys.exit(0 if sys.version_info >= (3,12) else 1)' \
            && ok "python $pyver (>= 3.12, harbor requires-python)" \
            || bad "python $pyver < 3.12 -- harbor won't install; recreate env with python=3.12"
        if [ "$CHECK_ONLY" -eq 0 ]; then
            echo "  pip installing harbor>=$HARBOR_MIN_VERSION (pure-python wheels)..."
            pip install -q --upgrade "harbor>=$HARBOR_MIN_VERSION" \
                && ok "pip install harbor" || bad "pip install harbor failed (egress to pypi.org?)"
        fi
        if command -v harbor >/dev/null 2>&1; then
            hv="$(harbor --version 2>/dev/null || echo '?')"
            ok "harbor on PATH (version $hv)"
            python - "$hv" "$HARBOR_MIN_VERSION" <<'PYEOF' && ok "harbor version >= $HARBOR_MIN_VERSION" || warn "harbor $hv < $HARBOR_MIN_VERSION -- upgrade recommended"
import sys
from packaging.version import Version
try:
    sys.exit(0 if Version(sys.argv[1]) >= Version(sys.argv[2]) else 1)
except Exception:
    sys.exit(1)
PYEOF
        else
            bad "harbor not on PATH after install"
        fi
    else
        bad "could not activate conda env '$CONDA_ENV'"
    fi
fi

# ================================================================================
echo
echo "-- 3. Scratch cache/dir layout"
for d in "$APPTAINER_CACHEDIR" "$APPTAINER_TMPDIR" "$SIF_CACHE_DIR" "$JOBS_DIR" "$REPO_DIR/logs"; do
    if [ "$CHECK_ONLY" -eq 1 ]; then
        [ -d "$d" ] && ok "$d" || warn "$d missing"
    else
        mkdir -p "$d" && ok "$d" || bad "cannot create $d"
    fi
done
free_gb="$(df -BG --output=avail "$SCRATCH_DIR" 2>/dev/null | tail -1 | tr -dc '0-9')"
if [ -n "$free_gb" ]; then
    if [ "$free_gb" -ge "$MIN_SCRATCH_FREE_GB" ]; then
        ok "scratch free space: ${free_gb}G (>= ${MIN_SCRATCH_FREE_GB}G; every tb2 task has its own SIF)"
    else
        warn "scratch free space: ${free_gb}G < ${MIN_SCRATCH_FREE_GB}G -- full tb2 sweep needs 50-150+ GB of SIFs"
    fi
fi

# ================================================================================
echo
echo "-- 4. Host preflight (binaries, rootless userns)"
if command -v git >/dev/null 2>&1; then
    gitver="$(git --version | awk '{print $3}')"
    # --filter=blob:none needs git >= 2.19
    printf '%s\n2.19.0\n' "$gitver" | sort -V -C && bad "git $gitver < 2.19 (no partial clone)" \
        || ok "git $gitver (partial clone OK)"
else
    bad "git not on PATH (module chain broken? see Lmod Inactive Modules)"
fi
if command -v singularity >/dev/null 2>&1; then
    ok "singularity on PATH ($(singularity --version 2>/dev/null))"
    # apptainer bundles mksquashfs for docker->SIF conversion
    singularity buildcfg 2>/dev/null | grep -qi mksquashfs && ok "bundled mksquashfs configured" \
        || warn "could not confirm mksquashfs via buildcfg (pull will tell)"
else
    warn "singularity not on PATH (fatal on Hopper; fine if setting up elsewhere with ENV_TYPE=docker)"
fi
ns_max="$(cat /proc/sys/user/max_user_namespaces 2>/dev/null || echo 0)"
[ "${ns_max:-0}" -gt 0 ] && ok "unprivileged user namespaces enabled (max=$ns_max)" \
    || bad "user namespaces disabled on $(hostname) -- --fakeroot cannot work (check on a COMPUTE node)"
command -v curl >/dev/null 2>&1 && ok "curl" || warn "curl missing (needed for --net checks only)"

# ================================================================================
echo
echo "-- 5. Credentials (export before sbatch; consumed via host env, never argv)"
[ -n "${OPENAI_API_KEY:-}" ] && ok "OPENAI_API_KEY set (codex / openhands-sdk)" \
    || warn "OPENAI_API_KEY not set (required for AGENT=codex|openhands-sdk)"
[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && ok "CLAUDE_CODE_OAUTH_TOKEN set (claude-code)" \
    || warn "CLAUDE_CODE_OAUTH_TOKEN not set (required for AGENT=claude-code; get via 'claude setup-token')"
[ -n "${ANTHROPIC_API_KEY:-}" ] && warn "ANTHROPIC_API_KEY is set in this env -- harmless (run script forces OAuth), but be aware" || true

# ================================================================================
if [ "$DO_NET" -eq 1 ]; then
    echo
    echo "-- 6. Egress probes (run from an salloc'd COMPUTE node -- login egress differs)"
    probe() {  # probe <label> <url>
        local code
        code="$(curl -s -o /dev/null --connect-timeout 8 --max-time 15 -w '%{http_code}' "$2" 2>/dev/null)"
        # any HTTP response (incl. 401/403/404) proves TCP+TLS egress works
        if [ -n "$code" ] && [ "$code" != "000" ]; then ok "$1 ($2 -> $code)"; else bad "$1 ($2 unreachable)"; fi
    }
    echo "  [harbor host process]"
    probe "dataset registry"        "https://raw.githubusercontent.com/laude-institute/harbor/main/registry.json"
    probe "task repo (github)"      "https://github.com/laude-institute/terminal-bench-2"
    probe "github codeload"         "https://codeload.github.com"
    probe "pypi index"              "https://pypi.org/simple/harbor/"
    probe "pypi files"              "https://files.pythonhosted.org"
    echo "  [SIF conversion -- all tb2 images are Docker Hub alexgshaw/*]"
    probe "docker hub registry"     "https://registry-1.docker.io/v2/"
    probe "docker hub auth"         "https://auth.docker.io/token?service=registry.docker.io&scope=repository:alexgshaw/gpt2-codegolf:pull"
    probe "docker hub CDN"          "https://production.cloudflare.docker.com"
    echo "  [container bootstrap (shares host netns under apptainer)]"
    probe "debian mirror"           "https://deb.debian.org"
    probe "ubuntu archive"          "http://archive.ubuntu.com/ubuntu/"
    probe "ubuntu security"         "http://security.ubuntu.com/ubuntu/"
    probe "get-pip fallback"        "https://bootstrap.pypa.io/get-pip.py"
    echo "  [agent installs]"
    probe "nvm installer (codex)"   "https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.2/install.sh"
    probe "node dist (codex)"       "https://nodejs.org/dist/"
    probe "npm registry (codex)"    "https://registry.npmjs.org/@openai/codex"
    probe "claude-code bootstrap"   "https://downloads.claude.ai/claude-code-releases/bootstrap.sh"
    probe "uv installer (openhands)" "https://astral.sh/uv/install.sh"
    probe "github release objects"  "https://objects.githubusercontent.com"
    echo "  [agent runtime APIs -- the previously-bitten VPN egress check]"
    probe "OpenAI API"              "https://api.openai.com/v1/models"
    probe "Anthropic API"           "https://api.anthropic.com/v1/messages"
fi

# ================================================================================
echo
echo "== summary: $PASS ok, $WARN warn, $FAIL fail =="
if [ "$FAIL" -gt 0 ]; then
    echo "Fix FAILs before submitting. WARNs are context-dependent (e.g. creds for agents you aren't running)."
    exit 1
fi
echo "Ready. Smoke test:"
echo "  cd $REPO_DIR && export OPENAI_API_KEY=... && N_TASKS=1 sbatch run_terminalbench_harbor.sh"
exit 0