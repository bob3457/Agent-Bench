#!/usr/bin/env python3
"""
eval_freshqa.py — grade responses.jsonl with the FreshEval judge and report.

    python eval_freshqa.py \
        --responses responses.jsonl \
        --mode both \
        --judge-cmd "claude -p" \
        --graded-out graded.jsonl

Modes:
  relaxed  — primary answer correct; hallucinations/outdated info tolerated
  strict   — additionally NO hallucinations, outdated info, or ill-formed answers
  both     — run both and also compute a hallucination rate

Hallucination rate (only with --mode both): the fraction of responses whose
PRIMARY answer is correct (passes relaxed) but which FAIL strict — i.e. the
right answer wrapped in hallucinated / outdated / ill-formed content. This is
exactly the relaxed-minus-strict gap the FreshLLMs paper attributes to
hallucination and staleness.

Both rubric strings below are copied verbatim from the repo's
fresheval_relaxed.ipynb / fresheval_strict.ipynb.
"""

import argparse
import datetime
import json
import shlex
import subprocess
import sys

try:
    from tqdm import tqdm
except ImportError:
    def tqdm(x, **k):
        return x

RELAXED_PREFIX = (
    "Please evaluate the response to a question under relaxed evaluation, where"
    " hallucinations, outdated information, and ill-formed answers are allowed,"
    " as long as the primary answer is accurate. Please credit the response"
    " only if it provides a confident and definitive answer, or the correct"
    " answer can be obviously inferred from the response. The primary or final"
    " answer when standing alone must be accurate. Any additional information"
    " that is provided must not contradict the primary answer or reshape one's"
    " perception of it. For false-premise questions, the response must point"
    " out the presence of a false premise to receive credit. For answers that"
    " involve names of entities (e.g., people), complete names or commonly"
    " recognized names are expected. Regarding numerical answers, approximate"
    " numbers are generally not accepted unless explicitly included in the"
    " ground-truth answers. We accept ill-formed responses (including those in"
    " a non-English language), as well as hallucinated or outdated information"
    " that does not significantly impact the primary answer."
)

STRICT_PREFIX = (
    "Please evaluate the response to a question under strict evaluation, where"
    " no hallucinations, outdated information, or ill-formed answers are"
    " allowed. Please credit the response only if it provides a confident and"
    " definitive answer, or the correct answer can be obviously inferred from"
    " the response. The primary or final answer when standing alone must be"
    " accurate. Any additional information that is provided must not contradict"
    " the primary answer or reshape one's perception of it. For false-premise"
    " questions, the response must point out the presence of a false premise to"
    " receive credit. For answers that involve names of entities (e.g.,"
    " people), complete names or commonly recognized names are expected."
    " Regarding numerical answers, approximate numbers are generally not"
    " accepted unless explicitly included in the ground-truth answers. A"
    " response that contains any hallucination, no matter how minor, will not"
    " receive credit. Furthermore, when the response indicates that the"
    " information might be outdated, we accept it only if it is evident that"
    " the knowledge has not changed (e.g., through common sense or well-known"
    " facts)."
)

JUDGE_TEMPLATE = """{prefix}

Today's date is {today}.

question: {question}
correct answer(s): {answers}
response: {response}

First give a one-sentence explanation, then on a final separate line output
exactly TRUE (correct) or FALSE (incorrect).
"""


def run_judge(judge_cmd, prompt, timeout=300):
    parts = shlex.split(judge_cmd)
    if any("{}" in p for p in parts):
        argv, stdin = [p.replace("{}", prompt) for p in parts], None
    else:
        argv, stdin = parts + [prompt], None
    proc = subprocess.run(argv, input=stdin, capture_output=True, text=True, timeout=timeout)
    if proc.returncode != 0:
        raise RuntimeError((proc.stderr or proc.stdout).strip()[:500])
    return proc.stdout.strip()


def parse_verdict(text):
    if not text.strip():
        return None
    last_true = text.upper().rfind("TRUE")
    last_false = text.upper().rfind("FALSE")
    if last_true == last_false == -1:
        return None
    return last_true > last_false


def judge_one(judge_cmd, prefix, rec, today):
    prompt = JUDGE_TEMPLATE.format(
        prefix=prefix,
        today=today,
        question=rec["question"],
        answers=" | ".join(rec.get("reference_answers") or []) or "(none provided)",
        response=rec.get("response") or "(empty)",
    )
    return parse_verdict(run_judge(judge_cmd, prompt))


def report(graded, modes):
    cats = {}
    for g in graded:
        c = g["category"]
        cats.setdefault(c, [])
        cats[c].append(g)
    n = len(graded)
    print("=" * 72)
    header = f"{'category':<22}{'n':>5}"
    if "relaxed" in modes:
        header += f"{'relaxed':>12}"
    if "strict" in modes:
        header += f"{'strict':>12}"
    if {"relaxed", "strict"} <= set(modes):
        header += f"{'halluc.':>12}"
    print(header)
    print("-" * 72)

    def line(name, items):
        m = len(items)
        out = f"{name:<22}{m:>5}"
        rc = sum(1 for x in items if x.get("relaxed"))
        sc = sum(1 for x in items if x.get("strict"))
        if "relaxed" in modes:
            out += f"{rc/m:>11.1%}" if m else f"{'-':>12}"
        if "strict" in modes:
            out += f"{sc/m:>11.1%}" if m else f"{'-':>12}"
        if {"relaxed", "strict"} <= set(modes):
            hall = sum(1 for x in items if x.get("relaxed") and not x.get("strict"))
            out += f"{hall/m:>11.1%}" if m else f"{'-':>12}"
        print(out)

    for c in sorted(cats):
        line(c, cats[c])
    print("-" * 72)
    line("OVERALL", graded)
    if {"relaxed", "strict"} <= set(modes):
        rc = sum(1 for g in graded if g.get("relaxed"))
        hall = sum(1 for g in graded if g.get("relaxed") and not g.get("strict"))
        print(f"\nHallucination rate = {hall}/{n} = {hall/n:.1%} of all responses"
              + (f"  ({hall}/{rc} = {hall/rc:.1%} of relaxed-correct ones)" if rc else ""))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--responses", required=True)
    ap.add_argument("--mode", choices=["relaxed", "strict", "both"], default="both")
    ap.add_argument("--judge-cmd", default="claude -p",
                    help='judge invocation; question appended as final arg. '
                         'For the official judge use an OpenAI gpt-4 wrapper.')
    ap.add_argument("--graded-out", default=None, help="optional JSONL of per-item verdicts")
    args = ap.parse_args()

    modes = ["relaxed", "strict"] if args.mode == "both" else [args.mode]
    today = datetime.datetime.now().strftime("%B %d, %Y")

    records = []
    with open(args.responses, encoding="utf-8") as fh:
        for ln in fh:
            ln = ln.strip()
            if ln:
                records.append(json.loads(ln))
    if not records:
        sys.exit("No records in responses file.")

    graded = []
    for rec in tqdm(records, desc="grading"):
        g = {"question": rec["question"], "category": rec.get("category", "uncategorized")}
        for m in modes:
            prefix = RELAXED_PREFIX if m == "relaxed" else STRICT_PREFIX
            try:
                g[m] = judge_one(args.judge_cmd, prefix, rec, today)
            except Exception as e:
                g[m] = None
                g[f"{m}_error"] = str(e)
        graded.append(g)

    if args.graded_out:
        with open(args.graded_out, "w", encoding="utf-8") as out:
            for g in graded:
                out.write(json.dumps(g, ensure_ascii=False) + "\n")

    report(graded, modes)


if __name__ == "__main__":
    main()
