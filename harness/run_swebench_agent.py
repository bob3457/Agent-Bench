#!/usr/bin/env python3
"""
SWE-bench_Lite GENERATION harness — agent-open.

Generation half of SWE-bench: drives an agent to edit a real checkout at
base_commit and emits predictions.jsonl (instance_id -> model_patch). It does
NOT score; that's run_singularity.py, which is agent-agnostic.

WHY THIS IS AGENT-OPEN
  The harness only ever does three agent-neutral things: hand the agent a
  prompt in a checkout, let it edit the working tree, capture the diff. The
  only per-agent knowledge is (1) how to invoke it, (2) what env it needs,
  (3) how to read its telemetry -- and all three are DATA in agents.yaml, not
  code here. So adding a CLI agent is a ~5-line YAML entry, zero code.

  Agents that don't fit the "invoke a binary, edit cwd" mold (e.g. OpenHands,
  which runs its own runtime) are `type: plugin` in the YAML and implement the
  tiny Agent interface in a separate .py. The harness talks only to `Agent`
  and never knows the difference.

LIMITS (so the abstraction doesn't overpromise)
  - Diff capture only works for agents that edit files locally in cwd. Agents
    in a different action space (browser nav, etc.) are out of scope.
  - Telemetry does not generalize for free: the COMMON fields (wall-clock,
    returncode) are uniform; rich per-agent fields (tokens/cost) are parsed
    per-agent and normalized downstream in aggregate_telemetry.py. An unknown
    agent may yield only wall-clock -- that's fine, it still runs.

Outputs (per agent, so runs never clobber each other):
    data/<agent>/predictions.jsonl
    data/<agent>/metrics.jsonl
    data/repo_cache/                 (shared checkouts)

Resumable: appends and skips instance_ids already present.

Requires: pip install pyyaml datasets
"""

import argparse
import importlib
import json
import os
import time
import shutil
import subprocess
from pathlib import Path

from datasets import load_dataset

# --- config -----------------------------------------------------------------
DATA_DIR = Path("data")
REPO_CACHE = DATA_DIR / "repo_cache"
AGENTS_FILE = Path("agents.yaml")
AGENT_TIMEOUT_S = 600
DEFAULT_N_INSTANCES = 25
# ----------------------------------------------------------------------------


def out_paths(agent):
    d = DATA_DIR / agent
    d.mkdir(parents=True, exist_ok=True)
    return d / "predictions.jsonl", d / "metrics.jsonl"


# === telemetry parsers ======================================================
# Each takes (stdout, meta) and returns raw_text (used by the printed-diff
# fallback). They MUTATE meta with whatever agent-specific fields they can
# pull. Unknown/none just passes stdout through.

def _tel_claude_json(stdout, meta):
    try:
        data = json.loads(stdout)
        meta["result_keys"] = list(data.keys())
        meta["usage"] = data.get("usage")           # 4 token buckets
        for k in ("total_cost_usd", "cost_usd", "duration_ms",
                  "duration_api_ms", "ttft_ms", "num_turns", "session_id"):
            if k in data:
                meta[k] = data[k]
        return data.get("result", "") or ""          # diff/prose lives here
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
    """Minimal contract the harness depends on. Subclass for plugin agents."""

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
        """Return (raw_text, meta). raw_text only feeds the printed-diff
        fallback; the real result is whatever it edited in the tree."""
        raise NotImplementedError


class ShellAgent(Agent):
    """Any CLI agent that edits files in cwd. Fully defined by its YAML row."""

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


# === shared: prompt, git, repo setup ========================================

def build_prompt(example):
    return f"""Fix this GitHub issue. You are in the root of a git checkout of the
repository at the relevant base commit.

{example['problem_statement']}

Instructions:
1. Inspect the relevant source files to locate the bug.
2. Edit the files directly to fix the issue. Apply your changes to the
   working tree using your file-editing tools.
3. Make the smallest correct change. Do not add tests or unrelated edits.
4. You do not need to print a diff; the changes you make to the files are
   what will be evaluated.
"""


def git(args, cwd, check=True):
    return subprocess.run(
        ["git", *args], cwd=cwd, capture_output=True, text=True, check=check
    )


def ensure_repo(repo, base_commit):
    owner, name = repo.split("/")
    dest = REPO_CACHE / f"{owner}__{name}"
    if not dest.exists():
        dest.parent.mkdir(parents=True, exist_ok=True)
        print(f"  cloning {repo} ...")
        git(["clone", f"https://github.com/{repo}.git", str(dest)], cwd=".")
    git(["fetch", "--quiet", "origin", base_commit], cwd=dest, check=False)
    git(["reset", "--hard", "--quiet", base_commit], cwd=dest)
    git(["clean", "-fdx", "--quiet"], cwd=dest)
    return dest


# === shared: patch capture, validation, resume ==============================

