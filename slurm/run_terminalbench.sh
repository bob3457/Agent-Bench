#!/bin/bash
# Run Terminal-Bench 2.0 via Harbor on Hopper (SLURM). Self-contained: Harbor
# pulls the dataset from its registry -- no local dataset files needed (it does
# still shell out to git to clone the task repo, hence the git module below).
#
# Verified against harbor v0.16.1 source (laude-institute/harbor, 2026-07-02).
# NOTE: github.com/harbor-framework/terminal-bench is the LEGACY tb 0.2.x
# harness; the framework this script drives lives at laude-institute/harbor,
# and terminal-bench@2.0 resolves to laude-institute/terminal-bench-2.
#
# Verified on Hopper (2026-07-02):
#   - apptainer/1.4.1 gated behind hosts/hopper; ships a `singularity` symlink
#     (harbor's backend execs the `singularity` binary by name)
#   - rootless --fakeroot works via root-mapped userns (no /etc/subuid entry
#     needed; /proc/sys/user/max_user_namespaces > 0)
#   - no squashfuse on compute nodes -> every container start unpacks the SIF
#     to a temp sandbox; APPTAINER_TMPDIR must point at scratch
#   - Harbor's singularity backend defaults its SIF cache to a throwaway
#     tempfile.mkdtemp(); persist it via --ek singularity_image_cache_dir
#     (kwarg confirmed in SingularityEnvironment.__init__; cache is flock-
#     coordinated, safe to share across concurrent jobs)
#   - Harbor clones with --filter=blob:none; needs git/2.39.1-vd (gnu10 chain),
#     NOT the ungated git/2.27.1
#   - MODULE ORDER MATTERS: load hosts/hopper exactly ONCE. Reloading it resets
#     the compiler to gnu9, which INACTIVATES git/2.39.1-vd (gnu10-dependent)
#     and silently drops git off PATH. Apptainer first, then gnu10+git last.
#   - Harbor's in-container exec server needs /usr/bin/python3; its bootstrap
#     tries to install one and dies on minimal/distroless images
#     ("[harbor] FATAL: cannot install /usr/bin/python3" in trial.log).
#     Such tasks are permanently broken on this backend -> EXCLUDE_TASKS.
#   - `harbor run` exits 0 even when every trial raises an exception (verified
#     in cli/jobs.py: no exit-code propagation from stats). rc=0 != tasks ran.
#     result.json schema: {n_total_trials, stats: {n_completed_trials,
#     n_errored_trials, ...}} (legacy files may use n_trials/n_errors).
#
# Log capture (verified in trial.py + utils/path_filter.py):
#   - With NO --agent-include-logs/--verifier-include-logs flags, Harbor
#     downloads the ENTIRE agent + verifier logs directories unfiltered.
#   - Do NOT pass '**/*': the filter is fnmatch-based, and '**/*' requires a
#     '/' in the relative path -- it silently DROPS every top-level file
#     (trajectory.json, command output). Omitting the flags captures strictly
#     more. If you ever need filtering, '*' matches across '/' in fnmatch.
#   - Codex copies $CODEX_HOME/sessions (container CODEX_HOME=/tmp/codex-home)
#     and claude-code copies its session JSONLs into the agent logs dir
#     themselves, so rollouts land in the trial dir with no --artifact needed.
#
# Credentials (verified in agents/installed/*.py):
#   - Agents resolve creds via _get_env(): --ae extra_env first, then the
#     HOST os.environ. Plain exports (propagated by #SBATCH --export=ALL)
#     reach the container, so secrets are NOT passed via --ae -- argv is
#     world-readable in /proc on shared compute nodes.
#   - codex reads OPENAI_API_KEY; openhands-sdk requires LLM_API_KEY;
#     claude-code prefers ANTHROPIC_API_KEY unless CLAUDE_FORCE_OAUTH is
#     truthy, in which case it uses CLAUDE_CODE_OAUTH_TOKEN. We force OAuth
#     so a stray ANTHROPIC_API_KEY in the login env can't silently bill the
#     API instead of the subscription.
#
# USAGE (batch):
#     cd /scratch/czhai/Agent-Bench && mkdir -p logs
#     export OPENAI_API_KEY=sk-...            # codex / openhands-sdk
#     export CLAUDE_CODE_OAUTH_TOKEN=...      # claude-code
#     sbatch run_terminalbench_harbor.sh
#     # smoke test (1 task):   N_TASKS=1 sbatch run_terminalbench_harbor.sh
#     # pick agent/effort:     AGENT=codex EFFORT=high N_TASKS=25 sbatch run_terminalbench_harbor.sh
#     #                        AGENT=openhands-sdk EFFORT=medium sbatch run_terminalbench_harbor.sh
#     #                        AGENT=claude-code sbatch run_terminalbench_harbor.sh
#     # run one named task:    EXTRA_ARGS="-i hello-world" N_TASKS=1 sbatch run_terminalbench_harbor.sh
#     # extra exclusions:      EXCLUDE_TASKS="gpt2-codegolf some-other-task" sbatch run_terminalbench_harbor.sh
#
# USAGE (interactive, on an salloc'd compute node):
#     N_TASKS=1 N_CONCURRENT=1 AGENT=claude-code \
#         bash run_terminalbench_harbor.sh 2>&1 | tee logs/tbench-pilot-$(date +%s).log
#
#     # local machine (Docker): ENV_TYPE=docker bash run_terminalbench_harbor.sh
#
#SBATCH --job-name=agentbench-tbench
#SBATCH --output=logs/agentbench-tbench-%j.out
#SBATCH --error=logs/agentbench-tbench-%j.err
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --time=04:00:00        # tune to N_TASKS x per-task time (high effort is slowest)
#SBATCH --export=ALL
# ADAPT: set these to your Hopper allocation.
#SBATCH --partition=normal
##SBATCH --account=your_account

