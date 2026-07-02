#!/bin/bash
# Run ONLY the FreshQA generation harness with the Codex agent on Hopper.
#
# USAGE:
#     cd ~/Agent-Bench && mkdir -p logs
#     export OPENAI_API_KEY=sk-...
#     sbatch run_freshqa_codex.sh
#     # smoke test:            FRESHQA_LIMIT=5 sbatch run_freshqa_codex.sh
#     # open-book (web) run:   FRESHQA_AGENT=codex-search sbatch run_freshqa_codex.sh
#     # resume after timeout:  RESUME=1 sbatch run_freshqa_codex.sh
#
#SBATCH --job-name=agentbench-freshqa
#SBATCH --output=logs/agentbench-freshqa-%j.out
#SBATCH --error=logs/agentbench-freshqa-%j.err
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
AGENT="${AGENT:-codex}"
REPO_DIR="${REPO_DIR:-/scratch/czhai/Agent-Bench}"
CONDA_ENV="${CONDA_ENV:-bench}"
RESUME="${RESUME:-0}"
FRESHQA_LIMIT="${FRESHQA_LIMIT:-50}"
HARNESS_DIR="${HARNESS_DIR:-$REPO_DIR/harness}"
# ADAPT: dataset ships at the repo root in this repo.
FRESHQA_INPUT="${FRESHQA_INPUT:-$REPO_DIR/freshqa.csv}"

# FreshQA is OPEN-BOOK (needs live web). Plain `codex` is closed-book unless its
# agents.yaml row enables web search. With plain codex the harness prints a
# closed-book WARNING -- expected; codex never reports web_search_requests, so
# it is not a reliable liveness signal.
FRESHQA_AGENT="${FRESHQA_AGENT:-$AGENT}"
# ------------------------------------------------------------------------------

: "${OPENAI_API_KEY:?OPENAI_API_KEY not set -- run: export OPENAI_API_KEY=... before sbatch}"

source "$(conda info --base)/etc/profile.d/conda.sh"
conda activate "$CONDA_ENV"

cd "$REPO_DIR"
mkdir -p "$REPO_DIR/logs"

# ADAPT: git comes from a module; Lmod init isn't nounset-clean.
set +u
[ -f /etc/profile.d/lmod.sh ] && source /etc/profile.d/lmod.sh
[ -n "${MODULESHOME:-}" ] && [ -f "$MODULESHOME/init/bash" ] && source "$MODULESHOME/init/bash"
module load git/2.27.1 || echo "WARNING: 'module load git/2.27.1' failed"
set -u
[ -n "${GIT_BINDIR:-}" ] && export PATH="$GIT_BINDIR:$PATH"

command -v codex >/dev/null 2>&1 || { echo "ERROR: codex not on PATH"; exit 1; }
command -v git   >/dev/null 2>&1 || { echo "ERROR: git not on PATH";   exit 1; }

RESUME_ARG=""
[ "$RESUME" = "1" ] && RESUME_ARG="--resume"

echo "host=$(hostname) job=${SLURM_JOB_ID:-local} agent=$FRESHQA_AGENT env=$CONDA_ENV"
echo "codex: $(command -v codex)"
echo "freshqa_limit=$FRESHQA_LIMIT resume=$RESUME"

echo
echo "========== STAGE: freshqa =========="
rc=0
if [ -f "$FRESHQA_INPUT" ]; then
    python "$HARNESS_DIR/run_freshqa_agent.py" --agent "$FRESHQA_AGENT" \
        --input "$FRESHQA_INPUT" --limit "$FRESHQA_LIMIT" $RESUME_ARG || rc=$?
    if [ "$rc" -eq 0 ]; then echo "[freshqa] OK"; else echo "[freshqa] FAILED (rc=$rc)"; fi
else
    echo "[freshqa] SKIP -- input not found: $FRESHQA_INPUT (set FRESHQA_INPUT=...)"
    rc=1
fi

echo "predictions under data/${FRESHQA_AGENT%%-*}/"
exit "$rc"