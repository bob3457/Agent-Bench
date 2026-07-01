#!/usr/bin/env python3
"""
agent_core.py — the agent-agnostic core shared by every harness.

This is the single source of truth for HOW an agent is defined, launched, and
read. It deliberately has NO benchmark logic and NO heavy dependencies (no
`datasets`, no task loaders), so any harness -- SWE-bench, FreshQA, HotpotQA, or
a new one -- can `from agent_core import ...` without dragging in things it
doesn't use.

What lives here:
  - AGENTS_FILE / AGENT_TIMEOUT_S : shared defaults.
  - TELEMETRY parsers            : read an agent's stdout into a meta dict.
  - Agent / ShellAgent           : the tiny interface the harnesses talk to.
  - load_agent / load_agents_file: read agents.yaml and instantiate one agent.

What does NOT live here (stays in each harness): the prompt, the task data, the
result capture (git diff vs. parsed answer), and the output format. Those are
per-benchmark; everything in this file is per-agent and benchmark-neutral.
"""

import importlib
import json
import os
import re
import shutil
import subprocess
import time
from pathlib import Path
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))  # repo root

# Shared defaults. AGENT_TIMEOUT_S is read by ShellAgent.run at call time, so a
# harness can override the wall-clock budget with `agent_core.AGENT_TIMEOUT_S = N`
# before invoking an agent.
# Shared defaults. The agents registry lives at <repo>/configs/agents.yaml, and
# this file lives at <repo>/harness/agent_core.py -- so resolve the default from
# __file__ rather than the cwd, letting you run the harness from anywhere. A
# cwd-local ./agents.yaml, if present, still wins (handy for ad-hoc overrides).
# Either way, --agents-file overrides this.
_HARNESS_DIR = Path(__file__).resolve().parent
_CWD_AGENTS = Path("agents.yaml")
AGENTS_FILE = _CWD_AGENTS if _CWD_AGENTS.is_file() else _HARNESS_DIR.parent / "configs" / "agents.yaml"
AGENT_TIMEOUT_S = 600


# === telemetry parsers ======================================================
# Each takes (stdout, meta) and returns raw_text (the prose/diff/answer the
# harness will use). They MUTATE meta with whatever agent-specific fields they
# can pull. Unknown/none just passes stdout through.
#
# NOTE: run() always populates meta["_stdout"] and meta["_stderr"] with the
# FULL, untruncated streams before calling the parser, so a parser can inspect
# stderr too (codex prints its session id there). These underscore-prefixed
# keys are scratch for the parser; harnesses should not persist them.

def _tel_claude_json(stdout, meta):
    try:
        data = json.loads(stdout)
        meta["result_keys"] = list(data.keys())
        meta["usage"] = data.get("usage")           # 4 token buckets
        for k in ("total_cost_usd", "cost_usd", "duration_ms",
                  "duration_api_ms", "ttft_ms", "num_turns", "session_id"):
            if k in data:
                meta[k] = data[k]
        return data.get("result", "") or ""          # diff/prose/answer lives here
    except json.JSONDecodeError:
        meta["parse_error"] = True
        return stdout


# codex prints a header line like "session id: 019f1e8f-b7c9-7a80-bee7-...".
# The uuid is also embedded in the rollout filename:
#   rollout-2026-07-01T12-16-35-<uuid>.jsonl
# so matching on the uuid pins the EXACT file this run created, rather than
# guessing by modification time (which breaks under concurrency or when a prior
# run's file happens to be newest).
_SESSION_ID_RE = re.compile(r"session id:\s*([0-9a-fA-F][0-9a-fA-F-]{7,})", re.IGNORECASE)


def _codex_sessions_root():
    """Where codex writes rollout files. Honors CODEX_HOME (which relocates the
    ENTIRE codex home, sessions/ included); falls back to ~/.codex. This must
    agree with wherever `codex exec` actually ran, so relocating CODEX_HOME per
    job keeps the recorded session paths correct."""
    home = os.environ.get("CODEX_HOME")
    base = Path(home) if home else Path.home() / ".codex"
    return base / "sessions"


