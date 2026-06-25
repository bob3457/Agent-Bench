#!/usr/bin/env python3
"""
run_hotpot_agent.py

Run ANY command-line agent (claude -p, codex exec, a local agent binary, ...)
over the HotpotQA distractor set and write predictions.json in the exact format
the official scorer (hotpot_evaluate_v1.py) expects.

Per-question telemetry (wall time, exit code, and — when the agent emits Claude
Code JSON — tokens / cost / latency) is written to a SEPARATE metrics file so
predictions.json stays exactly what the scorer reads.

The agent command is taken verbatim and the prompt is appended as the final
argument (or piped to stdin with --stdin). Examples:

    # text mode: you get wall_time + returncode per question
    export AGENT_CMD="claude -p"

    # JSON mode: you ALSO get tokens, cost, and latency per question
    export AGENT_CMD="claude -p --output-format json"

    export AGENT_CMD="codex exec --full-auto"
    export AGENT_CMD="/path/to/local_agent --temperature 0"

    python run_hotpot_agent.py --agent-cmd "$AGENT_CMD" \
        --input hotpot_dev_distractor_v1.json \
        --output predictions.json \
        --metrics metrics.json \
        --limit 100

Then score:
    python hotpot_evaluate_v1.py predictions.json hotpot_dev_distractor_v1.json

--- Tool isolation (context-only answering) ---
When the agent is `claude`, the harness appends flags that disable web search,
file/shell access, and MCP tools so the model answers from the prompt context
ONLY — never the web or local files. This is ON by default; pass --no-isolate to
run your command verbatim. The flags live in CLAUDE_ISOLATION_FLAGS below; if your
installed Claude Code uses different flag names, edit them there (run
`claude --help` to confirm). The resolved command is printed at startup so you can
see exactly what ran. Isolation is a no-op for non-claude agents and is skipped if
you've already set --allowedTools / --disallowedTools yourself.
"""

import argparse
import json
import os
import re
import shlex
import subprocess
import sys
import time

try:
    from tqdm import tqdm
except ImportError:  # tqdm is optional
    def tqdm(x, **k):
        return x

SENTINEL = "FINAL ANSWER:"
SP_SENTINEL = "SUPPORTING FACTS:"

# Flags appended to a `claude` agent command so it answers from the prompt ONLY:
# no web search, no file reads, no shell, no MCP tools. The empty allow-list means
# nothing may run; the explicit deny-list is belt-and-suspenders for the network/
# file/exec built-ins; --strict-mcp-config ignores any global or user MCP servers.
# Edit here if your Claude Code version uses different flag names.
CLAUDE_ISOLATION_FLAGS = [
    "--allowedTools", "",  # empty allow-list => no tool may run
    "--disallowedTools",
    "WebSearch,WebFetch,Bash,Read,Edit,Write,Glob,Grep,NotebookEdit,Task",
    "--strict-mcp-config",  # ignore global/user MCP servers
]

# Flag names that indicate the user already configured tool permissions, in which
# case we respect their choice and only ensure MCP servers stay disabled.
_USER_TOOL_FLAGS = (
    "--allowedTools", "--allowed-tools",
    "--disallowedTools", "--disallowed-tools",
)


def looks_like_claude(argv):
    """True if the command's executable looks like the Claude Code CLI."""
    if not argv:
        return False
    exe = os.path.basename(argv[0]).lower()
    return exe == "claude" or exe.startswith("claude")


def harden_agent_argv(argv, enabled):
    """Return (argv, appended_flags). For a `claude` command with isolation on,
    append CLAUDE_ISOLATION_FLAGS so the agent answers from context only. No-op for
    non-claude agents or when disabled, and idempotent w.r.t. flags already set."""
    if not enabled or not looks_like_claude(argv):
        return list(argv), []

    out = list(argv)
    appended = []

    user_set_tools = any(f in out for f in _USER_TOOL_FLAGS)
    if not user_set_tools:
        i = 0
        flags = CLAUDE_ISOLATION_FLAGS[:]
        while i < len(flags):
            # Drop the trailing --strict-mcp-config here; handled separately below.
            if flags[i] == "--strict-mcp-config":
                i += 1
                continue
            out.append(flags[i])
            appended.append(flags[i])
            # value-bearing flags consume the next token
            if i + 1 < len(flags) and not flags[i + 1].startswith("--"):
                out.append(flags[i + 1])
                appended[-1] = f"{flags[i]} {flags[i + 1]!r}"
                i += 2
            else:
                i += 1
    else:
        print("Note: --allowedTools/--disallowedTools already set in your command; "
              "leaving tool permissions as you specified.")

    if "--strict-mcp-config" not in out:
        out.append("--strict-mcp-config")
        appended.append("--strict-mcp-config")

    return out, appended


