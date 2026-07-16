#!/bin/bash
# Grade already-generated Agent-Bench HotpotQA predictions on Hopper.
#
# Grading is OFFLINE (official EM/F1 script vs the gold file for the mode) --
# no API key, no internet needed on the compute node.
#
# HOTPOT_MODE picks which run to grade (default fullwiki, matching the
# runner's default): it selects the gold file AND the prediction/metrics
# filenames the runner wrote. HOTPOT_MODE=distractor grades the old
# unsuffixed hotpot_predictions.json against the distractor gold file.
#
# USAGE (submit from the repo root):
#     cd /projects/kzhou6/czhai/Agent-Bench   # your repo root
#     mkdir -p logs
#     sbatch slurm/grade_hotpot.sh
#     # cap hotpot cases scored (optional 3rd arg to the eval script):
#     HOTPOT_LIMIT=100 sbatch slurm/grade_hotpot.sh
#     # skip if graded output already exists:
#     RESUME=1 sbatch slurm/grade_hotpot.sh
#     # grade a different output family dir under data/:
#     FAM=codexlow sbatch slurm/grade_hotpot.sh
#     # grade a distractor-mode run:
#     HOTPOT_MODE=distractor sbatch slurm/grade_hotpot.sh
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
REPO_DIR="${REPO_DIR:-/projects/kzhou6/czhai/Agent-Bench}"
CONDA_ROOT="${CONDA_ROOT:-/projects/kzhou6/czhai/miniconda3}"
CONDA_ENV="${CONDA_ENV:-$CONDA_ROOT/envs/bench}"
RESUME="${RESUME:-0}" # 1 = skip if metrics file exists

DATA_DIR="${DATA_DIR:-$REPO_DIR/data/$FAM}"
EVAL_DIR="${EVAL_DIR:-$REPO_DIR/eval}"

# Mode-aware defaults. The runner writes fullwiki output with a _fullwiki
# suffix (distractor stays unsuffixed, matching pre-existing data/ files).
HOTPOT_MODE="${HOTPOT_MODE:-fullwiki}"
if [ "$HOTPOT_MODE" = "fullwiki" ]; then
  HOTPOT_GOLD="${HOTPOT_GOLD:-$REPO_DIR/datasets/hotpot_dev_fullwiki_v1.json}"
  HOTPOT_PRED="${HOTPOT_PRED:-$DATA_DIR/hotpot_fullwiki_predictions.json}"
  HOTPOT_METRICS="${HOTPOT_METRICS:-$DATA_DIR/hotpot_fullwiki_metrics.txt}"
else
  HOTPOT_GOLD="${HOTPOT_GOLD:-$REPO_DIR/datasets/hotpot_dev_distractor_v1.json}"
  HOTPOT_PRED="${HOTPOT_PRED:-$DATA_DIR/hotpot_predictions.json}"
  HOTPOT_METRICS="${HOTPOT_METRICS:-$DATA_DIR/hotpot_metrics.txt}"
fi
HOTPOT_LIMIT="${HOTPOT_LIMIT:-}" # optional 3rd arg; empty = score all
# ----------------------------------------------------------------------------

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
