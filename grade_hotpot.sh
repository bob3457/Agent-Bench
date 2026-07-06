#!/bin/bash
# Grade already-generated Agent-Bench HotpotQA predictions on Hopper.
#
# Grading is OFFLINE (official EM/F1 script vs the gold distractor file) --
# no API key, no internet needed on the compute node.
#
# USAGE (submit from ~/Agent-Bench):
#     cd ~/Agent-Bench
#     mkdir -p logs
#     sbatch grade_hotpot.sh
#     # cap hotpot cases scored (optional 3rd arg to the eval script):
#     HOTPOT_LIMIT=100 sbatch grade_hotpotqa.sh
#     # skip if graded output already exists:
#     RESUME=1 sbatch grade_hotpotqa.sh
#     # grade a different output family dir under data/:
#     FAM=codexlow sbatch grade_hotpotqa.sh
#
#SBATCH --job-name=hotpot-grade
#SBATCH --output=logs/hotpot-grade-%j.out
#SBATCH --error=logs/hotpot-grade-%j.err
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=8G
#SBATCH --time=00:15:00        # offline EM/F1 takes seconds
#SBATCH --export=ALL
# ADAPT: SBATCH lines are parsed by SLURM, not the shell -- no $VAR expansion here.
#SBATCH --partition=normal
##SBATCH --account=your_account

set -euo pipefail

# --- knobs (env-overridable at submit time) ---------------------------------
FAM="${FAM:-codexlow}" # output family dir under data/
REPO_DIR="${REPO_DIR:-/scratch/czhai/Agent-Bench}"
CONDA_ENV="${CONDA_ENV:-bench}"
RESUME="${RESUME:-0}" # 1 = skip if metrics file exists

DATA_DIR="${DATA_DIR:-$REPO_DIR/data/$FAM}"
EVAL_DIR="${EVAL_DIR:-$REPO_DIR/eval}"

HOTPOT_GOLD="${HOTPOT_GOLD:-$REPO_DIR/hotpot_dev_distractor_v1.json}"
HOTPOT_PRED="${HOTPOT_PRED:-$DATA_DIR/hotpot_predictions.json}"
HOTPOT_METRICS="${HOTPOT_METRICS:-$DATA_DIR/hotpot_metrics.txt}"
HOTPOT_LIMIT="${HOTPOT_LIMIT:-}" # optional 3rd arg; empty = score all
# ----------------------------------------------------------------------------

# conda activation inside a non-interactive shell
source "$(conda info --base)/etc/profile.d/conda.sh"
conda activate "$CONDA_ENV"

cd "$REPO_DIR"
mkdir -p "$DATA_DIR" logs

echo "host=$(hostname) job=${SLURM_JOB_ID:-local} fam=$FAM env=$CONDA_ENV resume=$RESUME"

# --- preflight ---------------------------------------------------------------
if [ "$RESUME" = "1" ] && [ -s "$HOTPOT_METRICS" ]; then
  echo "[hotpot] SKIP -- metrics exist: $HOTPOT_METRICS"
  exit 0
fi
if [ ! -f "$HOTPOT_PRED" ]; then
  echo "[hotpot] FAILED -- predictions not found: $HOTPOT_PRED" >&2
  exit 1
fi
if [ ! -f "$HOTPOT_GOLD" ]; then
  echo "[hotpot] FAILED -- gold not found: $HOTPOT_GOLD" >&2
  exit 1
fi

# --- grade -------------------------------------------------------------------
# hotpot_evaluate_v1.py prints the metrics dict to stdout; tee it to disk.
# Third positional arg (case cap) is optional -- only pass when set.
echo
echo "========== STAGE: hotpot =========="
args=("$HOTPOT_PRED" "$HOTPOT_GOLD")
[ -n "$HOTPOT_LIMIT" ] && args+=("$HOTPOT_LIMIT")
echo "+ python $EVAL_DIR/hotpot_evaluate_v1.py ${args[*]}"

rc=0
python "$EVAL_DIR/hotpot_evaluate_v1.py" "${args[@]}" | tee "$HOTPOT_METRICS" || rc=$?

echo
echo "========== SUMMARY =========="
if [ "$rc" -eq 0 ]; then
  echo "  hotpot=0 (OK)"
else
  echo "  hotpot=$rc (FAILED)"
fi
echo "hotpot metrics -> $HOTPOT_METRICS"
exit "$rc"
