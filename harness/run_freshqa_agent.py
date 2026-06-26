#!/usr/bin/env python3
"""
run_freshqa_agent.py — elicit answers from ANY agent in agents.yaml and record
them to JSONL.

Agent-open, exactly like run_swebench_agent.py: the harness knows nothing about
specific agents. You pick an agent by name (--agent), it's loaded from
agents.yaml, and the harness only ever hands it a question and reads back its
answer + telemetry. Adding an agent is a YAML edit, not a code change.

    # open-book (web tools allowed) — see the agents.yaml row note below
    python run_freshqa_agent.py --agent claude-search \
        --input freshqa.csv --output responses.jsonl --limit 50

    python run_freshqa_agent.py --agent codex \
        --input freshqa.csv --output responses.jsonl

Then grade with: python eval_freshqa.py --responses responses.jsonl --mode both

------------------------------------------------------------------------------
TOOL POSTURE IS NOW DATA, NOT CODE
------------------------------------------------------------------------------
FreshQA wants the agent ONLINE (fresh facts), so web tools must be enabled. The
old version hard-coded claude-specific permission flags here. That logic is gone:
which tools an agent may use is part of "how to invoke it", which lives in its
agents.yaml row. Define an open-book claude variant once and reuse it:

    claude-search:
      type: shell
      command: ["claude", "-p", "--output-format", "json",
                "--allowedTools", "WebSearch", "WebFetch"]
      prompt_via: stdin
      model_flag: "--model"
      required_env: []
      telemetry: claude_json

The harness records the effective command and (for claude_json telemetry)
surfaces how many web tool calls actually executed, so you can confirm tools are
live. For a non-claude agent that has no notion of tool gating, "online" is
whatever that agent does by default.

Each output line is one JSON object with the eval-contract fields
(question, category, reference_answers, response) plus flattened telemetry
(input/output/cache tokens, cost, durations, ttft, web tool counts) when the
agent emits Claude Code JSON.
"""

import argparse
import csv
import datetime
import json
import shutil
import sys
import tempfile
import time

# Shared, agent-agnostic machinery — the SINGLE source of truth for how agents
# are defined, launched, and read. Importing it here is the whole point: the QA
# harnesses and the SWE-bench harness drive identical agent objects.
import agent_core
from agent_core import AGENTS_FILE, load_agent, load_agents_file

try:
    from tqdm import tqdm
except ImportError:  # tqdm optional
    def tqdm(x, **k):
        return x


def find_col(fieldnames, *needles):
    for f in fieldnames:
        if any(n in f.lower() for n in needles):
            return f
    return None


def load_rows(path):
    with open(path, newline="", encoding="utf-8") as fh:
        reader = csv.DictReader(fh)
        fields = reader.fieldnames or []
        q_col = find_col(fields, "question")
        cat_col = find_col(fields, "fact_type", "category", "type", "split")
        ans_cols = [f for f in fields if "answer" in f.lower()]
        if not q_col or not ans_cols:
            sys.exit(f"Could not find question/answer columns. Headers were: {fields}")
        rows = []
        for r in reader:
            q = (r.get(q_col) or "").strip()
            if not q:
                continue
            answers = [(r.get(c) or "").strip() for c in ans_cols if (r.get(c) or "").strip()]
            rows.append({
                "question": q,
                "category": (r.get(cat_col) or "uncategorized").strip() if cat_col else "uncategorized",
                "reference_answers": answers,
            })
        return rows


def flatten_telemetry(meta):
    """Pull the flat per-question telemetry fields out of the meta dict that the
    shared telemetry parsers populate. Token buckets live nested under
    meta['usage']; web tool activity lives under usage['server_tool_use']."""
    usage = meta.get("usage") or {}
    stu = usage.get("server_tool_use") or {}
    return {
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
        "web_search_requests": stu.get("web_search_requests"),
        "web_fetch_requests": stu.get("web_fetch_requests"),
        "codex_session_file": meta.get("codex_session_file"),
    }