def clean_patch(output):
    if not output:
        return ""
    output = output.strip()
    if "```" in output:
        for part in output.split("```"):
            if "diff --git" in part:
                return part[part.index("diff --git"):].strip() + "\n"
    if "diff --git" in output:
        return output[output.index("diff --git"):].strip() + "\n"
    return ""


def patch_applies(patch, cwd):
    if not patch.strip():
        return False
    proc = subprocess.run(
        ["git", "apply", "--reverse", "--check", "-"],
        cwd=cwd, input=patch, capture_output=True, text=True,
    )
    return proc.returncode == 0


def already_done(pred_path):
    done = set()
    if pred_path.exists():
        with open(pred_path) as f:
            for line in f:
                line = line.strip()
                if line:
                    try:
                        done.add(json.loads(line)["instance_id"])
                    except (json.JSONDecodeError, KeyError):
                        pass
    return done


# === main ===================================================================

def main():
    ap = argparse.ArgumentParser(description="Agent-open SWE-bench generation harness.")
    ap.add_argument("--agent", default="claude",
                    help="Agent name from the agents file (default: claude).")
    ap.add_argument("--n", type=int, default=DEFAULT_N_INSTANCES,
                    help=f"Number of instances (default: {DEFAULT_N_INSTANCES}).")
    ap.add_argument("--model", default=None, help="Optional model override.")
    ap.add_argument("--agents-file", default=str(AGENTS_FILE),
                    help=f"Path to the agent registry (default: {AGENTS_FILE}).")
    ap.add_argument("--list-agents", action="store_true",
                    help="Print known agents and exit.")
    args = ap.parse_args()

    agents_cfg = load_agents_file(args.agents_file)

    if args.list_agents:
        for name, cfg in agents_cfg.items():
            print(f"  {name:12} ({cfg.get('type', 'shell')})")
        return

    if shutil.which("git") is None:
        raise SystemExit("`git` not found on PATH.")

    agent = load_agent(args.agent, agents_cfg)
    agent.check()                              # preflight: binary + keys

    pred_path, metrics_path = out_paths(args.agent)
    REPO_CACHE.mkdir(parents=True, exist_ok=True)

    model_name = args.model or args.agent
    dataset = load_dataset("princeton-nlp/SWE-bench_Lite",
                           split=f"test[:{args.n}]")

    done = already_done(pred_path)
    if done:
        print(f"Resuming: {len(done)} instance(s) already in {pred_path}, skipping.")
    print(f"Agent: {args.agent} | instances: {args.n} | output: {pred_path.parent}/")

    with open(pred_path, "a") as pf, open(metrics_path, "a") as mf:
        for i, ex in enumerate(dataset):
            iid = ex["instance_id"]
            if iid in done:
                print(f"=== {iid} ({i+1}/{len(dataset)}) -- skipped")
                continue

            print(f"\n=== {iid} ({i+1}/{len(dataset)}) [{args.agent}] ===")

            try:
                repo_dir = ensure_repo(ex["repo"], ex["base_commit"])
            except subprocess.CalledProcessError as e:
                print(f"  repo setup failed: {e.stderr[:200] if e.stderr else e}")
                mf.write(json.dumps({"instance_id": iid, "agent": args.agent,
                                     "repo_setup_error": True}) + "\n")
                mf.flush()
                continue

            raw, meta = agent.run(build_prompt(ex), cwd=repo_dir, model=args.model)
            if i == 0 and meta.get("result_keys"):
                print("RESULT KEYS:", meta.get("result_keys"))

            # --- SHARED, agent-agnostic diff capture ---
            git(["add", "-A"], cwd=repo_dir, check=False)
            patch = git(["diff", "--cached"], cwd=repo_dir, check=False).stdout
            if patch and not patch.endswith("\n"):
                patch += "\n"
            meta["capture"] = "git_diff" if patch.strip() else None

            # Fallback: tree clean but the agent printed a diff in its output.
            if not patch.strip():
                printed = clean_patch(raw)
                if printed.startswith("diff --git"):
                    print("  tree clean; using printed diff from output")
                    patch = printed
                    meta["capture"] = "printed"

            if patch.strip():
                ok = patch_applies(patch, cwd=repo_dir)
                meta["applies_clean"] = ok
                if not ok:
                    print("  patch does NOT apply cleanly (saved anyway, flagged)")
            else:
                print("  no changes produced -- saving empty")
                patch = ""
                meta["applies_clean"] = False

            pf.write(json.dumps({
                "instance_id": iid,
                "model_patch": patch,
                "model_name_or_path": model_name,
            }) + "\n")
            pf.flush()

            mf.write(json.dumps({"instance_id": iid, **meta}) + "\n")
            mf.flush()

            print(f"  tokens={meta.get('usage')} time={meta['wall_time_s']}s "
                  f"cost={meta.get('total_cost_usd')} rc={meta.get('returncode')}")

    print(f"\nDONE: {pred_path} + {metrics_path}")


if __name__ == "__main__":
    main()