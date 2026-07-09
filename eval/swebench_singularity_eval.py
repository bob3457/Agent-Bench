#!/usr/bin/env python3
"""
Run SWE-bench evaluation with Singularity / Apptainer instead of Docker.

It reuses the official `swebench` package (verified against v4.1.0) for:
  - image naming        -> TestSpec.instance_image_key
  - the eval script     -> TestSpec.eval_script
  - grading / scoring   -> swebench.harness.grading.get_eval_report

...and replaces ONLY the container runtime. On Hopper neither squashfuse
(mount SIFs), fuse2fs (ext3 --overlay), nor fuse-overlayfs / rootless kernel
overlayfs (dir overlays on Lustre) is available, so the strategy is:

  1. keep ONE compressed .sif per instance in --sif-dir (pulled on the login
     node; ~95 GB for 75 Lite instances),
  2. per RUN, extract the SIF to a throwaway --writable sandbox on disk
     (~2-4 min, ~3 GB transient), run the patch+tests writing directly into
     it, grade, then delete the sandbox.

Pristine state is guaranteed by re-extraction, not overlays. --fakeroot is
unnecessary (sandbox files are owned by the invoking user) and defaults OFF.

Usage:
  python run_swebench_singularity.py \
      --predictions preds.jsonl \
      --dataset SWE-bench/SWE-bench_Lite --split test \
      --instance-ids django__django-11099 sympy__sympy-20154 \
      --workdir ./sb_work --sif-dir ./sifs

predictions: a .jsonl, one object per line, each with
  {"instance_id": "...", "model_name_or_path": "...", "model_patch": "<diff>"}
"""
import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path

from swebench.harness.utils import load_swebench_dataset
from swebench.harness.test_spec.test_spec import make_test_spec
from swebench.harness.grading import get_eval_report
from swebench.harness.constants import (
    KEY_INSTANCE_ID,
    KEY_MODEL,
    KEY_PREDICTION,
    LOG_TEST_OUTPUT,
    LOG_REPORT,
)

# Mirrors GIT_APPLY_CMDS in swebench/harness/run_evaluation.py
GIT_APPLY_CMDS = [
    "git apply --verbose",
    "git apply --verbose --reject",
    "patch --batch --fuzz=5 -p1 -i",
]

DRIVER_TEMPLATE = """#!/bin/bash
set -uxo pipefail
cd /testbed
applied=0
for cmd in {apply_cmds}; do
    if eval "$cmd /host/patch.diff"; then applied=1; break; fi
done
if [ "$applied" -ne 1 ]; then
    echo ">>>>> Patch Apply Failed"
    exit 1
fi
/bin/bash /host/eval.sh
"""


def sh(cmd, **kw):
    print("+", " ".join(cmd), file=sys.stderr)
    return subprocess.run(cmd, **kw)


def ensure_sif(image_key, image_dir, apptainer):
    """Return the local .sif for docker://<image_key>, pulling if absent.

    NOTE: pulls only work where egress does (login node). Pre-warm the whole
    --sif-dir there before submitting SLURM jobs; on compute nodes a missing
    SIF will fail fast rather than crawl through the throttled proxy.
    """
    image_dir.mkdir(parents=True, exist_ok=True)
    name = image_key.split("/")[-1].replace(":", "_")
    target = image_dir / (name + ".sif")
    if target.exists():
        return target
    r = sh([apptainer, "pull", str(target), f"docker://{image_key}"])
    if r.returncode != 0:
        raise RuntimeError(f"image acquisition failed for {image_key}")
    return target


