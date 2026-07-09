#!/bin/bash
# Grade already-generated Agent-Bench SWE-bench Lite predictions on Hopper.
#
# SWE-bench grading is LOCAL but HEAVY: each prediction's patch is applied
# inside an isolated container and the repo's test suite is run. On Hopper
# (rootless, no Docker) this goes through the Apptainer-based evaluator
# (eval/swebench_singularity_eval.py) instead of the stock Docker harness. The
# dataset is loaded offline via HF_HUB_OFFLINE=1, so pre-cache
# princeton-nlp/SWE-bench_Lite on a login node before submitting.
#
# NOTE: the evaluator is SERIAL -- it grades one instance at a time (no
# --max_workers). Parallelize across families/jobs, not within one.
#
# USAGE (submit from the repo root):
#     cd /scratch/$USER/Agent-Bench   # your repo root
#     mkdir -p logs
#     sbatch slurm/grade_swebench.sh
#     # skip if the report already exists:
#     RESUME=1 sbatch slurm/grade_swebench.sh
#     # grade a different output family dir under data/:
#     FAM=codexhigh sbatch slurm/grade_swebench.sh
#     # grade a subset / bump per-instance timeout:
#     SWEBENCH_TIMEOUT=3600 sbatch slurm/grade_swebench.sh
#
#SBATCH --job-name=swebench-grade
#SBATCH --output=logs/swebench-grade-%j.out
#SBATCH --error=logs/swebench-grade-%j.err
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8      # ADAPT: test suites are multi-threaded even when grading serially
#SBATCH --mem=32G              # ADAPT: container starts + test runs are memory-hungry
#SBATCH --time=08:00:00        # ADAPT: ~minutes/instance; serial -- budget N x per-instance time
#SBATCH --export=ALL
# ADAPT: SBATCH lines are parsed by SLURM, not the shell -- no $VAR expansion here.
#SBATCH --partition=normal
##SBATCH --account=your_account

set -euo pipefail

# --- knobs (env-overridable at submit time) ---------------------------------
FAM="${FAM:-codexlow}" # output family dir under data/
REPO_DIR="${REPO_DIR:-/scratch/czhai/Agent-Bench}"
CONDA_ROOT="${CONDA_ROOT:-/projects/kzhou6/czhai/miniconda3}"
CONDA_ENV="${CONDA_ENV:-$CONDA_ROOT/envs/bench}"
RESUME="${RESUME:-0}" # 1 = skip if report exists

DATA_DIR="${DATA_DIR:-$REPO_DIR/data/$FAM}"
EVAL_DIR="${EVAL_DIR:-$REPO_DIR/eval}"

# SWE-bench (containerized test execution via Apptainer)
SWEBENCH_PRED="${SWEBENCH_PRED:-$DATA_DIR/predictions.jsonl}"
SWEBENCH_DATASET="${SWEBENCH_DATASET:-princeton-nlp/SWE-bench_Lite}"
SWEBENCH_SPLIT="${SWEBENCH_SPLIT:-test}"
SWEBENCH_RUN_ID="${SWEBENCH_RUN_ID:-${FAM}_${SLURM_JOB_ID:-local}}"
SWEBENCH_REPORT="${SWEBENCH_REPORT:-$DATA_DIR/swebench_report.json}"
# Evaluator-native knobs (see eval/swebench_singularity_eval.py argparse).
# The evaluator is SERIAL; there is no worker knob.
SWEBENCH_SIF_DIR="${SWEBENCH_SIF_DIR:-/scratch/czhai/sb_sifs}"
SWEBENCH_WORKDIR="${SWEBENCH_WORKDIR:-/scratch/czhai/sb_work/$SWEBENCH_RUN_ID}"
SWEBENCH_TIMEOUT="${SWEBENCH_TIMEOUT:-1800}" # per-instance seconds
APPTAINER_BIN="${APPTAINER_BIN:-apptainer}"  # binary name: apptainer | singularity
SWEBENCH_EVAL="${SWEBENCH_EVAL:-$EVAL_DIR/swebench_singularity_eval.py}"

# offline HF dataset load (pre-cache on a login node first:
#   python -c "from datasets import load_dataset; load_dataset('princeton-nlp/SWE-bench_Lite')")
export HF_HUB_OFFLINE="${HF_HUB_OFFLINE:-1}"
export HF_DATASETS_OFFLINE="${HF_DATASETS_OFFLINE:-1}"
# keep Apptainer caches off the tiny node-local tmpfs
export APPTAINER_CACHEDIR="${APPTAINER_CACHEDIR:-/scratch/czhai/apptainer_cache}"
export APPTAINER_TMPDIR="${APPTAINER_TMPDIR:-/scratch/czhai/apptainer_tmp}"
# ----------------------------------------------------------------------------

