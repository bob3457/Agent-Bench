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


def _tel_codex_session(stdout, meta):
    # Rich token/latency data isn't reliably on stdout for codex exec; it lands
    # in rollout files under ~/.codex/sessions/. Record the newest one's path
    # so aggregate_telemetry.py can parse it later.
    try:
        sessions = sorted(
            Path.home().joinpath(".codex", "sessions").rglob("*.json*"),
            key=lambda p: p.stat().st_mtime,
        )
        if sessions:
            meta["codex_session_file"] = str(sessions[-1])
    except OSError:
        pass
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
            meta["stderr"] = result.stderr[:500]

        parser = TELEMETRY.get(self.cfg.get("telemetry", "none"), _tel_none)
        raw_text = parser(result.stdout, meta)
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