def run_instance(spec, pred, sif, work, apptainer, timeout, fakeroot):
    inst_dir = work / spec.instance_id
    host = inst_dir / "host"
    host.mkdir(parents=True, exist_ok=True)

    (host / "patch.diff").write_text(pred.get(KEY_PREDICTION) or "")
    (host / "eval.sh").write_text(spec.eval_script)
    driver = host / "driver.sh"
    driver.write_text(
        DRIVER_TEMPLATE.format(
            apply_cmds=" ".join(f'"{c}"' for c in GIT_APPLY_CMDS)
        )
    )

    # Fresh throwaway sandbox per run: extraction (not an overlay) provides
    # pristine state, and the run writes directly into it via --writable.
    run_sandbox = inst_dir / "run.sandbox"
    if run_sandbox.exists():
        shutil.rmtree(run_sandbox, ignore_errors=True)
    r = sh([apptainer, "build", "--sandbox", str(run_sandbox), str(sif)])
    if r.returncode != 0:
        raise RuntimeError(f"sandbox extraction failed for {spec.instance_id}")

    # --writable sandboxes cannot auto-create bind mount points (no overlay
    # to synthesize them in); guarantee /host exists inside the tree.
    (run_sandbox / "host").mkdir(exist_ok=True)

    cmd = [apptainer, "exec", "--cleanenv", "--no-home", "--pwd", "/testbed"]
    if fakeroot:
        cmd.append("--fakeroot")
    cmd += [
        "--writable",
        "--bind", f"{host}:/host",
        str(run_sandbox), "/bin/bash", "/host/driver.sh",
    ]

    log_path = inst_dir / LOG_TEST_OUTPUT
    try:
        with open(log_path, "w") as f:
            try:
                sh(cmd, stdout=f, stderr=subprocess.STDOUT, timeout=timeout)
            except subprocess.TimeoutExpired:
                f.write(f"\n\nTimeout error: {timeout} seconds exceeded.\n")
    finally:
        # Sandboxes are ~3 GB / ~58k files each; never leave them behind,
        # even when grading below raises.
        shutil.rmtree(run_sandbox, ignore_errors=True)

    report = get_eval_report(
        test_spec=spec,
        prediction=pred,
        test_log_path=str(log_path),
        include_tests_status=True,
    )
    (inst_dir / LOG_REPORT).write_text(json.dumps(report, indent=2))
    return report[spec.instance_id]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--predictions", required=True, help="predictions .jsonl")
    ap.add_argument("--dataset", default="SWE-bench/SWE-bench")
    ap.add_argument("--split", default="test")
    ap.add_argument("--instance-ids", nargs="*", default=None)
    ap.add_argument("--namespace", default="swebench",
                    help="Docker Hub namespace for prebuilt images")
    ap.add_argument("--image-tag", default="latest")
    ap.add_argument("--workdir", default="./sb_work")
    ap.add_argument("--sif-dir", default="./sifs",
                    help="where per-instance .sif files are stored")
    ap.add_argument("--timeout", type=int, default=1800, help="per-instance seconds")
    ap.add_argument("--apptainer", default="apptainer",
                    help="binary name: apptainer or singularity")
    ap.add_argument("--fakeroot", dest="fakeroot", action="store_true",
                    default=False,
                    help="force --fakeroot on (rarely needed: sandbox files "
                         "are owned by you; adds userns friction on Hopper)")
    args = ap.parse_args()

    preds = {}
    for line in Path(args.predictions).read_text().splitlines():
        if line.strip():
            p = json.loads(line)
            preds[p[KEY_INSTANCE_ID]] = p
    ids = args.instance_ids or list(preds)

    dataset = load_swebench_dataset(args.dataset, args.split, instance_ids=ids)
    work, image_dir = Path(args.workdir), Path(args.sif_dir)

    resolved = 0
    for inst in dataset:
        iid = inst[KEY_INSTANCE_ID]
        if iid not in preds:
            print(f"[skip] no prediction for {iid}", file=sys.stderr)
            continue
        spec = make_test_spec(inst, namespace=args.namespace,
                              instance_image_tag=args.image_tag)
        print(f"[{iid}] image={spec.instance_image_key} arch={spec.arch}",
              file=sys.stderr)
        try:
            sif = ensure_sif(spec.instance_image_key, image_dir, args.apptainer)
            r = run_instance(spec, preds[iid], sif, work, args.apptainer,
                             args.timeout, fakeroot=args.fakeroot)
            status = "RESOLVED" if r.get("resolved") else "unresolved"
            resolved += int(bool(r.get("resolved")))
            print(f"[{iid}] {status}", file=sys.stderr)
        except Exception as e:
            print(f"[{iid}] ERROR: {e}", file=sys.stderr)

    print(f"\nResolved {resolved}/{len(ids)}", file=sys.stderr)


if __name__ == "__main__":
    main()