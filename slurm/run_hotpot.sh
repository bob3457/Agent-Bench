#!/bin/bash
# Run ONLY the HotpotQA generation harness with the Codex agent on Hopper.
#
# DEFAULT MODE IS FULLWIKI: no context is given; the agent searches Wikipedia
# itself, so the default AGENT is an open-book row (codexlow-search). Pass
# HOTPOT_MODE=distractor (with a closed-book AGENT) for the old inline-context
# setting.
#
# USAGE:
#     cd /projects/kzhou6/czhai/Agent-Bench && mkdir -p logs   # your repo root
#     export OPENAI_API_KEY=sk-...
#     sbatch slurm/run_hotpot.sh                    # fullwiki, codexlow-search
#     # smoke test:            HOTPOT_LIMIT=5 sbatch slurm/run_hotpot.sh
#     # resume after timeout:  RESUME=1 sbatch slurm/run_hotpot.sh
#     # closed-book distractor setting:
#     HOTPOT_MODE=distractor AGENT=codex sbatch slurm/run_hotpot.sh
#
#SBATCH --job-name=agentbench-hotpot
#SBATCH --output=logs/agentbench-hotpot-%j.out
#SBATCH --error=logs/agentbench-hotpot-%j.err
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --time=01:00:00
#SBATCH --export=ALL
# ADAPT: set these to your Hopper allocation.
#SBATCH --partition=normal
##SBATCH --account=your_account

set -euo pipefail

# --- knobs -------------------------------------------------------------------
# Default agent matches the default (fullwiki) mode: open-book with web search.
# For HOTPOT_MODE=distractor, pass a closed-book row, e.g. AGENT=codex.
AGENT="${AGENT:-codexlow-search}"
REPO_DIR="${REPO_DIR:-/projects/kzhou6/czhai/Agent-Bench}"
CONDA_ROOT="${CONDA_ROOT:-/projects/kzhou6/czhai/miniconda3}"
CONDA_ENV="${CONDA_ENV:-$CONDA_ROOT/envs/bench}"
RESUME="${RESUME:-0}"
# Accept both spellings (README documents HOTPOT_N; the invocation below
# consumes $HOTPOT_LIMIT, which was previously never set -- unbound under set -u).
HOTPOT_LIMIT="${HOTPOT_LIMIT:-${HOTPOT_N:-50}}"
HARNESS_DIR="${HARNESS_DIR:-$REPO_DIR/harness}"
# fullwiki (default): no context given; agent searches Wikipedia itself.
# Requires an open-book agent row (codex*-search / claude-search) and the
# fullwiki dev file:
#   wget -P datasets/ http://curtis.ml.cmu.edu/datasets/hotpot/hotpot_dev_fullwiki_v1.json
# (fetch on a LOGIN node -- compute-node egress is throttled; ditto the agent's
# live web searches, so consider higher --timeout for fullwiki runs).
# distractor: answer from the 10 provided paragraphs, closed-book agent.
HOTPOT_MODE="${HOTPOT_MODE:-fullwiki}"
# ADAPT: dataset ships at the repo root in this repo.
if [ "$HOTPOT_MODE" = "fullwiki" ]; then
  HOTPOT_INPUT="${HOTPOT_INPUT:-$REPO_DIR/datasets/hotpot_dev_fullwiki_v1.json}"
else
  HOTPOT_INPUT="${HOTPOT_INPUT:-$REPO_DIR/datasets/hotpot_dev_distractor_v1.json}"
fi
# ------------------------------------------------------------------------------

: "${OPENAI_API_KEY:?OPENAI_API_KEY not set -- run: export OPENAI_API_KEY=... before sbatch}"

cd "$REPO_DIR"
mkdir -p "$REPO_DIR/logs"

# ADAPT: git comes from a module; Lmod init isn't nounset-clean.
set +u
[ -f /etc/profile.d/lmod.sh ] && source /etc/profile.d/lmod.sh
[ -n "${MODULESHOME:-}" ] && [ -f "$MODULESHOME/init/bash" ] && source "$MODULESHOME/init/bash"
module load git/2.27.1 || echo "WARNING: 'module load git/2.27.1' failed"
set -u
[ -n "${GIT_BINDIR:-}" ] && export PATH="$GIT_BINDIR:$PATH"

# conda activation LAST -- module loads prepend to PATH and would shadow the
# env's python if activation ran first. NEVER `conda info --base` in batch
# shells: it resolves via whatever conda is on PATH (a coin flip with
# multiple installs, or nothing at all in a clean batch env).
source "$CONDA_ROOT/etc/profile.d/conda.sh"
conda activate "$CONDA_ENV"
# Reactivating an already-active env (e.g. submitted from a `(bench)` shell
# with --export=ALL) is a PATH no-op -- force the env bin dir to the front.
export PATH="$CONDA_PREFIX/bin:$PATH"
python -c "import sys; assert sys.version_info >= (3, 12), sys.version" || {
  echo "FATAL: wrong python: $(command -v python || echo none)"
  exit 1
}

command -v codex >/dev/null 2>&1 || {
  echo "ERROR: codex not on PATH"
  exit 1
}
command -v git >/dev/null 2>&1 || {
  echo "ERROR: git not on PATH"
  exit 1
}

RESUME_ARG=""
[ "$RESUME" = "1" ] && RESUME_ARG="--resume"

echo "host=$(hostname) job=${SLURM_JOB_ID:-local} agent=$AGENT env=$CONDA_ENV"
echo "codex: $(command -v codex)"
echo "hotpot_limit=$HOTPOT_LIMIT mode=$HOTPOT_MODE resume=$RESUME"

echo
echo "========== STAGE: hotpotqa =========="
rc=0
if [ -f "$HOTPOT_INPUT" ]; then
  python "$HARNESS_DIR/run_hotpot_agent.py" --agent "$AGENT" --mode "$HOTPOT_MODE" \
    --input "$HOTPOT_INPUT" --limit "$HOTPOT_LIMIT" $RESUME_ARG || rc=$?
  if [ "$rc" -eq 0 ]; then echo "[hotpotqa] OK"; else echo "[hotpotqa] FAILED (rc=$rc)"; fi
else
  echo "[hotpotqa] SKIP -- input not found: $HOTPOT_INPUT (set HOTPOT_INPUT=...)"
  rc=1
fi

echo "predictions under data/${AGENT%%-*}/"
exit "$rc"