def _tel_codex_session(stdout, meta):
    # Rich token/latency data isn't reliably on stdout for `codex exec`; it
    # lands in rollout JSONL under <CODEX_HOME>/sessions/<Y>/<M>/<D>/. Record
    # THIS run's file so aggregate_telemetry.py can parse it later.
    #
    # Strategy: (1) pull the session id codex printed (stdout or stderr) and
    # resolve the rollout file whose name contains that id; (2) if that fails,
    # fall back to the newest *.jsonl under the (CODEX_HOME-aware) sessions root.
    root = _codex_sessions_root()

    combined = (meta.get("_stdout") or stdout or "") + "\n" + (meta.get("_stderr") or "")
    m = _SESSION_ID_RE.search(combined)
    session_id = m.group(1) if m else None
    if session_id:
        meta["codex_session_id"] = session_id

    resolved = None
    try:
        if session_id:
            # Match the id anywhere in the filename. rglob is safe if the tree
            # is missing (yields nothing). Prefer the newest if >1 somehow match.
            hits = sorted(
                root.rglob(f"*{session_id}*.json*"),
                key=lambda p: p.stat().st_mtime,
            )
            if hits:
                resolved = hits[-1]

        if resolved is None:
            # Fallback: newest session file under the CODEX_HOME-aware root.
            # Less reliable (can grab a neighbor's file), so flag it.
            sessions = sorted(
                root.rglob("*.json*"),
                key=lambda p: p.stat().st_mtime,
            )
            if sessions:
                resolved = sessions[-1]
                meta["codex_session_fallback"] = True
    except OSError:
        pass

    if resolved is not None:
        meta["codex_session_file"] = str(resolved)
    return stdout


def _tel_none(stdout, meta):
    return stdout


TELEMETRY = {
    "claude_json": _tel_claude_json,
    "codex_session": _tel_codex_session,
    "none": _tel_none,
}


# === agent interface ========================================================

class Agent:
    """Minimal contract the harnesses depend on. Subclass for plugin agents."""

    def __init__(self, name, cfg):
        self.name = name
        self.cfg = cfg
        self.required_env = cfg.get("required_env", [])

    def check(self):
        """Preflight: abort with a clear message if it can't possibly run."""
        missing = [k for k in self.required_env if not os.environ.get(k)]
        if missing:
            raise SystemExit(
                f"Missing required env var(s) for --agent {self.name}: "
                f"{', '.join(missing)}.\nSet them (e.g. in your .env / SLURM "
                f"job) before running. Keys are read from the env, never hardcoded."
            )

    def run(self, prompt, cwd, model=None):
        """Return (raw_text, meta). raw_text is the agent's textual output
        (prose/diff/answer); meta always carries name, wall_time_s, returncode,
        plus whatever the telemetry parser added."""
        raise NotImplementedError


class ShellAgent(Agent):
    """Any CLI agent that runs in a cwd. Fully defined by its YAML row."""

    def check(self):
        binary = self.cfg["command"][0]
        if shutil.which(binary) is None:
            raise SystemExit(
                f"`{binary}` not found on PATH (needed for --agent {self.name})."
            )
        super().check()

    def run(self, prompt, cwd, model=None):
        cmd = list(self.cfg["command"])
        model_flag = self.cfg.get("model_flag")
        if model and model_flag:
            cmd += [model_flag, model]

        prompt_via = self.cfg.get("prompt_via", "arg")
        stdin_text = None
        if prompt_via == "arg":
            cmd += [prompt]
        elif prompt_via == "stdin":
            stdin_text = prompt
        else:
            raise SystemExit(f"agent {self.name}: bad prompt_via '{prompt_via}'.")

        t0 = time.time()
        try:
            result = subprocess.run(
                cmd, input=stdin_text, capture_output=True, text=True,
                cwd=cwd, timeout=AGENT_TIMEOUT_S,
            )
        except subprocess.TimeoutExpired:
            return "", {"agent": self.name, "wall_time_s": round(time.time() - t0, 2),
                        "returncode": None, "timeout": True}

        meta = {"agent": self.name, "wall_time_s": round(time.time() - t0, 2),
                "returncode": result.returncode}
        if result.returncode != 0:
            meta["stderr"] = (result.stderr or "")[:500]

        # Expose FULL streams to the telemetry parser (codex prints its session
        # id on stderr, and stderr is otherwise only kept truncated on failure).
        # These are scratch fields; drop them after parsing so harnesses don't
        # serialize the whole transcript into their output records.
        meta["_stdout"] = result.stdout or ""
        meta["_stderr"] = result.stderr or ""

        parser = TELEMETRY.get(self.cfg.get("telemetry", "none"), _tel_none)
        raw_text = parser(result.stdout, meta)

        meta.pop("_stdout", None)
        meta.pop("_stderr", None)
        return raw_text, meta


def load_agent(name, agents_cfg):
    """Instantiate ONLY the selected agent (lazy -- don't import unused plugins
    or trip over a binary that isn't installed for an agent you're not running)."""
    if name not in agents_cfg:
        raise SystemExit(f"Unknown agent '{name}'. Known: {', '.join(agents_cfg)}.")
    cfg = agents_cfg[name]
    kind = cfg.get("type", "shell")
    if kind == "shell":
        return ShellAgent(name, cfg)
    if kind == "plugin":
        mod = importlib.import_module(cfg["module"])
        klass = getattr(mod, cfg["class"])
        return klass(name, cfg)
    raise SystemExit(f"agent {name}: unknown type '{kind}'.")


def load_agents_file(path):
    import yaml  # imported here so a missing pyyaml only bites if you run this
    with open(path) as f:
        return yaml.safe_load(f)