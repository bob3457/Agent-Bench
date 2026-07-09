#!/bin/bash
# Grade already-generated Agent-Bench SWE-bench Lite predictions on Hopper.
#
# SWE-bench grading is LOCAL but HEAVY: each prediction's patch is applied
# inside an isolated container and the repo's test suite is run. On Hopper
# (rootless, no Docker) this goes through the Apptainer-based evaluator
# (eval/run_singularity.py) instead of the stock Docker harness. The dataset
# is loaded offline via HF_HUB_OFFLINE=1, so pre-cache
# princeton-nlp/SWE-bench_Lite on a login node before submitting.
#
# USAGE (submit from the repo root):
#     cd /scratch/$USER/Agent-Bench   # your repo root
#     mkdir -p logs
#     sbatch slurm/grade_swebench.sh
#     # skip if the report already exists:
#     RESUME=1 sbatch slurm/grade_swebench.sh
#     # grade a different output family dir under data/:
#     FAM=codexhigh sbatch slurm/grade_swebench.sh
#     # bump parallel workers (watch memory -- each worker builds/runs a container):
#     MAX_WORKERS=8 sbatch slurm/grade_swebench.sh
#
#SBATCH --job-name=swebench-grade
#SBATCH --output=logs/swebench-grade-%j.out
#SBATCH --error=logs/swebench-grade-%j.err
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8      # ADAPT: >= MAX_WORKERS; each worker runs a test suite
#SBATCH --mem=32G              # ADAPT: container builds + test runs are memory-hungry
#SBATCH --time=08:00:00        # ADAPT: ~minutes/instance; 300 instances can take hours
#SBATCH --export=ALL
# ADAPT: SBATCH lines are parsed by SLURM, not the shell -- no $VAR expansion here.
#SBATCH --partition=normal
##SBATCH --account=your_account

set -euo pipefail

# --- knobs (env-overridable at submit time) ---------------------------------
FAM="${FAM:-codexlow}" # output family dir under data/
REPO_DIR="${REPO_DIR:-/scratch/czhai/Agent-Bench}"
CONDA_ENV="${CONDA_ENV:-bench}"
RESUME="${RESUME:-0}" # 1 = skip if report exists

DATA_DIR="${DATA_DIR:-$REPO_DIR/data/$FAM}"
EVAL_DIR="${EVAL_DIR:-$REPO_DIR/eval}"

# SWE-bench (containerized test execution via Apptainer)
SWEBENCH_PRED="${SWEBENCH_PRED:-$DATA_DIR/predictions.jsonl}"
SWEBENCH_DATASET="${SWEBENCH_DATASET:-princeton-nlp/SWE-bench_Lite}"
SWEBENCH_SPLIT="${SWEBENCH_SPLIT:-test}"
SWEBENCH_RUN_ID="${SWEBENCH_RUN_ID:-${FAM}_${SLURM_JOB_ID:-local}}"
SWEBENCH_REPORT="${SWEBENCH_REPORT:-$DATA_DIR/swebench_report.json}"
MAX_WORKERS="${MAX_WORKERS:-4}"
# ADAPT: point this at your Apptainer-based evaluator entrypoint. If you've
# switched to the stock harness (python -m swebench.harness.run_evaluation),
# swap the invocation below -- but the stock harness assumes Docker, which
# Hopper doesn't have.
SWEBENCH_EVAL="${SWEBENCH_EVAL:-$EVAL_DIR/swebench_singularity_eval.py}"

# offline HF dataset load (pre-cache on a login node first:
#   python -c "from datasets import load_dataset; load_dataset('princeton-nlp/SWE-bench_Lite')")
export HF_HUB_OFFLINE="${HF_HUB_OFFLINE:-1}"
export HF_DATASETS_OFFLINE="${HF_DATASETS_OFFLINE:-1}"
# keep Apptainer caches off the tiny node-local tmpfs
export APPTAINER_CACHEDIR="${APPTAINER_CACHEDIR:-/scratch/czhai/apptainer_cache}"
export APPTAINER_TMPDIR="${APPTAINER_TMPDIR:-/scratch/czhai/apptainer_tmp}"
# ----------------------------------------------------------------------------

# conda activation inside a non-interactive shell
source "$(conda info --base)/etc/profile.d/conda.sh"
conda activate "$CONDA_ENV"

cd "$REPO_DIR"
mkdir -p "$DATA_DIR" logs "$APPTAINER_CACHEDIR" "$APPTAINER_TMPDIR"

echo "host=$(hostname) job=${SLURM_JOB_ID:-local} fam=$FAM env=$CONDA_ENV resume=$RESUME workers=$MAX_WORKERS run_id=$SWEBENCH_RUN_ID"

# --- preflight ---------------------------------------------------------------
if [ "$RESUME" = "1" ] && [ -s "$SWEBENCH_REPORT" ]; then
  echo "[swebench] SKIP -- report exists: $SWEBENCH_REPORT"
  exit 0
fi
if [ ! -f "$SWEBENCH_PRED" ]; then
  echo "[swebench] FAILED -- predictions not found: $SWEBENCH_PRED" >&2
  exit 1
fi
if [ ! -f "$SWEBENCH_EVAL" ]; then
  echo "[swebench] FAILED -- evaluator not found: $SWEBENCH_EVAL" >&2
  exit 1
fi
if ! command -v apptainer >/dev/null 2>&1 && ! command -v singularity >/dev/null 2>&1; then
  echo "[swebench] FAILED -- apptainer/singularity not on PATH (module load apptainer?)" >&2
  exit 1
fi

# --- grade -------------------------------------------------------------------
echo
echo "========== STAGE: swebench =========="
# ADAPT: flag names below assume run_singularity.py mirrors the stock harness
# CLI (--predictions_path/--dataset_name/--split/--max_workers/--run_id).
# Adjust to match your evaluator's argparse if it differs.
echo "+ python $SWEBENCH_EVAL --predictions_path $SWEBENCH_PRED --dataset_name $SWEBENCH_DATASET --split $SWEBENCH_SPLIT --max_workers $MAX_WORKERS --run_id $SWEBENCH_RUN_ID"

rc=0
python "$SWEBENCH_EVAL" \
  --predictions_path "$SWEBENCH_PRED" \
  --dataset_name "$SWEBENCH_DATASET" \
  --split "$SWEBENCH_SPLIT" \
  --max_workers "$MAX_WORKERS" \
  --run_id "$SWEBENCH_RUN_ID" || rc=$?

# the harness-style evaluators write <model>.<run_id>.json in CWD; copy the
# newest matching report next to the predictions for a stable path.
latest_report="$(ls -t ./*."$SWEBENCH_RUN_ID".json 2>/dev/null | head -n1 || true)"
if [ -n "$latest_report" ]; then
  cp -f "$latest_report" "$SWEBENCH_REPORT"
  echo "[swebench] report copied: $latest_report -> $SWEBENCH_REPORT"
else
  echo "[swebench] WARNING -- no *.$SWEBENCH_RUN_ID.json report found in $PWD"
fi

echo
echo "========== SUMMARY =========="
if [ "$rc" -eq 0 ]; then
  echo "  swebench=0 (OK)"
else
  echo "  swebench=$rc (FAILED)"
fi
echo "swebench report -> $SWEBENCH_REPORT"
exit "$rc"
