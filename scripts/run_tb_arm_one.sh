#!/usr/bin/env bash
set -uo pipefail
[ "$#" -ge 5 ] || { echo "Usage: $0 TASK TASK_DIR SIF AGENT_T VERIF_T [ITER]" >&2; exit 2; }
TASK="$1"; TASK_DIR="$2"; SIF="$3"; AGENT_T="$4"; VERIF_T="$5"; ITER="${6:-1}"
: "${OPENAI_API_KEY:?OPENAI_API_KEY not set}"
[ "$(uname -m)" = "aarch64" ] || { echo "run on gracehopper" >&2; exit 1; }
RUN_ROOT="${RUN_ROOT:-/scratch/czhai/tb-runs-arm64}"
NODE_DIR="${NODE_DIR:-/scratch/czhai/node-v22.14.0-linux-arm64}"
NPM_GLOBAL="${NPM_GLOBAL:-/scratch/czhai/npm-global-arm64}"
PYTEST_VENV="${PYTEST_VENV:-/scratch/czhai/tb-arm64/pytest-libs}"
CODEX_MODEL="${CODEX_MODEL:-gpt-5.5}"; CODEX_REASONING="${CODEX_REASONING:-low}"
PERF_EVENTS="${PERF_EVENTS:-task-clock,cpu_cycles,inst_retired,l1d_cache,l1d_cache_refill,l2d_cache,l2d_cache_refill,br_retired,context-switches,cpu-migrations,page-faults}"
OUT="$RUN_ROOT/$TASK/iter_$ITER"; SANDBOX="$OUT/sandbox"
[ -f "$SIF" ] || { echo "Missing SIF: $SIF" >&2; exit 1; }
[ -f "$TASK_DIR/instruction.md" ] || { echo "Missing instruction.md" >&2; exit 1; }
rm -rf "$OUT"; mkdir -p "$OUT"
echo "[extract] $TASK"
apptainer build --sandbox "$SANDBOX" "$SIF" > "$OUT/extract.log" 2>&1 || { echo "extract failed" >&2; exit 1; }
mkdir -p "$SANDBOX/opt/node-arm64" "$SANDBOX/opt/npm-global" "$SANDBOX/opt/pytest-libs" "$SANDBOX/tb-tests"
WORKDIR=/app; apptainer exec "$SANDBOX" test -d /app || WORKDIR=/
PROMPT="$(cat "$TASK_DIR/instruction.md")"
START_NS="$(date +%s%N)"
echo "[agent] $TASK (workdir=$WORKDIR)"
set +e
timeout "$AGENT_T" \
/usr/bin/time -v -o "$OUT/time_v.txt" \
perf stat -x, -o "$OUT/perf_stat.csv" -e "$PERF_EVENTS" -- \
apptainer exec --writable --pwd "$WORKDIR" \
  -B "$NODE_DIR":/opt/node-arm64 -B "$NPM_GLOBAL":/opt/npm-global \
  --env OPENAI_API_KEY="$OPENAI_API_KEY" \
  --env PATH="/opt/node-arm64/bin:/opt/npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  "$SANDBOX" \
  codex --sandbox danger-full-access --ask-for-approval never \
    exec --skip-git-repo-check -m "$CODEX_MODEL" \
    -c "model_reasoning_effort=$CODEX_REASONING" --json "$PROMPT" \
    > "$OUT/stdout.jsonl" 2> "$OUT/stderr.txt"
RC=$?; set -e
END_NS="$(date +%s%N)"
RESOLVED="unknown"; VERIF_MODE="none"; VRC=1
if [ -d "$TASK_DIR/tests" ]; then
  cp -r --preserve=mode,timestamps "$TASK_DIR/tests/." "$SANDBOX/tb-tests/" || true
  echo "[verify] $TASK"
  set +e
  if [ -f "$TASK_DIR/tests/test.sh" ]; then
    timeout "$VERIF_T" apptainer exec --writable --pwd "$WORKDIR" --env TEST_DIR=/tb-tests \
      "$SANDBOX" bash /tb-tests/test.sh > "$OUT/verifier.log" 2>&1
    VRC=$?; VERIF_MODE="task_test_sh"
  fi
  if [ "$VRC" -ne 0 ] && ! grep -qE "[0-9]+ (passed|failed)" "$OUT/verifier.log" 2>/dev/null; then
    if [ -d "$PYTEST_VENV" ] && [ -f "$TASK_DIR/tests/test_outputs.py" ]; then
      timeout "$VERIF_T" apptainer exec --writable --pwd "$WORKDIR" \
        -B "$PYTEST_VENV":/opt/pytest-libs --env TEST_DIR=/tb-tests --env PYTHONPATH=/opt/pytest-libs \
        "$SANDBOX" python3 -m pytest /tb-tests/test_outputs.py -rA \
        > "$OUT/verifier.log" 2>&1
      VRC=$?; VERIF_MODE="host_venv_pytest"
    fi
  fi
  set -e
  if [ "$VRC" -eq 0 ]; then RESOLVED="true"
  elif grep -qE "[0-9]+ failed" "$OUT/verifier.log" 2>/dev/null; then RESOLVED="false"
  else RESOLVED="verifier_error"; fi
fi
python3 - <<PY
import json
from pathlib import Path
meta={"task":"$TASK","iteration":int("$ITER"),"returncode":int("$RC"),
"wall_ms":(int("$END_NS")-int("$START_NS"))/1e6,"resolved":"$RESOLVED",
"verifier_mode":"$VERIF_MODE","workdir":"$WORKDIR",
"agent":"codex-$CODEX_REASONING-$CODEX_MODEL-arm64-incontainer",
"perf_events":"$PERF_EVENTS","mode":"host_perf_wraps_container"}
Path("$OUT/metadata.json").write_text(json.dumps(meta,indent=2))
print(f"rc={meta['returncode']} wall={meta['wall_ms']/1000:.1f}s resolved={meta['resolved']} ({meta['verifier_mode']})")
PY
[ "${KEEP_SANDBOX:-0}" = "1" ] || rm -rf "$SANDBOX"
exit "$RC"
