#!/bin/bash
# Grade already-generated Agent-Bench FreshQA responses on Hopper.
#
# FreshQA grading uses an LLM JUDGE shelled out via JUDGE_CMD. eval_freshqa.py
# shlex-splits JUDGE_CMD and appends the judge prompt as the final argv
# element, then parses the trailing TRUE/FALSE from stdout -- so the command
# must (a) run headless and (b) print reasonably clean output.
#
# DEFAULT JUDGE: Codex CLI at low reasoning effort. Needs the `codex` musl
# binary on PATH, CODEX_HOME auth (auth.json from `codex login` on a login
# node), and egress to the OpenAI API from the compute node.
#
# TO SWITCH THE JUDGE TO CLAUDE CODE: submit with
#     export CLAUDE_CODE_OAUTH_TOKEN=...            # `claude setup-token` on a login node
#     JUDGE_CMD="claude -p" sbatch slurm/grade_fresh.sh
# (or edit the JUDGE_CMD default below). Claude needs the `claude` binary on
# PATH + egress to the Anthropic API. If the token is rejected, fall back to
# ANTHROPIC_API_KEY.
#
# USAGE (submit from the repo root):
#     cd /projects/kzhou6/czhai/Agent-Bench   # your repo root
#     mkdir -p logs
#     sbatch slurm/grade_fresh.sh
#     # skip if graded output already exists:
#     RESUME=1 sbatch slurm/grade_fresh.sh
#     # grade a different output family dir under data/:
#     FAM=codexhigh sbatch slurm/grade_fresh.sh
#
#SBATCH --job-name=freshqa-grade
#SBATCH --output=logs/freshqa-grade-%j.out
#SBATCH --error=logs/freshqa-grade-%j.err
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=8G
#SBATCH --time=00:45:00        # ~1 judge call/item
#SBATCH --export=ALL           # propagate CODEX_HOME / CLAUDE_CODE_OAUTH_TOKEN exported before sbatch
# ADAPT: SBATCH lines are parsed by SLURM, not the shell -- no $VAR expansion here.
#SBATCH --partition=normal
##SBATCH --account=your_account

set -euo pipefail

# --- knobs (env-overridable at submit time) ---------------------------------
FAM="${FAM:-codexlow}" # output family dir under data/
REPO_DIR="${REPO_DIR:-/projects/kzhou6/czhai/Agent-Bench}"
CONDA_ROOT="${CONDA_ROOT:-/projects/kzhou6/czhai/miniconda3}"
CONDA_ENV="${CONDA_ENV:-$CONDA_ROOT/envs/bench}"
RESUME="${RESUME:-0}" # 1 = skip if graded file exists

DATA_DIR="${DATA_DIR:-$REPO_DIR/data/$FAM}"
EVAL_DIR="${EVAL_DIR:-$REPO_DIR/eval}"

FRESHQA_RESP="${FRESHQA_RESP:-$DATA_DIR/freshqa_responses.jsonl}"
FRESHQA_GRADED="${FRESHQA_GRADED:-$DATA_DIR/freshqa_graded.jsonl}"
FRESHQA_MODE="${FRESHQA_MODE:-both}"

# JUDGE: Codex CLI, headless, low reasoning effort (cheap; a grading rubric
# doesn't benefit from high effort). NOTE: bare `codex` launches the
# interactive TUI and hangs a batch job -- `codex exec` is the headless mode.
# --skip-git-repo-check: codex exec refuses to run outside a trusted git repo,
#                        and the eval may invoke it from an arbitrary cwd.
# -s read-only:          judge only reads a rubric; deny file writes.
JUDGE_CMD="${JUDGE_CMD:-codex exec --skip-git-repo-check -s read-only -c model_reasoning_effort=low}"
#
# To use Claude Code as the judge instead, override at submit time:
#     JUDGE_CMD="claude -p" sbatch slurm/grade_fresh.sh
# or swap the default above for:
#     JUDGE_CMD="${JUDGE_CMD:-claude -p}"
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

echo "host=$(hostname) job=${SLURM_JOB_ID:-local} fam=$FAM env=$CONDA_ENV resume=$RESUME judge='$JUDGE_CMD'"

# --- preflight ---------------------------------------------------------------
if [ "$RESUME" = "1" ] && [ -s "$FRESHQA_GRADED" ]; then
  echo "[freshqa] SKIP -- graded exists: $FRESHQA_GRADED"
  exit 0
fi
if [ ! -f "$FRESHQA_RESP" ]; then
  echo "[freshqa] FAILED -- responses not found: $FRESHQA_RESP" >&2
  exit 1
fi

# The judge binary is the first word of JUDGE_CMD -- works for both
# "codex exec ..." and "claude -p".
JUDGE_BIN="${JUDGE_CMD%% *}"
if ! command -v "$JUDGE_BIN" >/dev/null 2>&1; then
  echo "[freshqa] FAILED -- judge binary '$JUDGE_BIN' not on PATH on $(hostname)" >&2
  exit 1
fi
echo "judge binary: $(command -v "$JUDGE_BIN")"

# Judge-specific auth checks. eval_freshqa.py doesn't preflight the judge
# (it's separate from agent_core), so catch auth problems here instead of
# failing once per item.
case "$JUDGE_BIN" in
  codex)
    # Codex auths via auth.json under CODEX_HOME (~/.codex if unset).
    # Run `codex login` (or place auth.json) on a login node first; the
    # compute node also needs egress to the OpenAI API.
    CODEX_AUTH="${CODEX_HOME:-$HOME/.codex}/auth.json"
    if [ ! -f "$CODEX_AUTH" ] && [ -z "${OPENAI_API_KEY:-}" ]; then
      echo "[freshqa] FAILED -- no codex auth: $CODEX_AUTH missing and OPENAI_API_KEY unset" >&2
      exit 1
    fi
    ;;
  claude)
    # Claude Code auths headlessly via CLAUDE_CODE_OAUTH_TOKEN (generate
    # with `claude setup-token` on a login node) or ANTHROPIC_API_KEY.
    # Export it BEFORE sbatch (--export=ALL propagates it). The compute
    # node also needs egress to the Anthropic API.
    if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -z "${ANTHROPIC_API_KEY:-}" ]; then
      echo "[freshqa] FAILED -- no judge auth (export CLAUDE_CODE_OAUTH_TOKEN before sbatch)" >&2
      exit 1
    fi
    ;;
  *)
    echo "[freshqa] WARNING -- unrecognized judge '$JUDGE_BIN'; skipping auth preflight"
    ;;
esac

# --- grade -------------------------------------------------------------------
echo
echo "========== STAGE: freshqa =========="
echo "+ python $EVAL_DIR/eval_freshqa.py --responses $FRESHQA_RESP --mode $FRESHQA_MODE --judge-cmd '$JUDGE_CMD' --graded-out $FRESHQA_GRADED"

rc=0
python "$EVAL_DIR/eval_freshqa.py" \
  --responses "$FRESHQA_RESP" \
  --mode "$FRESHQA_MODE" \
  --judge-cmd "$JUDGE_CMD" \
  --graded-out "$FRESHQA_GRADED" || rc=$?

echo
echo "========== SUMMARY =========="
if [ "$rc" -eq 0 ]; then
  echo "  freshqa=0 (OK)"
else
  echo "  freshqa=$rc (FAILED)"
fi
echo "freshqa graded -> $FRESHQA_GRADED"
exit "$rc"