def build_prompt(item):
    """Build a self-contained prompt from a HotpotQA distractor item.

    Sentences are shown with their 0-based index so the agent can cite
    supporting facts as [paragraph_title, sentence_index] pairs.
    """
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
    """Pull the answer out of (possibly noisy) agent stdout."""
    if not raw:
        return ""
    # Prefer the text after the LAST sentinel line.
    matches = list(re.finditer(re.escape(SENTINEL), raw, flags=re.I))
    if matches:
        tail = raw[matches[-1].end():]
        return tail.splitlines()[0].strip() if tail.strip() else ""
    # Fallback: last non-empty line of output.
    lines = [ln.strip() for ln in raw.splitlines() if ln.strip()]
    return lines[-1] if lines else raw.strip()


def extract_supporting_facts(raw, item):
    """Parse [title, sentence_index] pairs after the SP sentinel and validate
    them against the actual context. Invalid pairs (unknown title or out-of-range
    index) are dropped so they never get written to predictions.json."""
    if not raw:
        return []

    # Map each real paragraph title to its sentence count for validation.
    title_lens = {title: len(sents) for title, sents in item["context"]}

    matches = list(re.finditer(re.escape(SP_SENTINEL), raw, flags=re.I))
    if not matches:
        return []
    tail = raw[matches[-1].end():].strip()
    if not tail:
        return []

    # Grab the first JSON-array-looking span (may span multiple lines if the
    # agent pretty-printed it). Greedy to the last ']'.
    m = re.search(r"\[.*\]", tail, flags=re.DOTALL)
    if not m:
        return []
    try:
        parsed = json.loads(m.group(0))
    except json.JSONDecodeError:
        return []
    if not isinstance(parsed, list):
        return []

    facts = []
    seen = set()
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


def parse_claude_metrics(stdout):
    """If stdout is a Claude Code `--output-format json` result, return
    (answer_text, metrics_dict). Otherwise return (None, {}) so the caller
    falls back to treating stdout as plain text (codex / local agents / text mode).
    """
    try:
        data = json.loads(stdout)
    except (json.JSONDecodeError, TypeError):
        return None, {}
    if not isinstance(data, dict) or "usage" not in data:
        return None, {}
    u = data.get("usage", {}) or {}
    m = {
        "is_error": data.get("is_error"),
        "stop_reason": data.get("stop_reason"),
        "num_turns": data.get("num_turns"),
        "duration_ms": data.get("duration_ms"),          # Claude Code's own wall time
        "duration_api_ms": data.get("duration_api_ms"),  # time inside API calls only
        "ttft_ms": data.get("ttft_ms"),                  # time to first token
        "total_cost_usd": data.get("total_cost_usd"),    # notional under subscription
        "session_id": data.get("session_id"),
        "input_tokens": u.get("input_tokens"),
        "output_tokens": u.get("output_tokens"),
        "cache_creation_input_tokens": u.get("cache_creation_input_tokens"),
        "cache_read_input_tokens": u.get("cache_read_input_tokens"),
    }
    return data.get("result", "") or "", m


def run_agent(base_argv, prompt, use_stdin, timeout):
    """Run the agent, returning (stdout, meta). meta always has wall_time_s
    and returncode; never raises on non-zero exit (caller inspects meta)."""
    t0 = time.time()
    if use_stdin:
        res = subprocess.run(
            base_argv, input=prompt, capture_output=True, text=True, timeout=timeout
        )
    else:
        res = subprocess.run(
            base_argv + [prompt], capture_output=True, text=True, timeout=timeout
        )
    meta = {"wall_time_s": round(time.time() - t0, 2), "returncode": res.returncode}
    if res.returncode != 0:
        meta["stderr"] = res.stderr.strip()[:300] or "agent exited non-zero"
    return res.stdout, meta


