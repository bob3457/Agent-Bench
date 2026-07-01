#!/bin/bash
# Run all three Agent-Bench generation harnesses (SWE-bench, HotpotQA, FreshQA)
# with the Codex agent on Hopper (SLURM), sequentially in one job.
#
# USAGE (submit from ~/Agent-Bench):
#     cd ~/Agent-Bench
#     mkdir -p logs                       # SLURM won't create --output dirs
#     export OPENAI_API_KEY=sk-...        # consumed by codex exec
#     sbatch run_agentbench_codex.sh
#     # override any knob at submit time, e.g. a quick smoke test:
#     SWE_N=3 HOTPOT_LIMIT=5 FRESHQA_LIMIT=5 sbatch run_agentbench_codex.sh
#     # resume after a timeout/requeue (skips work already on disk):
#     RESUME=1 sbatch run_agentbench_codex.sh
#
#SBATCH --job-name=agentbench-codex
#SBATCH --output=logs/agentbench-codex-%j.out
#SBATCH --error=logs/agentbench-codex-%j.err
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --time=01:00:00        # SWE-bench dominates; tune to SWE_N x per-instance time
#SBATCH --export=ALL           # propagate the OPENAI_API_KEY you exported before sbatch
# ADAPT: SBATCH directives are parsed by SLURM, not the shell -- no $VAR expansion here.
#        Set these to your Hopper allocation.
#SBATCH --partition=normal
##SBATCH --account=your_account

set -euo pipefail

# --- knobs (env-overridable at submit time) ---------------------------------
AGENT="${AGENT:-codex}"
REPO_DIR="${REPO_DIR:-/scratch/czhai/Agent-Bench}"
CONDA_ENV="${CONDA_ENV:-bench}"
RESUME="${RESUME:-0}"          # 1 = skip work already on disk (requeue-friendly)

SWE_N="${SWE_N:-25}"
HOTPOT_LIMIT="${HOTPOT_LIMIT:-50}"
FRESHQA_LIMIT="${FRESHQA_LIMIT:-50}"

# The harness scripts live in <repo>/harness/ (they resolve agents.yaml and the
# data/ output dir from __file__, so running from here still writes to <repo>/data/).
HARNESS_DIR="${HARNESS_DIR:-$REPO_DIR/harness}"

# ADAPT: dataset file locations. Both ship at the repo root in this repo.
HOTPOT_INPUT="${HOTPOT_INPUT:-$REPO_DIR/hotpot_dev_distractor_v1.json}"
FRESHQA_INPUT="${FRESHQA_INPUT:-$REPO_DIR/freshqa.csv}"

# FreshQA is OPEN-BOOK (needs live web). Plain `codex` is closed-book unless its
# agents.yaml row enables web search. If you have a search-enabled variant, set
# FRESHQA_AGENT=codex-search. With plain codex the harness prints a closed-book
# WARNING -- expected, since codex never reports web_search_requests; it is not
# a reliable liveness signal for codex.
FRESHQA_AGENT="${FRESHQA_AGENT:-$AGENT}"
# ----------------------------------------------------------------------------

# Fail fast if the key didn't make it through (export it BEFORE sbatch).
: "${OPENAI_API_KEY:?OPENAI_API_KEY not set -- run: export OPENAI_API_KEY=... before sbatch}"

# conda activation inside a non-interactive shell
source "$(conda info --base)/etc/profile.d/conda.sh"
conda activate "$CONDA_ENV"

cd "$REPO_DIR"
mkdir -p "$REPO_DIR/logs"

# ADAPT: compute nodes ship a bare PATH; git comes from a module.
# Lmod's `module` is a shell function set up by login init, which a batch script
# does NOT source -- and the init scripts/function aren't nounset-clean, so
# relax `-u` just around the module handling.
set +u
[ -f /etc/profile.d/lmod.sh ] && source /etc/profile.d/lmod.sh
[ -n "${MODULESHOME:-}" ] && [ -f "$MODULESHOME/init/bash" ] && source "$MODULESHOME/init/bash"
module load git/2.27.1 || echo "WARNING: 'module load git/2.27.1' failed"
# To use the newer git/2.39.1-vd instead, it's gated behind a toolchain; load
# the chain first (per `module spider git/2.39.1-vd`):
#     module load hosts/hopper gnu10/10.3.0-ya git/2.39.1-vd
set -u

