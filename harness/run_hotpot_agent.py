#!/usr/bin/env python3
"""
run_hotpot_agent.py — run ANY agent in agents.yaml over the HotpotQA distractor
set and write predictions.json in the exact format the official scorer
(hotpot_evaluate_v1.py) expects.

Agent-open, exactly like run_swebench_agent.py: pick an agent by name (--agent),
it's loaded from agents.yaml, and the harness only hands it a prompt and reads
back its answer. Per-question telemetry (wall time, returncode, and — for
claude_json/codex_session agents — tokens/cost/latency or the rollout-file path)
goes to a SEPARATE metrics file so predictions.json stays exactly what the scorer
reads.

    python run_hotpot_agent.py --agent claude-closedbook \
        --input hotpot_dev_distractor_v1.json \
        --output predictions.json --metrics metrics.json --limit 100

Then score:
    python hotpot_evaluate_v1.py predictions.json hotpot_dev_distractor_v1.json

------------------------------------------------------------------------------
CONTEXT-ONLY ANSWERING IS NOW DATA, NOT CODE
------------------------------------------------------------------------------
HotpotQA is closed-book: the agent must answer from the prompt context ONLY, not
the web or local files. The old version hard-coded claude-specific isolation
flags here. That logic is gone: tool posture is part of "how to invoke it" and
lives in the agent's agents.yaml row. Define a closed-book claude variant once:

    claude-closedbook:
      type: shell
      command: ["claude", "-p", "--output-format", "json",
                "--allowedTools", "",
                "--disallowedTools",
                "WebSearch,WebFetch,Bash,Read,Edit,Write,Glob,Grep,NotebookEdit,Task",
                "--strict-mcp-config"]
      prompt_via: stdin
      model_flag: "--model"
      required_env: []
      telemetry: claude_json

The prompt also instructs context-only answering, which is the only lever for
agents that don't expose tool gating (codex, local scripts) — for those,
closed-book is enforced by the empty scratch cwd plus the prompt, not by flags.
"""

import argparse
import json
import os
import re
import sys
import tempfile
import time

# Shared, agent-agnostic machinery (see run_freshqa_agent.py for the rationale).
import agent_core
from agent_core import AGENTS_FILE, load_agent, load_agents_file

try:
    from tqdm import tqdm
except ImportError:  # tqdm optional
    def tqdm(x, **k):
        return x

SENTINEL = "FINAL ANSWER:"
SP_SENTINEL = "SUPPORTING FACTS:"


def build_prompt(item):
    """Self-contained prompt from a HotpotQA distractor item. Sentences carry
    their 0-based index so the agent can cite [paragraph_title, sentence_index]."""
    blocks = []
    for title, sents in item["context"]:
        lines = [f"## {title}"]
        for i, s in enumerate(sents):
            lines.append(f"[{i}] {s.strip()}")
        blocks.append("\n".join(lines))
    ctx = "\n\n".join(blocks)

    return (
        "Answer the multi-hop question using ONLY the context below. Reason across "
        "paragraphs as needed. Do not use tools, search the web, or read local files.\n\n"
        "End your reply with EXACTLY these two lines:\n"
        f"{SENTINEL} <shortest exact answer>\n"
        f'{SP_SENTINEL} <JSON list of [paragraph_title, sentence_index] pairs>\n\n'
        "Rules:\n"
        "- The answer must be an entity, a short phrase, or 'yes'/'no' — nothing else on that line.\n"
        "- For supporting facts, list every sentence needed to justify the answer.\n"
        "- Use paragraph titles EXACTLY as written (the text after '## ').\n"
        "- sentence_index is the 0-based number shown in [brackets] before each sentence.\n"
        f'- Example: {SP_SENTINEL} [["Scott Derrickson", 0], ["Ed Wood", 2]]\n\n'
        f"=== CONTEXT ===\n{ctx}\n\n"
        f"=== QUESTION ===\n{item['question']}\n"
    )


def extract_answer(raw):
    """Pull the answer out of (possibly noisy) agent output."""
    if not raw:
        return ""
    matches = list(re.finditer(re.escape(SENTINEL), raw, flags=re.I))
    if matches:
        tail = raw[matches[-1].end():]
        return tail.splitlines()[0].strip() if tail.strip() else ""
    lines = [ln.strip() for ln in raw.splitlines() if ln.strip()]
    return lines[-1] if lines else raw.strip()


def extract_supporting_facts(raw, item):
    """Parse [title, sentence_index] pairs after the SP sentinel and validate
    against the actual context. Invalid pairs are dropped."""
    if not raw:
        return []
    title_lens = {title: len(sents) for title, sents in item["context"]}
    matches = list(re.finditer(re.escape(SP_SENTINEL), raw, flags=re.I))
    if not matches:
        return []
    tail = raw[matches[-1].end():].strip()
    if not tail:
        return []
    m = re.search(r"\[.*\]", tail, flags=re.DOTALL)
    if not m:
        return []
    try:
        parsed = json.loads(m.group(0))
    except json.JSONDecodeError:
        return []
    if not isinstance(parsed, list):
        return []

    facts, seen = [], set()
    for pair in parsed:
        if not (isinstance(pair, (list, tuple)) and len(pair) == 2):
            continue
        title, idx = pair[0], pair[1]
        if not (isinstance(title, str) and isinstance(idx, int)):
            continue
        if title in title_lens and 0 <= idx < title_lens[title]:
            key = (title, idx)
            if key not in seen:
                seen.add(key)
                facts.append([title, idx])
    return facts


