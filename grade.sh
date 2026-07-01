#!/bin/bash
# Grade already-generated Agent-Bench predictions (HotpotQA + FreshQA) on Hopper.
#
# HotpotQA grading is OFFLINE (official EM/F1 script vs the gold distractor file) --
# no API key, no internet. FreshQA grading uses an LLM JUDGE shelled out via
# `claude -p`, which needs Claude Code on PATH + auth + reachability to the
# Anthropic API from the compute node.
#
# USAGE (submit from ~/Agent-Bench):
#     cd ~/Agent-Bench
#     mkdir -p logs
#     # FreshQA judge auth -- OAuth token (NOT OPENAI_API_KEY):
#     export CLAUDE_CODE_OAUTH_TOKEN=...   # ADAPT: confirm var name (see note below)
#     sbatch grade_agentbench_claude.sh
#     # grade only one benchmark:
#     STAGES=hotpot  sbatch grade_agentbench_claude.sh
#     STAGES=freshqa sbatch grade_agentbench_claude.sh
#     # cap hotpot cases scored (optional 3rd arg to the eval script):
#     HOTPOT_LIMIT=100 sbatch grade_agentbench_claude.sh
#     # skip stages whose graded output already exists:
#     RESUME=1 sbatch grade_agentbench_claude.sh
#
#SBATCH --job-name=agentbench-grade
#SBATCH --output=logs/agentbench-grade-%j.out
#SBATCH --error=logs/agentbench-grade-%j.err
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=8G
#SBATCH --time=00:45:00        # hotpot is seconds; freshqa = ~1 judge call/item
#SBATCH --export=ALL           # propagate CLAUDE_CODE_OAUTH_TOKEN exported before sbatch
# ADAPT: SBATCH lines are parsed by SLURM, not the shell -- no $VAR expansion here.
#SBATCH --partition=normal
##SBATCH --account=your_account

set -euo pipefail

# --- knobs (env-overridable at submit time) ---------------------------------
FAM="${FAM:-claude}"                       # output family dir under data/
REPO_DIR="${REPO_DIR:-/scratch/czhai/Agent-Bench}"
CONDA_ENV="${CONDA_ENV:-bench}"
RESUME="${RESUME:-0}"                      # 1 = skip a stage if its graded file exists
STAGES="${STAGES:-hotpot freshqa}"         # subset: "hotpot", "freshqa", or both

DATA_DIR="${DATA_DIR:-$REPO_DIR/data/$FAM}"
EVAL_DIR="${EVAL_DIR:-$REPO_DIR/eval}"

# HotpotQA (offline EM/F1 vs gold)
HOTPOT_GOLD="${HOTPOT_GOLD:-$REPO_DIR/hotpot_dev_distractor_v1.json}"
HOTPOT_PRED="${HOTPOT_PRED:-$DATA_DIR/hotpot_predictions.json}"
HOTPOT_METRICS="${HOTPOT_METRICS:-$DATA_DIR/hotpot_metrics.txt}"
HOTPOT_LIMIT="${HOTPOT_LIMIT:-}"           # optional 3rd arg; empty = score all

# FreshQA (LLM judge)
FRESHQA_RESP="${FRESHQA_RESP:-$DATA_DIR/freshqa_responses.jsonl}"
FRESHQA_GRADED="${FRESHQA_GRADED:-$DATA_DIR/freshqa_graded.jsonl}"
FRESHQA_MODE="${FRESHQA_MODE:-both}"
JUDGE_CMD="${JUDGE_CMD:-claude -p}"
# ----------------------------------------------------------------------------

# conda activation inside a non-interactive shell
source "$(conda info --base)/etc/profile.d/conda.sh"
conda activate "$CONDA_ENV"

cd "$REPO_DIR"
mkdir -p "$DATA_DIR" logs

echo "host=$(hostname) job=${SLURM_JOB_ID:-local} fam=$FAM env=$CONDA_ENV stages='$STAGES' resume=$RESUME"