set -euo pipefail

# --- knobs -------------------------------------------------------------------
AGENT="${AGENT:-codex}"              # codex | openhands-sdk | claude-code
MODEL="${MODEL:-gpt-5.5}"            # bare name required for LiteLLM cost lookup
EFFORT="${EFFORT:-medium}"           # low | medium | high (codex/openhands only)
OPENHANDS_VERSION="${OPENHANDS_VERSION:-1.27.0}"

REPO_DIR="${REPO_DIR:-/scratch/czhai/Agent-Bench}"
SCRATCH_DIR="${SCRATCH_DIR:-/scratch/czhai}"
CONDA_ENV="${CONDA_ENV:-bench}"

DATASET="${DATASET:-terminal-bench@2.0}"
N_TASKS="${N_TASKS:-25}"
N_CONCURRENT="${N_CONCURRENT:-1}"
# Hopper has no Docker; Harbor's singularity backend is rootless-compatible.
# Use ENV_TYPE=docker when running on the local machine (ChrisWork) instead.
ENV_TYPE="${ENV_TYPE:-singularity}"
ENV_FILE="${ENV_FILE:-}"             # optional .env for the openhands example

# Space-separated task names to exclude (each becomes a -x flag; -x supports
# glob patterns). Grows as minimal/distroless images that can't host Harbor's
# python server surface.
# NOTE: keep this list IDENTICAL across agents/effort levels -- the reward-vs-
# cost comparison is only valid over the same task set.
EXCLUDE_TASKS="${EXCLUDE_TASKS:-gpt2-codegolf}"
# Raw harbor args appended verbatim, e.g. EXTRA_ARGS="-i hello-world --debug"
EXTRA_ARGS="${EXTRA_ARGS:-}"

# Cache/tmp locations -- all on scratch. Home quota is tight; SIF conversion,
# OCI layer blobs, and per-start sandbox unpacks are all disk-heavy.
export APPTAINER_CACHEDIR="${APPTAINER_CACHEDIR:-$SCRATCH_DIR/.apptainer_cache}"
export SINGULARITY_CACHEDIR="$APPTAINER_CACHEDIR"
export APPTAINER_TMPDIR="${APPTAINER_TMPDIR:-$SCRATCH_DIR/tmp}"
SIF_CACHE_DIR="${SIF_CACHE_DIR:-$SCRATCH_DIR/.harbor_sif_cache}"

# Versioned run ID: distinct jobs-dir entry per config so reruns never collide
# (Harbor refuses to start into an existing locked job dir).
RUN_ID="${RUN_ID:-tbench_${AGENT}_${EFFORT}_$(date +%Y%m%d_%H%M%S)}"
JOBS_DIR="${JOBS_DIR:-$REPO_DIR/data/harbor_jobs}"
# ------------------------------------------------------------------------------

source "$(conda info --base)/etc/profile.d/conda.sh"
conda activate "$CONDA_ENV"

cd "$REPO_DIR"
mkdir -p "$REPO_DIR/logs" "$JOBS_DIR"

