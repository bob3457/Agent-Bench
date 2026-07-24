import argparse, sys
from pathlib import Path
try:
    import tomllib
except ImportError:
    import tomli as tomllib
ap = argparse.ArgumentParser()
ap.add_argument("--tasks", required=True); ap.add_argument("--sifs", required=True); ap.add_argument("--out", required=True)
a = ap.parse_args()
sif_dir = Path(a.sifs); rows, no_sif = [], []
for toml_path in sorted(Path(a.tasks).rglob("task.toml")):
    tdir = toml_path.parent; task = tdir.name
    try: cfg = tomllib.loads(toml_path.read_text())
    except Exception as e: print(f"WARN {task}: {e}", file=sys.stderr); continue
    if not (tdir/"instruction.md").exists(): continue
    sif = sif_dir/f"{task}.sif"
    if not sif.exists(): no_sif.append(task); continue
    at = int(cfg.get("agent",{}).get("timeout_sec",1800)); vt = int(cfg.get("verifier",{}).get("timeout_sec",1800))
    rows.append(f"{task}\t{tdir}\t{sif}\t{at}\t{vt}")
out = Path(a.out); out.parent.mkdir(parents=True, exist_ok=True)
out.write_text("\n".join(rows)+"\n")
print(f"manifest: {len(rows)} tasks -> {out}")
if no_sif: print(f"no SIF ({len(no_sif)}): {no_sif[:8]}")
