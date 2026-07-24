#!/usr/bin/env bash
set -euo pipefail
[ "$#" -ge 1 ] || { echo "Usage: $0 MANIFEST [ITER]" >&2; exit 2; }
MANIFEST="$1"; ITER="${2:-1}"
RUN_ROOT="${RUN_ROOT:-/scratch/czhai/tb-runs-arm64}"
HERE="$(cd "$(dirname "$0")" && pwd)"
: "${OPENAI_API_KEY:?OPENAI_API_KEY not set}"
mapfile -t ROWS < "$MANIFEST"
for ROW in "${ROWS[@]}"; do
  [ -z "${ROW// }" ] && continue; [[ "$ROW" =~ ^# ]] && continue
  IFS=$'\t' read -r TASK TDIR SIF AT VT <<< "$ROW"
  [ -f "$RUN_ROOT/$TASK/iter_$ITER/metadata.json" ] && { echo "[skip] $TASK"; continue; }
  bash "$HERE/run_tb_arm_one.sh" "$TASK" "$TDIR" "$SIF" "$AT" "$VT" "$ITER" < /dev/null \
    || echo "[warn] failed: $TASK" >&2
done
python3 - "$RUN_ROOT" "$ITER" <<'PY'
import csv, json, sys
from pathlib import Path
root, it = Path(sys.argv[1]), sys.argv[2]
rows=[]
for m in sorted(root.glob(f"*/iter_{it}/metadata.json")):
    d=json.loads(m.read_text()); tc=None
    pf=m.parent/"perf_stat.csv"
    if pf.exists():
        for line in pf.read_text(errors="ignore").splitlines():
            p=[x.strip() for x in line.split(",")]
            if len(p)>=3 and p[2]=="task-clock" and not p[0].startswith("<"): tc=float(p[0]); break
    rows.append({"task":d["task"],"resolved":d["resolved"],"verifier_mode":d.get("verifier_mode"),
                 "rc":d["returncode"],"wall_s":round(d["wall_ms"]/1000,1),
                 "task_clock_ms":round(tc,1) if tc else ""})
out=root/f"tb_arm_summary_iter{it}.csv"
with out.open("w",newline="") as f:
    w=csv.DictWriter(f,fieldnames=list(rows[0].keys())); w.writeheader(); w.writerows(rows)
print(f"{len(rows)} tasks, {sum(1 for r in rows if r['resolved']=='true')} resolved -> {out}")
PY