def summarize(metrics):
    """Print a quick run-level rollup of cost / tokens / time."""
    vals = list(metrics.values())
    n = len(vals)
    if not n:
        return

    def s(key):
        return sum(v[key] for v in vals if isinstance(v.get(key), (int, float)))

    cost = s("total_cost_usd")
    in_tok = s("input_tokens")
    out_tok = s("output_tokens")
    cache_r = s("cache_read_input_tokens")
    cache_c = s("cache_creation_input_tokens")
    wall = s("wall_time_s")
    errors = sum(1 for v in vals if v.get("returncode") not in (0, None)
                 or v.get("is_error") or "error" in v)

    print("\n--- run summary ---")
    print(f"questions:        {n}  ({errors} errored)")
    print(f"total cost (usd): {cost:.4f}   (notional if on a subscription)")
    print(f"input tokens:     {in_tok:,}")
    print(f"output tokens:    {out_tok:,}")
    print(f"cache read:       {cache_r:,}   cache create: {cache_c:,}")
    print(f"wall time (s):    {wall:.1f}   (mean {wall / n:.1f}/q)")


def main():
    ap = argparse.ArgumentParser(description="Run a CLI agent over HotpotQA.")
    ap.add_argument("--agent-cmd", required=True,
                    help='Agent command, e.g. "claude -p --output-format json"')
    ap.add_argument("--input", required=True, help="hotpot_dev_distractor_v1.json")
    ap.add_argument("--output", default="predictions.json")
    ap.add_argument("--metrics", default=None,
                    help="per-question telemetry file (default: <output>.metrics.json)")
    ap.add_argument("--limit", type=int, default=None, help="cap number of questions")
    ap.add_argument("--stdin", action="store_true",
                    help="pipe the prompt to the agent's stdin instead of argv")
    ap.add_argument("--timeout", type=int, default=300, help="per-question timeout (s)")
    ap.add_argument("--resume", action="store_true",
                    help="skip ids already present in --output")
    ap.add_argument("--isolate", action=argparse.BooleanOptionalAction, default=True,
                    help="for `claude` agents, append flags that disable web search, "
                         "file/shell access, and MCP tools so it answers from the "
                         "prompt context only (default: on; use --no-isolate to run "
                         "your command verbatim)")
    args = ap.parse_args()

    base_argv = shlex.split(args.agent_cmd)
    if not base_argv:
        sys.exit("ERROR: --agent-cmd is empty")

    base_argv, injected = harden_agent_argv(base_argv, args.isolate)
    print("Agent command:", " ".join(shlex.quote(a) for a in base_argv))
    if injected:
        print("Tool isolation ON — appended:", ", ".join(injected))
    elif args.isolate and not looks_like_claude(base_argv):
        print("Tool isolation requested but agent isn't `claude`; "
              "running command verbatim (control its tools yourself).")
    elif not args.isolate:
        print("Tool isolation OFF (--no-isolate); running command verbatim.")

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

    for item in tqdm(data, desc="hotpot"):
        qid = item["_id"]
        if args.resume and qid in answers:
            continue

        meta = {}
        try:
            raw, meta = run_agent(base_argv, build_prompt(item), args.stdin, args.timeout)
            # If the agent emitted Claude Code JSON, pull telemetry and extract
            # the answer from its `result` field; otherwise treat stdout as text.
            answer_text, cc_meta = parse_claude_metrics(raw)
            if answer_text is not None:
                meta.update(cc_meta)
                raw_for_extract = answer_text
            else:
                raw_for_extract = raw
            pred = extract_answer(raw_for_extract)
            facts = extract_supporting_facts(raw_for_extract, item)
        except subprocess.TimeoutExpired:
            print(f"\n[{qid}] TIMEOUT after {args.timeout}s", file=sys.stderr)
            meta = {"error": "timeout", "wall_time_s": float(args.timeout)}
            pred, facts = "", []
        except Exception as e:
            print(f"\n[{qid}] ERROR: {e}", file=sys.stderr)
            meta = {**meta, "error": str(e)[:200]}
            pred, facts = "", []

        answers[qid] = pred
        sp[qid] = facts
        metrics[qid] = meta

        # checkpoint after every item so a crash never loses progress
        with open(args.output, "w") as f:
            json.dump({"answer": answers, "sp": sp}, f)
        with open(metrics_path, "w") as f:
            json.dump(metrics, f, indent=2)

    print(f"\nWrote {len(answers)} predictions to {args.output}")
    print(f"Wrote per-question telemetry to {metrics_path}")
    summarize(metrics)
    print(f"\nScore with:\n  python hotpot_evaluate_v1.py {args.output} {args.input}")


if __name__ == "__main__":
    main()