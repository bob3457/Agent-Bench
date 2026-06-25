#!/usr/bin/env python3
"""
Example PLUGIN agent: OpenHands.

This exists to show how an agent that DOESN'T fit the simple "invoke a binary,
edit cwd" mold plugs in. OpenHands is a framework that routes to an LLM via
LiteLLM and (by default) runs its own runtime container -- so a YAML shell row
can't express it. Instead it's `type: plugin` in agents.yaml, pointing here.

A plugin agent is just a class that subclasses Agent and implements run().
The harness imports it by module/class name and treats it exactly like any
other agent -- it never knows this is "special".

Use any of this as a template for your own framework-style agents.

TODO: VERIFY everything below against current OpenHands docs -- this is a
SKELETON. OpenHands changes fast; the module path, flags, runtime env var, and
workspace env var have all moved historically.
"""

import os
import time
import shutil
import subprocess

# Import the base class from the harness module. Adjust if you rename the file.
from run_swebench_agent import Agent, AGENT_TIMEOUT_S


class OpenHandsAgent(Agent):

    def check(self):
        if shutil.which("python") is None:
            raise SystemExit("`python` not found on PATH (needed for openhands).")
        # confirm the package is importable, with a clear message if not
        try:
            import openhands  # noqa: F401
        except ImportError:
            raise SystemExit(
                "openhands not importable. Install it into this env "
                "(see OpenHands docs) before running --agent openhands."
            )
        super().check()  # checks required_env (LLM_API_KEY) from the YAML row

    def run(self, prompt, cwd, model=None):
        env = os.environ.copy()
        # By default OpenHands spins up its OWN Docker runtime, which won't work
        # under rootless/Apptainer. Force a non-Docker runtime so it edits the
        # checkout in place. TODO: confirm the current env var name/value.
        env.setdefault("RUNTIME", "local")
        env["WORKSPACE_BASE"] = str(cwd)        # TODO: verify env var name
        if model:
            env["LLM_MODEL"] = model

        # TODO: verify the headless entrypoint and flags.
        cmd = ["python", "-m", "openhands.core.main", "-t", prompt]

        t0 = time.time()
        try:
            result = subprocess.run(
                cmd, capture_output=True, text=True,
                cwd=cwd, env=env, timeout=AGENT_TIMEOUT_S,
            )
        except subprocess.TimeoutExpired:
            return "", {"agent": self.name, "wall_time_s": round(time.time() - t0, 2),
                        "returncode": None, "timeout": True}

        meta = {"agent": self.name, "wall_time_s": round(time.time() - t0, 2),
                "returncode": result.returncode}
        if result.returncode != 0:
            meta["stderr"] = result.stderr[:500]
        # OpenHands writes its own trajectory/event logs; aggregate_telemetry.py
        # is where you'd parse those into the common schema.
        return result.stdout, meta