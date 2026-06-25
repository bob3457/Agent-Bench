#!/usr/bin/env python3
"""
run_freshqa_agent.py — elicit answers from ANY agent and record them to JSONL.

The agent is whatever you put in --agent-cmd. The question is appended as the
final argument (default), substituted for a {} placeholder, or piped via stdin.

    export AGENT_CMD="claude -p --output-format json"  # JSON mode: + tokens/cost
    python run_freshqa_agent.py \
        --agent-cmd "$AGENT_CMD" \
        --input freshqa.csv \
        --output responses.jsonl \
        --limit 50
        # tools (WebSearch/WebFetch) are now allowed BY DEFAULT for claude

Each output line is one JSON object:
    {"idx","question","category","reference_answers","response","ok","latency_s","agent_cmd","ts", ...}
When the agent emits Claude Code JSON, each line ALSO carries:
    {"total_cost_usd","input_tokens","output_tokens","cache_read_input_tokens",
     "cache_creation_input_tokens","num_turns","duration_ms","duration_api_ms","ttft_ms","session_id",
     "web_search_requests","web_fetch_requests","permission_denials"}
    plus "claude_raw": the complete Claude JSON object, saved verbatim (null for non-Claude agents).

Then grade with: python eval_freshqa.py --responses responses.jsonl --mode both

------------------------------------------------------------------------------
WHY TOOLS WERE OFF BEFORE
------------------------------------------------------------------------------
Claude Code gates WebSearch/WebFetch behind permissions. In non-interactive
print mode (-p) there is no approval prompt, so a gated tool is DENIED by
default: the agent tries to search, gets refused, and answers from memory.
The earlier run recorded `claude -p --output-format json` with no permission
flags, so all 27 web calls were denied and 0 executed.

This version pre-authorizes the web tools (least-privilege: WebSearch + WebFetch
only) so they actually run, records the EFFECTIVE command, and reports how many
tool calls executed vs. were denied so you can confirm tools are live.
"""

import argparse
import csv
import datetime
import json
import os
import re
import shlex
import subprocess
import sys
import time

try:
    from tqdm import tqdm
except ImportError:  # tqdm optional
    def tqdm(x, **k):
        return x

# ---------------------------------------------------------------------------
# Permission configuration.
# NOTE: flag spelling has shifted across Claude Code versions. Verify with
# `claude --help`. If yours differs, change the three constants below — they
# are the only place the flag names appear.
# ---------------------------------------------------------------------------
ALLOWED_TOOLS_FLAG = "--allowedTools"             # some versions: --allowed-tools
PERMISSION_MODE_FLAG = "--permission-mode"        # e.g. default | acceptEdits | bypassPermissions
SKIP_PERMISSIONS_FLAG = "--dangerously-skip-permissions"
DEFAULT_TOOLS = "WebSearch WebFetch"              # least-privilege set for FreshQA


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


def parse_claude_metrics(stdout):
    """If stdout is a Claude Code `--output-format json` result, return
    (answer_text, metrics_dict, full_data). Otherwise return (None, {}, None)
    so the caller treats stdout as plain text (codex / local agents / text mode).
    `full_data` is the complete parsed JSON object, for saving verbatim.
    """
    try:
        data = json.loads(stdout)
    except (json.JSONDecodeError, TypeError):
        return None, {}, None
    if not isinstance(data, dict) or "usage" not in data:
        return None, {}, None
    u = data.get("usage", {}) or {}
    stu = u.get("server_tool_use", {}) or {}        # NEW: did web tools actually run?
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
        # NEW: surface tool activity at the top level so you don't have to dig
        # into claude_raw to see whether tools fired or were blocked.
        "web_search_requests": stu.get("web_search_requests"),
        "web_fetch_requests": stu.get("web_fetch_requests"),
        "permission_denials": len(data.get("permission_denials") or []),
    }
    return data.get("result", "") or "", m, data


# ---------------------------------------------------------------------------
# NEW: permission-flag helpers
# ---------------------------------------------------------------------------
def is_claude_cmd(parts):
    return bool(parts) and "claude" in os.path.basename(parts[0]).lower()


def already_has_permission_flag(parts):
    flags = {ALLOWED_TOOLS_FLAG, "--allowed-tools", PERMISSION_MODE_FLAG, SKIP_PERMISSIONS_FLAG}
    return any(p in flags for p in parts)


def build_permission_flags(tools_str, permission_mode, skip_permissions):
    """Return the list of permission flags to splice into a claude command.
    `tools_str` is a space/comma-separated tool list ("" => inject nothing,
    i.e. closed-book). `skip_permissions` overrides everything (allows ALL tools).
    """
    if skip_permissions:
        return [SKIP_PERMISSIONS_FLAG]
    flags = []
    tools = [t for t in re.split(r"[,\s]+", tools_str.strip()) if t]
    if tools:
        flags += [ALLOWED_TOOLS_FLAG, *tools]   # pass each tool as its own token
    if permission_mode:
        flags += [PERMISSION_MODE_FLAG, permission_mode]
    return flags


