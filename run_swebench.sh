#!/bin/bash
# Run ONLY the SWE-bench_Lite generation harness with the Codex agent on Hopper.
#
# USAGE:
#     cd ~/Agent-Bench && mkdir -p logs
#     export OPENAI_API_KEY=sk-...
#     sbatch run_swebench_codex.sh
#     # smoke test:            SWE_N=3 sbatch run_swebench_codex.sh
#     # (SWE-bench resumes automatically by skipping instance_ids already predicted)
#
#SBATCH --job-name=agentbench-swe
#SBATCH --output=logs/agentbench-swe-%j.out
#SBATCH --error=logs/agentbench-swe-%j.err
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --time=01:00:00        # tune to SWE_N x per-instance time
#SBATCH --export=ALL
# ADAPT: set these to your Hopper allocation.
#SBATCH --partition=normal
##SBATCH --account=your_account

set -euo pipefail

# --- knobs -------------------------------------------------------------------
AGENT="${AGENT:-codex}"
REPO_DIR="${REPO_DIR:-/scratch/czhai/Agent-Bench}"
CONDA_ENV="${CONDA_ENV:-bench}"
SWE_N="${SWE_N:-25}"
HARNESS_DIR="${HARNESS_DIR:-$REPO_DIR/harness}"
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

# SWE-bench fetches princeton-nlp/SWE-bench_Lite (HF) and clones from github.com.
export HF_HOME="${HF_HOME:-$REPO_DIR/.hf_cache}"

# repo_cache empty-dir trap: crashed runs leave empty clone dirs that bypass
# ensure_repo's existence check. Uncomment before a retry after a crash:
# rm -rf "$REPO_DIR/data/repo_cache/"

echo "host=$(hostname) job=${SLURM_JOB_ID:-local} agent=$AGENT env=$CONDA_ENV"
echo "codex: $(command -v codex)"
echo "swe_n=$SWE_N"

echo
echo "========== STAGE: swebench =========="
rc=0
python "$HARNESS_DIR/run_swebench_agent.py" --agent "$AGENT" --n "$SWE_N" || rc=$?
if [ "$rc" -eq 0 ]; then echo "[swebench] OK"; else echo "[swebench] FAILED (rc=$rc)"; fi

fam="${AGENT%%-*}"
echo "predictions under data/$fam/"
exit "$rc"