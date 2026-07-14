#!/usr/bin/env bash
# 00_setup_conda_env.sh - set up the Python side of webarena-verified on Hopper.
#
# The site-hosting scripts (01-04, wa_site.sh, sbatch) are pure bash+Apptainer
# and need NO Python. This env is for the webarena-verified harness:
#   * `webarena-verified` CLI (dataset export, subset export)
#   * offline evaluation (HAR trace replay -> pass/fail)
#   * config rendering (__SHOPPING__ / __SHOPPING_ADMIN__ placeholders)
#   * optionally Playwright, for a quick manual browse/auth sanity check
#
# What it does:
#   1. Finds conda: existing miniconda at /projects/kzhou6/czhai/miniconda3 if
#      present, else bootstraps a fresh Miniconda into $WA_BASE/miniconda3
#      (kept in scratch since this is a scratch-only test setup).
#   2. Creates a *prefix* env at $WA_BASE/conda-env (python 3.12) so the whole
#      test footprint stays under /scratch/czhai and is trivially deletable.
#   3. Clones webarena-verified into $WA_BASE/src and pip-installs it
#      editable, with the `examples` extra (playwright etc.) unless
#      WA_INSTALL_EXAMPLES=0.
#   4. Redirects all caches (pip, playwright browsers) to scratch — never
#      $HOME on Hopper.
#   5. Writes $WA_BASE/activate_wa.sh — source it in any shell/job to get the
#      env + paths.
#
# Usage:
#   ./00_setup_conda_env.sh
#   WA_INSTALL_EXAMPLES=0 ./00_setup_conda_env.sh   # harness only, no playwright

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=wa_common.sh
source "$SCRIPT_DIR/wa_common.sh"

WA_CONDA_ROOT="${WA_CONDA_ROOT:-}" # explicit conda install to use
WA_ENV_PREFIX="${WA_ENV_PREFIX:-$WA_BASE/conda-env}"
WA_PY_VERSION="${WA_PY_VERSION:-3.12}"
WA_SRC_DIR="${WA_SRC_DIR:-$WA_BASE/src/webarena-verified}"
WA_REPO_URL="${WA_REPO_URL:-https://github.com/ServiceNow/webarena-verified.git}"
WA_INSTALL_EXAMPLES="${WA_INSTALL_EXAMPLES:-1}"

# Caches on scratch, never $HOME
export PIP_CACHE_DIR="${PIP_CACHE_DIR:-$WA_SCRATCH/pip-cache}"
export PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-$WA_BASE/ms-playwright}"
mkdir -p "$WA_BASE" "$PIP_CACHE_DIR"

# --- 1. locate or bootstrap conda ---------------------------------------------
find_conda() {
  local c
  for c in \
    "$WA_CONDA_ROOT" \
    "/home/czhai/miniconda3" \
    "$WA_BASE/miniconda3"; do
    [ -n "$c" ] && [ -x "$c/bin/conda" ] && {
      printf '%s' "$c"
      return 0
    }
  done
  return 1
}

if ! CONDA_ROOT="$(find_conda)"; then
  CONDA_ROOT="$WA_BASE/miniconda3"
  echo "[conda] no existing conda found; bootstrapping Miniconda -> $CONDA_ROOT"
  installer="$WA_SCRATCH/Miniconda3-latest-Linux-x86_64.sh"
  mkdir -p "$WA_SCRATCH"
  if [ ! -f "$installer" ]; then
    wget -q -O "$installer" \
      "https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh"
  fi
  bash "$installer" -b -p "$CONDA_ROOT"
fi
echo "[conda] using conda at: $CONDA_ROOT"

# shellcheck disable=SC1091
source "$CONDA_ROOT/etc/profile.d/conda.sh"

# Keep conda pkgs cache off $HOME too
export CONDA_PKGS_DIRS="${CONDA_PKGS_DIRS:-$WA_SCRATCH/conda-pkgs}"
mkdir -p "$CONDA_PKGS_DIRS"

# --- 2. prefix env --------------------------------------------------------------
if [ -x "$WA_ENV_PREFIX/bin/python" ]; then
  echo "[conda] env already exists: $WA_ENV_PREFIX"
else
  echo "[conda] creating env at $WA_ENV_PREFIX (python=$WA_PY_VERSION)"
  conda create -y -p "$WA_ENV_PREFIX" "python=$WA_PY_VERSION" pip
fi
conda activate "$WA_ENV_PREFIX"
python -V

# --- 3. install webarena-verified ------------------------------------------------
if [ ! -d "$WA_SRC_DIR/.git" ]; then
  echo "[src] cloning $WA_REPO_URL -> $WA_SRC_DIR"
  mkdir -p "$(dirname "$WA_SRC_DIR")"
  git clone "$WA_REPO_URL" "$WA_SRC_DIR"
else
  echo "[src] repo already cloned: $WA_SRC_DIR (git -C ... pull to update)"
fi

echo "[pip] installing webarena-verified (editable)"
if [ "$WA_INSTALL_EXAMPLES" = "1" ]; then
  pip install -e "${WA_SRC_DIR}[examples]"
else
  pip install -e "$WA_SRC_DIR"
fi

# --- 4. optional playwright browser ----------------------------------------------
if [ "$WA_INSTALL_EXAMPLES" = "1" ]; then
  echo "[playwright] installing chromium into $PLAYWRIGHT_BROWSERS_PATH"
  mkdir -p "$PLAYWRIGHT_BROWSERS_PATH"
  # No root on Hopper so `playwright install-deps` is unavailable; plain
  # chromium usually runs on Hopper's glibc. If it complains about missing
  # system libs, run the browser inside a container instead (PoloWitty's
  # playwright-SIF pattern) or use chromium --headless=new.
  python -m playwright install chromium || {
    echo "[playwright] browser install failed (non-fatal for hosting/eval)" >&2
  }
fi

# --- 5. activation helper --------------------------------------------------------
ACT="$WA_BASE/activate_wa.sh"
cat >"$ACT" <<EOF
# source this to work with webarena-verified on Hopper
source "$CONDA_ROOT/etc/profile.d/conda.sh"
conda activate "$WA_ENV_PREFIX"
export PIP_CACHE_DIR="$PIP_CACHE_DIR"
export PLAYWRIGHT_BROWSERS_PATH="$PLAYWRIGHT_BROWSERS_PATH"
export WA_BASE="$WA_BASE"
export WA_ROOT="$WA_ROOT"
export WA_SCRATCH="$WA_SCRATCH"
# site URLs, once slurm/webarena_sites.sbatch is running:
[ -f "$WA_SCRATCH/urls.env" ] && source "$WA_SCRATCH/urls.env"
EOF
echo
echo "[done] activate with:  source $ACT"
echo "[done] sanity check:   webarena-verified --help"