def already_done(output_path):
    done = set()
    try:
        with open(output_path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line:
                    done.add(json.loads(line)["question"])
    except FileNotFoundError:
        pass
    return done


def summarize(output_path):
    recs = []
    try:
        with open(output_path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line:
                    recs.append(json.loads(line))
    except FileNotFoundError:
        return
    n = len(recs)
    if not n:
        return

    def s(key):
        return sum(r[key] for r in recs if isinstance(r.get(key), (int, float)))

    errors = sum(1 for r in recs if not r.get("ok"))
    print("\n--- run summary ---")
    print(f"questions:        {n}  ({errors} errored)")
    print(f"total cost (usd): {s('total_cost_usd'):.4f}   (notional if on a subscription)")
    print(f"input tokens:     {s('input_tokens'):,}")
    print(f"output tokens:    {s('output_tokens'):,}")
    print(f"cache read:       {s('cache_read_input_tokens'):,}   "
          f"cache create: {s('cache_creation_input_tokens'):,}")
    lat = s("latency_s")
    print(f"latency (s):      {lat:.1f}   (mean {lat / n:.1f}/q)")

    # Tool-activity rollup — the at-a-glance check that web tools actually ran.
    # Derived from claude_json telemetry; for non-claude agents these are absent.
    web = s("web_search_requests") + s("web_fetch_requests")
    used = sum(1 for r in recs
               if (r.get("web_search_requests") or 0) + (r.get("web_fetch_requests") or 0) > 0)
    if web:
        print(f"web tool calls:   {web} executed across {used}/{n} questions")
        print("  OK: web tools are live (executed > 0).")
    elif any("web_search_requests" in r for r in recs):
        print("web tool calls:   0 executed")
        print("  WARNING: this looks closed-book. For FreshQA, use an agent whose")
        print("           agents.yaml row enables web tools (e.g. claude-search).")


def main():
    ap = argparse.ArgumentParser(description="Agent-open FreshQA harness (agents.yaml-driven).")
    ap.add_argument("--agent", default="claude",
                    help="Agent name from the agents file (default: claude). For FreshQA "
                         "use an online/open-book agent.")
    ap.add_argument("--agents-file", default=str(AGENTS_FILE),
                    help=f"Path to the agent registry (default: {AGENTS_FILE}).")
    ap.add_argument("--input", help="FreshQA CSV exported from the Google Sheet")
    ap.add_argument("--output", help="responses JSONL to write")
    ap.add_argument("--limit", type=int, default=50)
    ap.add_argument("--model", default=None, help="optional model override (via the agent's model_flag)")
    ap.add_argument("--timeout", type=int, default=None,
                    help="per-question timeout (s); applies to shell agents. "
                         f"Default: harness AGENT_TIMEOUT_S ({agent_core.AGENT_TIMEOUT_S}).")
    ap.add_argument("--resume", action="store_true", help="skip questions already in --output")
    ap.add_argument("--list-agents", action="store_true", help="print known agents and exit")
    args = ap.parse_args()

    agents_cfg = load_agents_file(args.agents_file)
    if args.list_agents:
        for name, cfg in agents_cfg.items():
            print(f"  {name:14} ({cfg.get('type', 'shell')})")
        return

    if not args.input or not args.output:
        ap.error("--input and --output are required (unless using --list-agents)")

    if args.timeout:
        agent_core.AGENT_TIMEOUT_S = args.timeout  # shell agents read this at call time

    agent = load_agent(args.agent, agents_cfg)
    agent.check()  # preflight: binary on PATH + required_env present

    model_name = args.model or args.agent
    rows = load_rows(args.input)[: args.limit]
    done = already_done(args.output) if args.resume else set()
    mode = "a" if args.resume else "w"

    # Scratch working dir: QA agents don't edit a repo, but every agent still
    # runs in *some* cwd. An empty temp dir means a closed-book agent has nothing
    # local to read, and no agent can dirty your tree.
    scratch = tempfile.mkdtemp(prefix="freshqa_")
    print(f"Agent: {args.agent} | questions: {min(len(rows), args.limit)} | cwd: {scratch}")

    try:
        with open(args.output, mode, encoding="utf-8") as out:
            for idx, row in enumerate(tqdm(rows, desc="querying agent")):
                if row["question"] in done:
                    continue
                t0 = time.time()
                try:
                    raw, meta = agent.run(row["question"], cwd=scratch, model=args.model)
                    resp = (raw or "").strip()
                    ok = (not meta.get("timeout")
                          and meta.get("returncode") in (0, None)
                          and bool(resp))
                    err = meta.get("stderr") if not ok else None
                except Exception as e:
                    resp, ok, err, meta = "", False, str(e)[:500], {}

                rec = {
                    "idx": idx,
                    "question": row["question"],
                    "category": row["category"],
                    "reference_answers": row["reference_answers"],
                    "response": resp,
                    "ok": ok,
                    "error": err,
                    "latency_s": meta.get("wall_time_s", round(time.time() - t0, 2)),
                    "agent": args.agent,
                    "model": model_name,
                    "ts": datetime.datetime.now().isoformat(timespec="seconds"),
                    **flatten_telemetry(meta),
                }
                out.write(json.dumps(rec, ensure_ascii=False) + "\n")
                out.flush()
    finally:
        shutil.rmtree(scratch, ignore_errors=True)

    print(f"Wrote responses to {args.output}")
    summarize(args.output)


if __name__ == "__main__":
    main()