# Bulletproof fallback if modules won't initialize in batch: hardcode git's
# bindir. Find it ONCE on a login node where `module` works:
#     module load git/2.39.1-vd && dirname "$(command -v git)"
# then run with GIT_BINDIR=/that/path (module software lives on shared storage,
# so the path is valid on every node).
[ -n "${GIT_BINDIR:-}" ] && export PATH="$GIT_BINDIR:$PATH"

# preflight: binaries the harnesses shell out to
command -v codex >/dev/null 2>&1 || { echo "ERROR: codex not on PATH"; exit 1; }
command -v git   >/dev/null 2>&1 || { echo "ERROR: git not on PATH";   exit 1; }

# Cache HF datasets + repo clones on a persistent path.
# ADAPT: SWE-bench fetches princeton-nlp/SWE-bench_Lite (HF) and clones repos
#        from github.com. If Hopper COMPUTE nodes have no internet, pre-warm on
#        the login node first, then this job runs offline.
export HF_HOME="${HF_HOME:-$REPO_DIR/.hf_cache}"

# Translate RESUME knob into the flag the QA harnesses understand.
# (SWE-bench resumes automatically by skipping instance_ids already predicted.)
RESUME_ARG=""
[ "$RESUME" = "1" ] && RESUME_ARG="--resume"

echo "host=$(hostname) job=${SLURM_JOB_ID:-local} agent=$AGENT env=$CONDA_ENV"
echo "codex: $(command -v codex)"
echo "swe_n=$SWE_N hotpot_limit=$HOTPOT_LIMIT freshqa_limit=$FRESHQA_LIMIT resume=$RESUME"

# Run a stage WITHOUT letting one failure abort the remaining stages.
declare -a STAGE_RESULTS=()
run_stage () {
    local name="$1"; shift
    echo
    echo "========== STAGE: $name =========="
    echo "+ $*"
    local rc=0
    "$@" || rc=$?
    if [ "$rc" -eq 0 ]; then echo "[$name] OK"
    else echo "[$name] FAILED (rc=$rc) -- continuing to next stage"; fi
    STAGE_RESULTS+=("$name=$rc")
}

# 1) SWE-bench_Lite (closed-book by design) -- no --input; loads split from HF.
#run_stage swebench \
#    python "$HARNESS_DIR/run_swebench_agent.py" --agent "$AGENT" --n "$SWE_N"

#2) HotpotQA (closed-book) -- needs the distractor JSON.
if [ -f "$HOTPOT_INPUT" ]; then
    run_stage hotpotqa \
        python "$HARNESS_DIR/run_hotpot_agent.py" --agent "$AGENT" \
            --input "$HOTPOT_INPUT" --limit "$HOTPOT_LIMIT" $RESUME_ARG
else
    echo "[hotpotqa] SKIP -- input not found: $HOTPOT_INPUT (set HOTPOT_INPUT=...)"
    STAGE_RESULTS+=("hotpotqa=skipped")
fi

# 3) FreshQA (open-book) -- needs the CSV.
#if [ -f "$FRESHQA_INPUT" ]; then
#    run_stage freshqa \
#        python "$HARNESS_DIR/run_freshqa_agent.py" --agent "$FRESHQA_AGENT" \
#            --input "$FRESHQA_INPUT" --limit "$FRESHQA_LIMIT" $RESUME_ARG
#else
#    echo "[freshqa] SKIP -- input not found: $FRESHQA_INPUT (set FRESHQA_INPUT=...)"
#    STAGE_RESULTS+=("freshqa=skipped")
#fi

echo
echo "========== SUMMARY =========="
fail=0
for r in "${STAGE_RESULTS[@]}"; do
    echo "  $r"
    case "$r" in *=0|*=skipped) ;; *) fail=1 ;; esac
done
fam="${AGENT%%-*}"
echo "predictions under data/$fam/  (freshqa under data/${FRESHQA_AGENT%%-*}/)"
exit "$fail"   # non-zero if any stage genuinely failed, so SLURM marks it FAILED