#!/usr/bin/env bash
# fix_webarena_env.sh - one-shot repair for the current situation:
#   * webarena-verified was accidentally pip-installed into conda BASE
#   * a clone of the repo already exists somewhere
#   * we want a proper named env `webarena` with everything installed there
#
# Run this once on Hopper from the webarena-verified-hopper directory:
#   ./fix_webarena_env.sh
#   ./fix_webarena_env.sh /path/to/your/clone     # if auto-detect misses it
#
# It will:
#   1. Uninstall webarena-verified from base (deps are left; see note at end)
#   2. Find your existing clone (or clone fresh to scratch if none found)
#   3. Create the named env `webarena` (python 3.12) in your home miniconda
#   4. pip install -e "<clone>[examples]" INTO that env, caches on scratch
#   5. Install the Playwright chromium browser to scratch
#   6. Rewrite $WA_BASE/activate_wa.sh to activate `webarena`
#   7. Verify: CLI resolves inside the env, and base no longer imports it

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=wa_common.sh
source "$SCRIPT_DIR/wa_common.sh"

WA_ENV_NAME="${WA_ENV_NAME:-webarena}"
WA_PY_VERSION="${WA_PY_VERSION:-3.12}"
CLONE_ARG="${1:-}"

export PIP_CACHE_DIR="${WA_PIP_CACHE_DIR:-$WA_SCRATCH/pip-cache}"
export PLAYWRIGHT_BROWSERS_PATH="${WA_PLAYWRIGHT_BROWSERS_PATH:-$WA_BASE/ms-playwright}"
export CONDA_PKGS_DIRS="${WA_CONDA_PKGS_DIRS:-$WA_SCRATCH/conda-pkgs}"
mkdir -p "$WA_BASE" "$WA_SCRATCH" "$PIP_CACHE_DIR" "$CONDA_PKGS_DIRS" "$PLAYWRIGHT_BROWSERS_PATH"

# --- locate conda ---------------------------------------------------------------
CONDA_ROOT=""
for c in "${WA_CONDA_ROOT:-}" "${CONDA_EXE:+$(dirname "$(dirname "$CONDA_EXE")")}" \
  "$HOME/miniconda3" "$HOME/anaconda3" \
  "/home/czhai/miniconda3" "/home/czhai/anaconda3"; do
  [ -n "$c" ] && [ -x "$c/bin/conda" ] && {
    CONDA_ROOT="$c"
    break
  }
done
[ -n "$CONDA_ROOT" ] || {
  echo "ERROR: conda not found; set WA_CONDA_ROOT=..." >&2
  exit 1
}
echo "[conda] $CONDA_ROOT"
# shellcheck disable=SC1091
source "$CONDA_ROOT/etc/profile.d/conda.sh"

# --- 1. clean base -----------------------------------------------------------------
conda activate base
if python -c "import webarena_verified" >/dev/null 2>&1; then
  echo "[base] uninstalling webarena-verified from base"
  pip uninstall -y webarena-verified
else
  echo "[base] webarena-verified not installed in base (nothing to remove)"
fi
conda deactivate

# --- 2. find the clone ----------------------------------------------------------------
find_clone() {
  local d
  for d in \
    "$CLONE_ARG" \
    "${WA_SRC_DIR:-}" \
    "$WA_BASE/src/webarena-verified" \
    "$SCRIPT_DIR/../webarena-verified" \
    "/scratch/${USER}/webarena-verified-repo" \
    "/scratch/${USER}/webarena-verified/src/webarena-verified" \
    "$HOME/webarena-verified"; do
    [ -n "$d" ] && [ -f "$d/pyproject.toml" ] && [ -d "$d/src/webarena_verified" ] &&
      {
        readlink -f "$d"
        return 0
      }
  done
  return 1
}

if SRC="$(find_clone)"; then
  echo "[src] using existing clone: $SRC"
else
  SRC="$WA_BASE/src/webarena-verified"
  echo "[src] no clone found; cloning fresh -> $SRC"
  mkdir -p "$(dirname "$SRC")"
  git clone https://github.com/ServiceNow/webarena-verified.git "$SRC"
fi

# --- 3. create the named env --------------------------------------------------------------
if conda env list | awk '{print $1}' | grep -qx "$WA_ENV_NAME"; then
  echo "[conda] env '$WA_ENV_NAME' already exists"
else
  echo "[conda] creating env '$WA_ENV_NAME' (python=$WA_PY_VERSION)"
  conda create -y -n "$WA_ENV_NAME" "python=$WA_PY_VERSION" pip
fi
conda activate "$WA_ENV_NAME"
echo "[conda] active: ${CONDA_PREFIX:?}"
python -V

# --- 4. install into the env ------------------------------------------------------------------
echo "[pip] installing webarena-verified (editable) into '$WA_ENV_NAME'"
pip install -e "${SRC}[examples]"

# --- 5. playwright browser (non-fatal) ----------------------------------------------------------
python -m playwright install chromium ||
  echo "[playwright] browser install failed (non-fatal for hosting/eval)" >&2

# --- 6. activation helper --------------------------------------------------------------------------
ACT="$WA_BASE/activate_wa.sh"
cat >"$ACT" <<EOF
# source this to work with webarena-verified on Hopper
source "$CONDA_ROOT/etc/profile.d/conda.sh"
conda activate "$WA_ENV_NAME"
export PIP_CACHE_DIR="$PIP_CACHE_DIR"
export CONDA_PKGS_DIRS="$CONDA_PKGS_DIRS"
export PLAYWRIGHT_BROWSERS_PATH="$PLAYWRIGHT_BROWSERS_PATH"
export WA_BASE="$WA_BASE"
export WA_ROOT="$WA_ROOT"
export WA_SCRATCH="$WA_SCRATCH"
# site URLs, once slurm/webarena_sites.sbatch is running:
[ -f "$WA_SCRATCH/urls.env" ] && source "$WA_SCRATCH/urls.env"
EOF
echo "[done] wrote $ACT"

# --- 7. verify -------------------------------------------------------------------------------------------
echo
echo "===== verification ====="
echo -n "webarena-verified in '$WA_ENV_NAME': "
command -v webarena-verified || {
  echo "MISSING"
  exit 1
}
webarena-verified --help >/dev/null && echo "CLI works: yes"
conda deactivate
conda activate base
if python -c "import webarena_verified" >/dev/null 2>&1; then
  echo "base still imports webarena_verified: YES (unexpected — check pip list in base)"
else
  echo "base still imports webarena_verified: no (clean)"
fi
conda deactivate

echo
echo "All set. Use it with:"
echo "  source $ACT"
echo
echo "Note: base still has leftover DEPENDENCIES (geopy, usaddress, thefuzz, ...)."
echo "They're harmless clutter; to purge them from base:"
echo "  conda activate base && pip uninstall -y geopy geographiclib pint \\"
echo "    price-parser pytimeparse2 unidecode url-normalize word2number \\"
echo "    usaddress us usaddress-scourgify jsonpath-ng compact-json thefuzz"
echo "Left alone on purpose: pydantic, beautifulsoup4, python-dateutil (other"
echo "tools in base may depend on them). If Agent-Bench tooling in base needed"
echo "a different pydantic than 2.12.0, restore it: pip install pydantic==<ver>"