def run_agent(agent_cmd, prompt, prompt_via, timeout, extra_flags):
    base = shlex.split(agent_cmd)
    parts = base + extra_flags                  # permission flags go before the prompt
    if any("{}" in p for p in base):
        argv, stdin = [p.replace("{}", prompt) for p in parts], None
    elif prompt_via == "stdin":
        argv, stdin = parts, prompt
    else:  # append as final argument
        argv, stdin = parts + [prompt], None
    proc = subprocess.run(argv, input=stdin, capture_output=True, text=True, timeout=timeout)
    if proc.returncode != 0:
        raise RuntimeError((proc.stderr or proc.stdout).strip()[:500] or "non-zero exit")
    return proc.stdout.strip()


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
    """Read the whole responses file and print a run-level rollup."""
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

    errors = sum(1 for r in recs if not r.get("ok") or r.get("is_error"))
    print("\n--- run summary ---")
    print(f"questions:        {n}  ({errors} errored)")
    print(f"total cost (usd): {s('total_cost_usd'):.4f}   (notional if on a subscription)")
    print(f"input tokens:     {s('input_tokens'):,}")
    print(f"output tokens:    {s('output_tokens'):,}")
    print(f"cache read:       {s('cache_read_input_tokens'):,}   "
          f"cache create: {s('cache_creation_input_tokens'):,}")
    lat = s("latency_s")
    print(f"latency (s):      {lat:.1f}   (mean {lat / n:.1f}/q)")

    # NEW: tool-activity rollup — the at-a-glance check that tools actually ran.
    web = s("web_search_requests") + s("web_fetch_requests")
    den = s("permission_denials")
    used = sum(1 for r in recs if (r.get("web_search_requests") or 0) + (r.get("web_fetch_requests") or 0) > 0)
    print(f"web tool calls:   {web} executed across {used}/{n} questions   "
          f"({den} permission denials)")
    if den and not web:
        print("  WARNING: tools were attempted but ALL denied — they are not enabled.")
        print("           Check --allowed-tools and your Claude Code version (`claude --help`).")
    elif web:
        print("  OK: web tools are live (executed > 0).")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--agent-cmd", required=True,
                    help='e.g. "claude -p --output-format json" or "codex exec"')
    ap.add_argument("--input", required=True, help="FreshQA CSV exported from the Google Sheet")
    ap.add_argument("--output", required=True, help="responses JSONL to write")
    ap.add_argument("--limit", type=int, default=50)
    ap.add_argument("--prompt-via", choices=["arg", "stdin"], default="arg")
    ap.add_argument("--timeout", type=int, default=300)
    ap.add_argument("--resume", action="store_true", help="skip questions already in --output")
    # NEW: tool-permission controls (only applied to claude commands)
    ap.add_argument("--allowed-tools", default=DEFAULT_TOOLS,
                    help='space/comma-separated tools to pre-authorize for claude. '
                         f'Default: "{DEFAULT_TOOLS}". Pass "" for closed-book (no tools).')
    ap.add_argument("--permission-mode", default=None,
                    help="optional Claude Code permission mode (e.g. acceptEdits, bypassPermissions)")
    ap.add_argument("--skip-permissions", action="store_true",
                    help="append --dangerously-skip-permissions (allows ALL tools; overrides --allowed-tools)")
    args = ap.parse_args()

    # ---- NEW: compute the permission flags and the EFFECTIVE command ----
    base_parts = shlex.split(args.agent_cmd)
    extra_flags = []
    if is_claude_cmd(base_parts):
        if already_has_permission_flag(base_parts):
            print("note: --agent-cmd already sets a permission flag; not injecting.", file=sys.stderr)
        else:
            extra_flags = build_permission_flags(args.allowed_tools, args.permission_mode, args.skip_permissions)
    elif args.allowed_tools != DEFAULT_TOOLS or args.permission_mode or args.skip_permissions:
        print("note: tool/permission flags only apply to claude; ignoring for non-claude agent.", file=sys.stderr)

    effective_cmd = " ".join(shlex.quote(p) for p in base_parts + extra_flags)
    print(f"effective agent command: {effective_cmd}")
    if extra_flags:
        print(f"  (tools allowed: {args.allowed_tools or '(none — closed-book)'})")

    rows = load_rows(args.input)[: args.limit]
    done = already_done(args.output) if args.resume else set()
    mode = "a" if args.resume else "w"

    with open(args.output, mode, encoding="utf-8") as out:
        for idx, row in enumerate(tqdm(rows, desc="querying agent")):
            if row["question"] in done:
                continue
            t0 = time.time()
            metrics, claude_raw = {}, None
            try:
                raw = run_agent(args.agent_cmd, row["question"], args.prompt_via, args.timeout, extra_flags)
                # If the agent emitted Claude Code JSON, pull telemetry, take the
                # answer from its `result` field, and keep the full object; else
                # treat stdout as plain text.
                answer_text, metrics, claude_raw = parse_claude_metrics(raw)
                resp = answer_text if answer_text is not None else raw
                ok, err = True, None
            except Exception as e:
                resp, ok, err = "", False, str(e)
            rec = {
                "idx": idx,
                "question": row["question"],
                "category": row["category"],
                "reference_answers": row["reference_answers"],
                "response": resp,
                "ok": ok,
                "error": err,
                "latency_s": round(time.time() - t0, 2),
                "agent_cmd": effective_cmd,    # NEW: record what ACTUALLY ran, flags included
                "ts": datetime.datetime.now().isoformat(timespec="seconds"),
                **metrics,             # flattened token/cost/duration/tool fields
                "claude_raw": claude_raw,  # full Claude JSON object (null for non-Claude agents)
            }
            out.write(json.dumps(rec, ensure_ascii=False) + "\n")
            out.flush()

    print(f"Wrote responses to {args.output}")
    summarize(args.output)


if __name__ == "__main__":
    main()