#!/usr/bin/env bash
# Run codex INSIDE an arm64 SWE-bench task container and export the patch.
# Grading happens elsewhere (official harness + Docker); this only produces
# model patches + telemetry.
#
# Usage: bash scripts/run_agent_arm_one.sh <instance_id> [iter]
# Env:
#   SIF_DIR      default /scratch/czhai/sifs-arm64
#   RUN_ROOT     default /scratch/czhai/agent-runs-arm64
#   NODE_DIR     default /scratch/czhai/node-v22.14.0-linux-arm64
#   NPM_GLOBAL   default /scratch/czhai/npm-global-arm64
#   PROMPT_DIR   default $RUN_ROOT/prompts  (from make_swebench_prompts.py)
#   CODEX_MODEL / CODEX_REASONING   default gpt-5.5 / low
#   OPENAI_API_KEY  required
#   KEEP_SANDBOX=1  keep sandbox after run (debugging)
set -uo pipefail
[ "$#" -ge 1 ] || { echo "Usage: $0 <instance_id> [iter]" >&2; exit 2; }
IID="$1"; ITER="${2:-1}"
: "${OPENAI_API_KEY:?OPENAI_API_KEY not set}"
[ "$(uname -m)" = "aarch64" ] || { echo "ERROR: ARM PERF_EVENTS but node is $(uname -m); run on gracehopper" >&2; exit 1; }
PERF_EVENTS="${PERF_EVENTS:-task-clock,cpu_cycles,inst_retired,l1d_cache,l1d_cache_refill,l2d_cache,l2d_cache_refill,br_retired,context-switches,cpu-migrations,page-faults}"

SIF_DIR="${SIF_DIR:-/scratch/czhai/sifs-arm64}"
RUN_ROOT="${RUN_ROOT:-/scratch/czhai/agent-runs-arm64}"
NODE_DIR="${NODE_DIR:-/scratch/czhai/node-v22.14.0-linux-arm64}"
NPM_GLOBAL="${NPM_GLOBAL:-/scratch/czhai/npm-global-arm64}"
PROMPT_DIR="${PROMPT_DIR:-$RUN_ROOT/prompts}"
CODEX_MODEL="${CODEX_MODEL:-gpt-5.5}"
CODEX_REASONING="${CODEX_REASONING:-low}"

SIF="$SIF_DIR/$IID.sif"
PROMPT_FILE="$PROMPT_DIR/$IID.txt"
OUT="$RUN_ROOT/$IID/iter_$ITER"
SANDBOX="$OUT/sandbox"
[ -f "$SIF" ] || { echo "Missing SIF: $SIF" >&2; exit 1; }
[ -f "$PROMPT_FILE" ] || { echo "Missing prompt: $PROMPT_FILE (run make_swebench_prompts.py)" >&2; exit 1; }
[ -d "$NODE_DIR" ] || { echo "Missing node dir: $NODE_DIR" >&2; exit 1; }
[ -d "$NPM_GLOBAL" ] || { echo "Missing npm-global: $NPM_GLOBAL" >&2; exit 1; }

rm -rf "$OUT"; mkdir -p "$OUT"
echo "[extract] $IID"
apptainer build --sandbox "$SANDBOX" "$SIF" > "$OUT/extract.log" 2>&1 \
  || { echo "extract failed, see $OUT/extract.log" >&2; exit 1; }
mkdir -p "$SANDBOX/opt/node-arm64" "$SANDBOX/opt/npm-global"

# record base state so the diff is exactly the agent's work
apptainer exec --pwd /testbed "$SANDBOX" bash -lc \
  'git rev-parse HEAD && git status --porcelain | head' > "$OUT/base_state.txt" 2>&1

PROMPT="$(cat "$PROMPT_FILE")"
START_NS="$(date +%s%N)"
echo "[agent] $IID"
set +e
/usr/bin/time -v -o "$OUT/time_v.txt" \
perf stat -x, -o "$OUT/perf_stat.csv" -e "$PERF_EVENTS" -- \
apptainer exec --writable --pwd /testbed \
  -B "$NODE_DIR":/opt/node-arm64 \
  -B "$NPM_GLOBAL":/opt/npm-global \
  --env OPENAI_API_KEY="$OPENAI_API_KEY" \
  --env PATH="/opt/node-arm64/bin:/opt/npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  "$SANDBOX" \
  codex \
    --sandbox danger-full-access \
    --ask-for-approval never \
    exec \
    --skip-git-repo-check \
    -m "$CODEX_MODEL" \
    -c "model_reasoning_effort=$CODEX_REASONING" \
    --json \
    "$PROMPT" \
    > "$OUT/stdout.jsonl" 2> "$OUT/stderr.txt"
RC=$?
set -e
END_NS="$(date +%s%N)"

echo "[diff] $IID"
apptainer exec --pwd /testbed "$SANDBOX" bash -lc \
  'git -c core.fileMode=false diff' > "$OUT/model.patch" 2> "$OUT/diff.err"

python3 - <<PY
import json
from pathlib import Path
out = Path("$OUT")
patch = out.joinpath("model.patch").read_text(errors="ignore")
meta = {
    "instance_id": "$IID",
    "iteration": int("$ITER"),
    "returncode": int("$RC"),
    "wall_ms": (int("$END_NS") - int("$START_NS")) / 1e6,
    "patch_bytes": len(patch),
    "patch_empty": not patch.strip(),
    "agent": "codex-$CODEX_REASONING-$CODEX_MODEL-arm64-incontainer",
    "perf_events": "$PERF_EVENTS",
    "mode": "host_perf_wraps_container",
}
out.joinpath("metadata.json").write_text(json.dumps(meta, indent=2))
print(f"rc={meta['returncode']} wall={meta['wall_ms']/1000:.1f}s patch={meta['patch_bytes']}B"
      + (" (EMPTY)" if meta["patch_empty"] else ""))
PY

if [ "${KEEP_SANDBOX:-0}" != "1" ]; then
  rm -rf "$SANDBOX"
fi
exit "$RC"