# --- module handling (batch shells don't source login init; not nounset-clean)
# ORDER MATTERS (see header): hosts/hopper ONCE, apptainer first, git chain
# LAST -- a later hosts/hopper reload flips gnu10 -> gnu9 and inactivates git.
set +u
[ -f /etc/profile.d/lmod.sh ] && source /etc/profile.d/lmod.sh
[ -n "${MODULESHOME:-}" ] && [ -f "$MODULESHOME/init/bash" ] && source "$MODULESHOME/init/bash"
if [ "$ENV_TYPE" = "singularity" ]; then
    module load hosts/hopper apptainer/1.4.1 || echo "WARNING: apptainer module load failed"
    module load gnu10/10.3.0-ya git/2.39.1-vd || echo "WARNING: git module load failed"
else
    module load hosts/hopper gnu10/10.3.0-ya git/2.39.1-vd || echo "WARNING: git module load failed"
fi
set -u
[ -n "${GIT_BINDIR:-}" ]       && export PATH="$GIT_BINDIR:$PATH"
[ -n "${APPTAINER_BINDIR:-}" ] && export PATH="$APPTAINER_BINDIR:$PATH"

if [ "$ENV_TYPE" = "singularity" ]; then
    mkdir -p "$APPTAINER_CACHEDIR" "$APPTAINER_TMPDIR" "$SIF_CACHE_DIR"
fi

# --- preflight -----------------------------------------------------------------
command -v harbor >/dev/null 2>&1 || { echo "ERROR: harbor not on PATH"; exit 1; }
# Harbor clones the task repo before anything container-related.
command -v git >/dev/null 2>&1 \
    || { echo "ERROR: git not on PATH after module loads (check Lmod 'Inactive Modules' output above)"; exit 1; }
if [ "$ENV_TYPE" = "singularity" ]; then
    # Harbor shells out to `singularity`; apptainer/1.4.1 provides the symlink.
    command -v singularity >/dev/null 2>&1 \
        || { echo "ERROR: singularity not on PATH (module load failed? set APPTAINER_BINDIR=)"; exit 1; }
    # rootless fakeroot must work (root-mapped userns). Cheap sanity check:
    ns_max="$(cat /proc/sys/user/max_user_namespaces 2>/dev/null || echo 0)"
    [ "$ns_max" -gt 0 ] || { echo "ERROR: unprivileged user namespaces disabled on $(hostname)"; exit 1; }
fi

# --- per-agent args -----------------------------------------------------------
# ARGS collects agent selection, model, and kwargs. Credentials stay OUT of
# argv: harbor agents fall back to host os.environ (see header), and secrets
# on the command line are visible in /proc/<pid>/cmdline on shared nodes.
declare -a ARGS=()
case "$AGENT" in
    codex)
        : "${OPENAI_API_KEY:?OPENAI_API_KEY not set -- export it before sbatch/bash}"
        # codex agent reads OPENAI_API_KEY from host env directly.
        ARGS+=(--agent codex --model "$MODEL"
               --ak "reasoning_effort=$EFFORT")
        ;;
    openhands-sdk)
        : "${OPENAI_API_KEY:?OPENAI_API_KEY not set -- export it before sbatch/bash}"
        # openhands-sdk runner hard-requires LLM_API_KEY (not OPENAI_API_KEY).
        export LLM_API_KEY="$OPENAI_API_KEY"
        ARGS+=(--agent openhands-sdk --model "$MODEL"
               --ak "reasoning_effort=$EFFORT"
               --ak "version=$OPENHANDS_VERSION")
        ;;
    claude-code)
        : "${CLAUDE_CODE_OAUTH_TOKEN:?CLAUDE_CODE_OAUTH_TOKEN not set -- export it before sbatch/bash}"
        # Without CLAUDE_FORCE_OAUTH, harbor's claude-code agent prefers any
        # ANTHROPIC_API_KEY it finds in the host env (--export=ALL leaks the
        # login env in!) and would silently bill the API. Force subscription.
        export CLAUDE_FORCE_OAUTH=1
        ARGS+=(--agent claude-code)
        # claude-code takes no reasoning_effort kwarg; model left at agent default.
        # To pin one, uncomment:
        # ARGS+=(--model "$MODEL")
        ;;
    *)
        echo "ERROR: unknown AGENT=$AGENT (expected codex|openhands-sdk|claude-code)"; exit 1
        ;;
esac

[ -n "$ENV_FILE" ] && ARGS+=(--env-file "$ENV_FILE")

# --- task exclusions + raw passthrough ------------------------------------------
for t in $EXCLUDE_TASKS; do
    ARGS+=(-x "$t")