# does STAGES contain $1 ?
want () { case " $STAGES " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

declare -a STAGE_RESULTS=()
run_stage () {
    local name="$1"; shift
    echo; echo "========== STAGE: $name =========="; echo "+ $*"
    local rc=0
    "$@" || rc=$?
    if [ "$rc" -eq 0 ]; then echo "[$name] OK"
    else echo "[$name] FAILED (rc=$rc) -- continuing"; fi
    STAGE_RESULTS+=("$name=$rc")
}

# --- 1) HotpotQA (offline) --------------------------------------------------
if want hotpot; then
    if [ "$RESUME" = "1" ] && [ -s "$HOTPOT_METRICS" ]; then
        echo "[hotpot] SKIP -- metrics exist: $HOTPOT_METRICS"; STAGE_RESULTS+=("hotpot=skipped")
    elif [ ! -f "$HOTPOT_PRED" ]; then
        echo "[hotpot] SKIP -- predictions not found: $HOTPOT_PRED"; STAGE_RESULTS+=("hotpot=missing")
    elif [ ! -f "$HOTPOT_GOLD" ]; then
        echo "[hotpot] SKIP -- gold not found: $HOTPOT_GOLD"; STAGE_RESULTS+=("hotpot=missing")
    else
        # hotpot_evaluate_v1.py prints the metrics dict to stdout; tee it to disk.
        # Third positional arg (case cap) is optional -- only pass when set.
        run_stage hotpot bash -c '
            set -euo pipefail
            args=("'"$HOTPOT_PRED"'" "'"$HOTPOT_GOLD"'")
            [ -n "'"$HOTPOT_LIMIT"'" ] && args+=("'"$HOTPOT_LIMIT"'")
            python "'"$EVAL_DIR"'/hotpot_evaluate_v1.py" "${args[@]}" | tee "'"$HOTPOT_METRICS"'"
        '
    fi
fi

# --- 2) FreshQA (LLM judge via claude -p) -----------------------------------
if want freshqa; then
    if [ "$RESUME" = "1" ] && [ -s "$FRESHQA_GRADED" ]; then
        echo "[freshqa] SKIP -- graded exists: $FRESHQA_GRADED"; STAGE_RESULTS+=("freshqa=skipped")
    elif [ ! -f "$FRESHQA_RESP" ]; then
        echo "[freshqa] SKIP -- responses not found: $FRESHQA_RESP"; STAGE_RESULTS+=("freshqa=missing")
    else
        # ADAPT: the FreshQA judge shells out to `claude -p`, so it needs:
        #   (a) the `claude` binary on PATH (Claude Code installed on the node), and
        #   (b) auth via an env var. You said you'll pass an OAuth token -- the
        #       headless var is CLAUDE_CODE_OAUTH_TOKEN (generate with
        #       `claude setup-token` on a login node). VERIFY this name against
        #       your Claude Code version; if it rejects the token, fall back to
        #       ANTHROPIC_API_KEY. Either way, export it BEFORE sbatch.
        #   (c) network egress to the Anthropic API from the COMPUTE node. Your
        #       compute nodes are known to reach github.com/huggingface.co; if
        #       the API host is blocked there, grade FreshQA on a login/interactive
        #       node instead (salloc) or an egress-allowed partition.
        if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -z "${ANTHROPIC_API_KEY:-}" ]; then
            echo "[freshqa] FAILED -- no judge auth (export CLAUDE_CODE_OAUTH_TOKEN before sbatch)"
            STAGE_RESULTS+=("freshqa=noauth")
        elif ! command -v claude >/dev/null 2>&1; then
            echo "[freshqa] FAILED -- 'claude' not on PATH (Claude Code not installed on $(hostname))"
            STAGE_RESULTS+=("freshqa=noclaude")
        else
            echo "claude: $(command -v claude)"
            run_stage freshqa \
                python "$EVAL_DIR/eval_freshqa.py" \
                    --responses "$FRESHQA_RESP" \
                    --mode "$FRESHQA_MODE" \
                    --judge-cmd "$JUDGE_CMD" \
                    --graded-out "$FRESHQA_GRADED"
        fi
    fi
fi

# --- summary ----------------------------------------------------------------
echo; echo "========== SUMMARY =========="
fail=0
for r in "${STAGE_RESULTS[@]}"; do
    echo "  $r"
    case "$r" in *=0|*=skipped) ;; *) fail=1 ;; esac
done
echo "hotpot metrics -> $HOTPOT_METRICS"
echo "freshqa graded -> $FRESHQA_GRADED"
exit "$fail"