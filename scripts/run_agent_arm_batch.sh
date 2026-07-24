#!/usr/bin/env bash
# Batch agent-in-container runs over an instance list, with resume.
# Usage: bash scripts/run_agent_arm_batch.sh configs/instances_arm_pulled.txt [ITER]
set -euo pipefail
[ "$#" -ge 1 ] || { echo "Usage: $0 INSTANCE_LIST [ITER]" >&2; exit 2; }
LIST="$1"; ITER="${2:-1}"
RUN_ROOT="${RUN_ROOT:-/scratch/czhai/agent-runs-arm64}"
HERE="$(cd "$(dirname "$0")" && pwd)"
: "${OPENAI_API_KEY:?OPENAI_API_KEY not set}"
[ -f "$LIST" ] || { echo "Missing list: $LIST" >&2; exit 1; }

mapfile -t IDS < "$LIST"
echo "=== arm64 agent batch: ${#IDS[@]} instances, iter=$ITER ==="
for IID in "${IDS[@]}"; do
  [ -z "${IID// }" ] && continue
  [[ "$IID" =~ ^# ]] && continue
  if [ -f "$RUN_ROOT/$IID/iter_$ITER/metadata.json" ]; then
    echo "[skip] $IID"
    continue
  fi
  bash "$HERE/run_agent_arm_one.sh" "$IID" "$ITER" < /dev/null \
    || echo "[warn] failed: $IID" >&2
done

echo "=== exporting predictions.jsonl ==="
python3 - "$RUN_ROOT" "$ITER" <<'PY'
import json, sys
from pathlib import Path
run_root, it = Path(sys.argv[1]), sys.argv[2]
preds, empty, failed = [], [], []
for meta_path in sorted(run_root.glob(f"*/iter_{it}/metadata.json")):
    meta = json.loads(meta_path.read_text())
    iid = meta["instance_id"]
    patch = (meta_path.parent / "model.patch").read_text(errors="ignore")
    if meta.get("returncode") != 0:
        failed.append(iid)
    if not patch.strip():
        empty.append(iid)
    preds.append({
        "instance_id": iid,
        "model_name_or_path": meta.get("agent", "codex-arm64-incontainer"),
        "model_patch": patch,
    })
out = run_root / f"predictions_iter{it}.jsonl"
with out.open("w") as f:
    for p in preds:
        f.write(json.dumps(p) + "\n")
print(f"{len(preds)} predictions -> {out}")
if empty:
    print(f"EMPTY patches ({len(empty)}): {empty[:10]}{'...' if len(empty)>10 else ''}")
if failed:
    print(f"nonzero rc ({len(failed)}): {failed[:10]}{'...' if len(failed)>10 else ''}")
PY
echo "Grade elsewhere: python -m swebench.harness.run_evaluation \\"
echo "  --dataset_name princeton-nlp/SWE-bench_Verified --predictions_path <predictions_iterN.jsonl> \\"
echo "  --run_id arm64-agent --max_workers 4   (on the Docker machine)"