done
# shellcheck disable=SC2206  # intentional word splitting of raw harbor args
[ -n "$EXTRA_ARGS" ] && ARGS+=($EXTRA_ARGS)

# --- environment kwargs ---------------------------------------------------------
if [ "$ENV_TYPE" = "singularity" ]; then
    # Persist converted SIFs across runs (backend default is a throwaway
    # mkdtemp -> full docker->SIF re-conversion every job). Cache is .lock-file
    # coordinated, safe to share across concurrent jobs.
    ARGS+=(--ek "singularity_image_cache_dir=$SIF_CACHE_DIR")
fi

# --- log capture ------------------------------------------------------------------
# INTENTIONALLY no --agent-include-logs / --verifier-include-logs: with no
# filter flags Harbor downloads BOTH logs directories in full, which is what
# feeds parse_codex.py / ccusage later. Passing '**/*' here is a trap -- the
# filter is fnmatch-based and '**/*' needs a '/', so it drops every top-level
# file (trajectory.json included). Codex + claude-code both copy their session
# rollouts into the agent logs dir themselves, so no --artifact needed either.

echo "host=$(hostname) job=${SLURM_JOB_ID:-local}"
echo "agent=$AGENT model=$MODEL effort=$EFFORT env=$ENV_TYPE"
echo "dataset=$DATASET n_tasks=$N_TASKS n_concurrent=$N_CONCURRENT"
echo "exclude=[$EXCLUDE_TASKS] extra_args=[$EXTRA_ARGS]"
echo "run_id=$RUN_ID jobs_dir=$JOBS_DIR"
echo "harbor: $(command -v harbor) ($(harbor --version 2>/dev/null || echo '?'))"
echo "git: $(command -v git) ($(git --version 2>/dev/null || echo '?'))"
if [ "$ENV_TYPE" = "singularity" ]; then
    echo "singularity: $(command -v singularity) ($(singularity --version 2>/dev/null || echo '?'))"
    echo "caches: APPTAINER_CACHEDIR=$APPTAINER_CACHEDIR TMPDIR=$APPTAINER_TMPDIR SIF=$SIF_CACHE_DIR"
fi

echo
echo "========== STAGE: terminal-bench =========="
rc=0
harbor run \
    --dataset "$DATASET" \
    --env "$ENV_TYPE" \
    --n-tasks "$N_TASKS" \
    --n-concurrent "$N_CONCURRENT" \
    --job-name "$RUN_ID" \
    --jobs-dir "$JOBS_DIR" \
    --yes \
    "${ARGS[@]}" || rc=$?

# `harbor run` exits 0 even when trials raise exceptions; surface that here so
# batch jobs don't silently "succeed" with zero completed trials.
# result.json: {n_total_trials, stats: {n_completed_trials, n_errored_trials}}
# (legacy runs used stats.n_trials / stats.n_errors -- handled below).
RESULT_JSON="$JOBS_DIR/$RUN_ID/result.json"
if [ "$rc" -eq 0 ]; then
    if [ -f "$RESULT_JSON" ]; then
        summary="$(python - "$RESULT_JSON" <<'PYEOF'
import json, sys
r = json.load(open(sys.argv[1]))
s = r.get("stats", {})
n_err = s.get("n_errored_trials", s.get("n_errors", 0)) or 0
n_done = s.get("n_completed_trials", s.get("n_trials", 0)) or 0
n_total = r.get("n_total_trials", 0) or 0
print(f"{n_err} {n_done} {n_total}")
PYEOF
        )" || summary=""
        if [ -n "$summary" ]; then
            read -r n_err n_done n_total <<< "$summary"
            echo "trials: total=$n_total completed=$n_done errored=$n_err (see $RESULT_JSON)"
            if [ "$n_err" -gt 0 ]; then
                echo "WARNING: $n_err trial(s) errored despite rc=0"; rc=2
            elif [ "$n_done" -eq 0 ]; then
                echo "WARNING: 0 trials completed despite rc=0"; rc=2
            fi
        else
            echo "WARNING: could not parse $RESULT_JSON"; rc=2
        fi
    else
        echo "WARNING: rc=0 but $RESULT_JSON missing -- job likely never started trials"; rc=2
    fi
fi
if [ "$rc" -eq 0 ]; then echo "[terminal-bench] OK"; else echo "[terminal-bench] FAILED/PARTIAL (rc=$rc)"; fi

echo "results + logs under $JOBS_DIR/$RUN_ID/"
exit "$rc"