def flatten_telemetry(meta):
    """Lift the flat telemetry fields out of meta (token buckets are nested
    under meta['usage'])."""
    usage = meta.get("usage") or {}
    flat = {
        "wall_time_s": meta.get("wall_time_s"),
        "returncode": meta.get("returncode"),
        "total_cost_usd": meta.get("total_cost_usd"),
        "input_tokens": usage.get("input_tokens"),
        "output_tokens": usage.get("output_tokens"),
        "cache_read_input_tokens": usage.get("cache_read_input_tokens"),
        "cache_creation_input_tokens": usage.get("cache_creation_input_tokens"),
        "num_turns": meta.get("num_turns"),
        "duration_ms": meta.get("duration_ms"),
        "duration_api_ms": meta.get("duration_api_ms"),
        "ttft_ms": meta.get("ttft_ms"),
        "session_id": meta.get("session_id"),
        "codex_session_file": meta.get("codex_session_file"),
    }
    for k in ("timeout", "stderr", "error"):
        if meta.get(k) is not None:
            flat[k] = meta[k]
    return flat


def summarize(metrics):
    vals = list(metrics.values())
    n = len(vals)
    if not n:
        return

    def s(key):
        return sum(v[key] for v in vals if isinstance(v.get(key), (int, float)))

    errors = sum(1 for v in vals if v.get("returncode") not in (0, None)
                 or v.get("timeout") or "error" in v)
    print("\n--- run summary ---")
    print(f"questions:        {n}  ({errors} errored)")
    print(f"total cost (usd): {s('total_cost_usd'):.4f}   (notional if on a subscription)")
    print(f"input tokens:     {s('input_tokens'):,}")
    print(f"output tokens:    {s('output_tokens'):,}")
    print(f"cache read:       {s('cache_read_input_tokens'):,}   "
          f"cache create: {s('cache_creation_input_tokens'):,}")
    wall = s("wall_time_s")
    print(f"wall time (s):    {wall:.1f}   (mean {wall / n:.1f}/q)")


def main():
    ap = argparse.ArgumentParser(description="Agent-open HotpotQA harness (agents.yaml-driven).")
    ap.add_argument("--agent", default="claude",
                    help="Agent name from the agents file (default: claude). For HotpotQA "
                         "use a closed-book agent.")
    ap.add_argument("--agents-file", default=str(AGENTS_FILE),
                    help=f"Path to the agent registry (default: {AGENTS_FILE}).")
    ap.add_argument("--input", help="hotpot_dev_distractor_v1.json")
    ap.add_argument("--output", default="predictions.json")
    ap.add_argument("--metrics", default=None,
                    help="per-question telemetry file (default: <output>.metrics.json)")
    ap.add_argument("--limit", type=int, default=None, help="cap number of questions")
    ap.add_argument("--model", default=None, help="optional model override (via the agent's model_flag)")
    ap.add_argument("--timeout", type=int, default=None,
                    help="per-question timeout (s); applies to shell agents. "
                         f"Default: harness AGENT_TIMEOUT_S ({agent_core.AGENT_TIMEOUT_S}).")
    ap.add_argument("--resume", action="store_true", help="skip ids already present in --output")
    ap.add_argument("--list-agents", action="store_true", help="print known agents and exit")
    args = ap.parse_args()

    agents_cfg = load_agents_file(args.agents_file)
    if args.list_agents:
        for name, cfg in agents_cfg.items():
            print(f"  {name:14} ({cfg.get('type', 'shell')})")
        return

    if not args.input:
        ap.error("--input is required (unless using --list-agents)")

    if args.timeout:
        agent_core.AGENT_TIMEOUT_S = args.timeout

    agent = load_agent(args.agent, agents_cfg)
    agent.check()

    metrics_path = args.metrics or (args.output + ".metrics.json")

    with open(args.input) as f:
        data = json.load(f)
    if args.limit is not None:
        data = data[: args.limit]

    answers, sp, metrics = {}, {}, {}
    if args.resume and os.path.exists(args.output):
        with open(args.output) as f:
            prev = json.load(f)
        answers, sp = prev.get("answer", {}), prev.get("sp", {})
        if os.path.exists(metrics_path):
            with open(metrics_path) as f:
                metrics = json.load(f)
        print(f"Resuming: {len(answers)} predictions already on disk.")

    scratch = tempfile.mkdtemp(prefix="hotpot_")
    print(f"Agent: {args.agent} | questions: {len(data)} | cwd: {scratch}")

    try:
        for item in tqdm(data, desc="hotpot"):
            qid = item["_id"]
            if args.resume and qid in answers:
                continue

            t0 = time.time()
            try:
                raw, meta = agent.run(build_prompt(item), cwd=scratch, model=args.model)
                pred = extract_answer(raw or "")
                facts = extract_supporting_facts(raw or "", item)
            except Exception as e:
                print(f"\n[{qid}] ERROR: {e}", file=sys.stderr)
                meta = {"error": str(e)[:200], "wall_time_s": round(time.time() - t0, 2)}
                pred, facts = "", []

            answers[qid] = pred
            sp[qid] = facts
            metrics[qid] = {"agent": args.agent, **flatten_telemetry(meta)}

            # checkpoint after every item so a crash never loses progress
            with open(args.output, "w") as f:
                json.dump({"answer": answers, "sp": sp}, f)
            with open(metrics_path, "w") as f:
                json.dump(metrics, f, indent=2)
    finally:
        import shutil
        shutil.rmtree(scratch, ignore_errors=True)

    print(f"\nWrote {len(answers)} predictions to {args.output}")
    print(f"Wrote per-question telemetry to {metrics_path}")
    summarize(metrics)
    print(f"\nScore with:\n  python hotpot_evaluate_v1.py {args.output} {args.input}")


if __name__ == "__main__":
    main()