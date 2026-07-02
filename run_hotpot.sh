#!/bin/bash
# Run ONLY the HotpotQA generation harness with the Codex agent on Hopper.
#
# USAGE:
#     cd ~/Agent-Bench && mkdir -p logs
#     export OPENAI_API_KEY=sk-...
#     sbatch run_hotpot_codex.sh
#     # smoke test:            HOTPOT_LIMIT=5 sbatch run_hotpot_codex.sh
#     # resume after timeout:  RESUME=1 sbatch run_hotpot_codex.sh
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
AGENT="${AGENT:-codex}"
REPO_DIR="${REPO_DIR:-/scratch/czhai/Agent-Bench}"
CONDA_ENV="${CONDA_ENV:-bench}"
RESUME="${RESUME:-0}"
HOTPOT_LIMIT="${HOTPOT_LIMIT:-50}"
HARNESS_DIR="${HARNESS_DIR:-$REPO_DIR/harness}"
# ADAPT: dataset ships at the repo root in this repo.
HOTPOT_INPUT="${HOTPOT_INPUT:-$REPO_DIR/hotpot_dev_distractor_v1.json}"
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

echo "host=$(hostname) job=${SLURM_JOB_ID:-local} agent=$AGENT env=$CONDA_ENV"
echo "codex: $(command -v codex)"
echo "hotpot_limit=$HOTPOT_LIMIT resume=$RESUME"

echo
echo "========== STAGE: hotpotqa =========="
rc=0
if [ -f "$HOTPOT_INPUT" ]; then
    python "$HARNESS_DIR/run_hotpot_agent.py" --agent "$AGENT" \
        --input "$HOTPOT_INPUT" --limit "$HOTPOT_LIMIT" $RESUME_ARG || rc=$?
    if [ "$rc" -eq 0 ]; then echo "[hotpotqa] OK"; else echo "[hotpotqa] FAILED (rc=$rc)"; fi
else
    echo "[hotpotqa] SKIP -- input not found: $HOTPOT_INPUT (set HOTPOT_INPUT=...)"
    rc=1
fi

echo "predictions under data/${AGENT%%-*}/"
exit "$rc"