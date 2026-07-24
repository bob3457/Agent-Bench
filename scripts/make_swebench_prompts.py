#!/usr/bin/env python3
"""Write per-instance prompt files from SWE-bench_Verified problem statements.

Mirrors the prompt shape used in Tejas's SWE-bench materializer (instance id,
repo, base commit, problem statement, minimal-change instructions) but omits
FAIL_TO_PASS/PASS_TO_PASS test names: this run feeds external grading, and
withholding test IDs matches the standard SWE-bench agent setting.

Usage:
  python3 scripts/make_swebench_prompts.py --list configs/instances_arm_pulled.txt \
      --out /scratch/czhai/agent-runs-arm64/prompts
"""
import argparse
from pathlib import Path

TEMPLATE = """You are working on a SWE-bench instance inside its task container.
The repository is checked out at /testbed with its environment installed
(conda env: testbed).

Instance id: {instance_id}
Repository: {repo}
Base commit: {base_commit}

Problem statement:
{problem_statement}

Instructions:
1. Inspect the repository under /testbed.
2. Make the minimal code change needed to fix the issue.
3. You may run the repo's tests to check your change
   (source /opt/miniconda3/bin/activate testbed || source /opt/conda/bin/activate testbed).
4. Do not modify tests. Do not make unrelated changes. Do not commit.
5. When done, summarize the files changed and how you validated the fix.
"""


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--list", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    from datasets import load_dataset

    ids = [l.strip() for l in open(args.list) if l.strip() and not l.startswith("#")]
    ds = load_dataset("princeton-nlp/SWE-bench_Verified", split="test")
    by_id = {r["instance_id"]: r for r in ds}

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    written, missing = 0, []
    for iid in ids:
        row = by_id.get(iid)
        if row is None:
            missing.append(iid)
            continue
        (out / f"{iid}.txt").write_text(
            TEMPLATE.format(
                instance_id=iid,
                repo=row["repo"],
                base_commit=row["base_commit"],
                problem_statement=row["problem_statement"] or "",
            )
        )
        written += 1
    print(f"Wrote {written} prompts to {out}")
    if missing:
        print(f"WARNING: not in Verified: {missing}")


if __name__ == "__main__":
    main()