# Put the self-installed Apptainer >= 1.5 on PATH (bundled squashfuse_ll --
# SIFs FUSE-mount instead of sandbox-unpacking per instance); fall back to the
# system module if absent. Before conda so the env's python stays first.
APPTAINER_BINDIR="${APPTAINER_BINDIR:-/scratch/czhai/apptainer/bin}"
[ -d "$APPTAINER_BINDIR" ] && export PATH="$APPTAINER_BINDIR:$PATH"
if ! command -v apptainer >/dev/null 2>&1 && ! command -v singularity >/dev/null 2>&1; then
  set +u
  [ -f /etc/profile.d/lmod.sh ] && source /etc/profile.d/lmod.sh
  [ -n "${MODULESHOME:-}" ] && [ -f "$MODULESHOME/init/bash" ] && source "$MODULESHOME/init/bash"
  module load hosts/hopper apptainer/1.4.1 || echo "WARNING: apptainer module load failed"
  set -u
fi

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
mkdir -p "$DATA_DIR" logs "$APPTAINER_CACHEDIR" "$APPTAINER_TMPDIR" "$SWEBENCH_WORKDIR" "$SWEBENCH_SIF_DIR"

echo "host=$(hostname) job=${SLURM_JOB_ID:-local} fam=$FAM env=$CONDA_ENV resume=$RESUME run_id=$SWEBENCH_RUN_ID"
echo "apptainer: $(command -v "$APPTAINER_BIN" || echo MISSING) ($("$APPTAINER_BIN" --version 2>/dev/null || echo '?'))"
echo "sif_dir=$SWEBENCH_SIF_DIR workdir=$SWEBENCH_WORKDIR timeout=${SWEBENCH_TIMEOUT}s"

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
if ! command -v "$APPTAINER_BIN" >/dev/null 2>&1; then
  echo "[swebench] FAILED -- $APPTAINER_BIN not on PATH (set APPTAINER_BINDIR= or APPTAINER_BIN=singularity)" >&2
  exit 1
fi

# --- grade -------------------------------------------------------------------
echo
echo "========== STAGE: swebench =========="
# Evaluator CLI (eval/swebench_singularity_eval.py): --predictions/--dataset/
# --split/--sif-dir/--workdir/--timeout/--apptainer. SERIAL; prints
# per-instance RESOLVED/unresolved + "Resolved X/Y" to stderr and writes a
# per-instance report.json under the workdir -- no aggregate report file, so
# we assemble one below.
echo "+ python $SWEBENCH_EVAL --predictions $SWEBENCH_PRED --dataset $SWEBENCH_DATASET --split $SWEBENCH_SPLIT --sif-dir $SWEBENCH_SIF_DIR --workdir $SWEBENCH_WORKDIR --timeout $SWEBENCH_TIMEOUT --apptainer $APPTAINER_BIN"

rc=0
python "$SWEBENCH_EVAL" \
  --predictions "$SWEBENCH_PRED" \
  --dataset "$SWEBENCH_DATASET" \
  --split "$SWEBENCH_SPLIT" \
  --sif-dir "$SWEBENCH_SIF_DIR" \
  --workdir "$SWEBENCH_WORKDIR" \
  --timeout "$SWEBENCH_TIMEOUT" \
  --apptainer "$APPTAINER_BIN" || rc=$?

# Assemble the aggregate report (stock-harness-shaped headline fields) from
# the per-instance report.json files the evaluator leaves in the workdir.
python - "$SWEBENCH_WORKDIR" "$SWEBENCH_PRED" "$SWEBENCH_REPORT" <<'PYAGG' || rc=$?
import json, sys
from pathlib import Path
work, pred_path, out = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
submitted = [json.loads(l)["instance_id"]
             for l in pred_path.read_text().splitlines() if l.strip()]
per, resolved = {}, []
for rp in sorted(work.glob("*/report.json")):
    r = json.loads(rp.read_text())
    for iid, body in r.items():
        per[iid] = body
        if body.get("resolved"):
            resolved.append(iid)
report = {
    "total_instances": len(submitted),
    "submitted_instances": len(submitted),
    "completed_instances": len(per),
    "resolved_instances": len(resolved),
    "unresolved_instances": len(per) - len(resolved),
    "resolved_ids": sorted(resolved),
    "submitted_ids": sorted(submitted),
    "per_instance": per,
}
out.write_text(json.dumps(report, indent=2))
print(f"[swebench] resolved {len(resolved)}/{len(submitted)} "
      f"(completed {len(per)}) -> {out}")
PYAGG

echo
echo "========== SUMMARY =========="
if [ "$rc" -eq 0 ]; then
  echo "  swebench=0 (OK)"
else
  echo "  swebench=$rc (FAILED)"
fi
echo "swebench report -> $SWEBENCH_REPORT"
exit "$rc"
