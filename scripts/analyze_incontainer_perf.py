#!/usr/bin/env python3
"""Summarize arm64 in-container agent runs (SWE-bench or any run_root with the
same metadata.json + perf_stat.csv layout) into a per-instance CSV and a
repo-grouped summary, in the same frame as the hotpot/freshqa metrics tables.

Per-instance columns: repo, instance, resolved-fields (rc/patch), wall_s,
task_clock_s, cpu_util_pct, ipc, l1d_refill_rate, l2d_refill_rate,
context_switches, cpu_migrations, page_faults, tokens (if present in stdout).

Usage:
  python3 analyze_incontainer_perf.py --root /scratch/czhai/agent-runs-arm64 --iter 1
  python3 analyze_incontainer_perf.py --root /scratch/czhai/tb-runs-arm64 --iter 1 --kind tb
"""
import argparse
import csv
import json
import statistics as st
from pathlib import Path


def parse_perf(path: Path):
    """Return dict of perf event -> float (skips <not counted>/<not supported>)."""
    out = {}
    if not path.exists():
        return out
    for line in path.read_text(errors="ignore").splitlines():
        parts = [x.strip() for x in line.split(",")]
        if len(parts) < 3 or parts[0].startswith("<") or not parts[2]:
            continue
        try:
            out[parts[2]] = float(parts[0].replace(",", ""))
        except ValueError:
            pass
    return out


def parse_tokens(path: Path):
    tot = {"input_tokens": 0, "output_tokens": 0, "reasoning_output_tokens": 0}
    if not path.exists():
        return tot
    for line in path.read_text(errors="ignore").splitlines():
        try:
            e = json.loads(line)
        except Exception:
            continue
        if e.get("type") == "turn.completed":
            u = e.get("usage") or {}
            for k in tot:
                tot[k] += u.get(k, 0) or 0
    return tot


def repo_of(instance_id: str):
    # SWE-bench ids: "<org>__<repo>-<num>" -> repo group "<org>/<repo>"
    if "__" in instance_id:
        org, rest = instance_id.split("__", 1)
        repo = rest.rsplit("-", 1)[0]
        return f"{org}/{repo}"
    return instance_id  # tb tasks: group is just the task name


def div(a, b):
    return a / b if b else 0.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True)
    ap.add_argument("--iter", type=int, default=1)
    ap.add_argument("--kind", choices=["swe", "tb"], default="swe")
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    root = Path(args.root)
    id_field = "instance_id" if args.kind == "swe" else "task"
    rows = []
    for meta_path in sorted(root.glob(f"*/iter_{args.iter}/metadata.json")):
        d = json.loads(meta_path.read_text())
        rd = meta_path.parent
        iid = d.get(id_field) or rd.parent.name
        perf = parse_perf(rd / "perf_stat.csv")
        tok = parse_tokens(rd / "stdout.jsonl")
        wall_ms = d.get("wall_ms") or 0
        task_ms = perf.get("task-clock", 0.0)
        cyc = perf.get("cpu_cycles", 0.0)
        inst = perf.get("inst_retired", 0.0)
        l1 = perf.get("l1d_cache", 0.0)
        l1r = perf.get("l1d_cache_refill", 0.0)
        l2 = perf.get("l2d_cache", 0.0)
        l2r = perf.get("l2d_cache_refill", 0.0)
        row = {
            "repo": repo_of(iid),
            "instance": iid,
            "wall_s": round(wall_ms / 1000, 1),
            "task_clock_s": round(task_ms / 1000, 2),
            "cpu_util_pct": round(div(task_ms, wall_ms) * 100, 2),
            "ipc": round(div(inst, cyc), 3),
            "l1d_refill_rate": round(div(l1r, l1), 4),
            "l2d_refill_rate": round(div(l2r, l2), 4),
            "context_switches": int(perf.get("context-switches", 0)),
            "cpu_migrations": int(perf.get("cpu-migrations", 0)),
            "page_faults": int(perf.get("page-faults", 0)),
            "input_tokens": tok["input_tokens"],
            "output_tokens": tok["output_tokens"],
            "reasoning_tokens": tok["reasoning_output_tokens"],
            "rc": d.get("returncode"),
        }
        if args.kind == "swe":
            row["patch_bytes"] = d.get("patch_bytes")
            row["patch_empty"] = d.get("patch_empty")
        else:
            row["resolved"] = d.get("resolved")
            row["verifier_mode"] = d.get("verifier_mode")
        rows.append(row)

    if not rows:
        raise SystemExit(f"no iter_{args.iter} runs under {root}")

    out = Path(args.out) if args.out else root / f"perf_summary_iter{args.iter}.csv"
    with out.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)

    # repo-grouped summary
    groups = {}
    for r in rows:
        groups.setdefault(r["repo"], []).append(r)

    def agg(vals):
        vals = [v for v in vals if v is not None]
        return (round(st.mean(vals), 2), round(st.median(vals), 2)) if vals else (0, 0)

    print(f"\nper-instance CSV -> {out}\n")
    hdr = f"{'repo':22s} {'n':>3} {'wall_s(mean/med)':>18} {'taskclk_s(mean/med)':>20} {'util%(mean)':>11} {'ipc(mean)':>10}"
    print(hdr)
    print("-" * len(hdr))
    summary_rows = []
    for repo in sorted(groups):
        g = groups[repo]
        wm, wmd = agg([r["wall_s"] for r in g])
        tm, tmd = agg([r["task_clock_s"] for r in g])
        um, _ = agg([r["cpu_util_pct"] for r in g])
        im, _ = agg([r["ipc"] for r in g])
        print(f"{repo:22s} {len(g):>3} {f'{wm}/{wmd}':>18} {f'{tm}/{tmd}':>20} {um:>11} {im:>10}")
        summary_rows.append(
            {"repo": repo, "n": len(g), "wall_s_mean": wm, "wall_s_median": wmd,
             "task_clock_s_mean": tm, "task_clock_s_median": tmd,
             "cpu_util_pct_mean": um, "ipc_mean": im}
        )

    sout = root / f"perf_summary_by_repo_iter{args.iter}.csv"
    with sout.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(summary_rows[0].keys()))
        w.writeheader()
        w.writerows(summary_rows)
    print(f"\nrepo summary -> {sout}")


if __name__ == "__main__":
    main()
