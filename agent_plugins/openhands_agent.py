#!/usr/bin/env python3
"""
Example PLUGIN agent: OpenHands (V1 / agent-SDK architecture).

This shows how a framework-style agent that doesn't fit the "invoke a binary,
edit cwd" mold plugs in. As of OpenHands V1 the agent loop is a *Python library*
(`openhands-sdk`), not a headless CLI. The old `python -m openhands.core.main`
entrypoint, the `RUNTIME` / `WORKSPACE_BASE` env vars, and the self-managed
Docker runtime are all gone. So this plugin drives the SDK in-process instead of
shelling out.

Verified against openhands-sdk==1.29.0 and openhands-tools==1.29.0
(the deps pinned by openhands-ai 1.8.0). The V1 surface is fast-moving; if you
bump those pins, re-check the constructor signatures used below.

A plugin agent is just a class that subclasses the harness Agent and implements
run(). The harness imports it by module/class name and treats it like any other
agent -- it never knows this is "special".

Key concept for the original "what is the workspace env var?" question: there
ISN'T one anymore. The workspace is the repo checkout directory, passed as the
`workspace=` argument to Conversation. It is a filesystem path (your `cwd`), not
a conda env name and not an OpenHands-internal identifier. The LocalConversation
runs all tools in-process inside that directory -- no Docker, no Apptainer
wrapper needed, which is exactly what we want on rootless HPC.
"""

import os
import time
import shutil
import threading

# Import the base class from the harness module. Adjust if you rename the file.
from run_swebench_agent import Agent, AGENT_TIMEOUT_S

# Cap the agent's step budget as a secondary bound alongside the wall-clock
# timeout. A single SWE-bench fix rarely needs hundreds of turns.
MAX_ITERATIONS = 200


class OpenHandsAgent(Agent):

    def check(self):
        # V1 splits the framework across three packages; all must be importable.
        try:
            import openhands.sdk  # noqa: F401
            import openhands.tools  # noqa: F401
        except ImportError as exc:
            raise SystemExit(
                f"openhands V1 not importable ({exc}). Install it into this env:\n"
                "  pip install openhands-sdk openhands-tools\n"
                "before running --agent openhands."
            )
        super().check()  # validates required_env (e.g. LLM_API_KEY) from the YAML row

    def run(self, prompt, cwd, model=None):
        # Lazy import: keeps harness startup cheap and confines the SDK's
        # import-time banner to actual runs.
        from openhands.sdk import LLM, Conversation, TextContent
        from openhands.sdk.event import MessageEvent
        from openhands.tools import get_default_agent

        # --- LLM config -----------------------------------------------------
        # Model comes from the harness (per-row in agents.yaml) or LLM_MODEL.
        # The API key + optional base_url are read from the env the YAML row
        # declares as required. These are passed to the LLM object directly --
        # there is no global config file or RUNTIME env var involved.
        llm = LLM(
            usage_id="agent",
            model=model or os.environ.get("LLM_MODEL", "gpt-5.5"),
            api_key=os.environ.get("LLM_API_KEY"),
            base_url=os.environ.get("LLM_BASE_URL")
            or os.environ.get("OPENHANDS_PROVIDER_BASE_URL"),
        )

        # --- Agent ----------------------------------------------------------
        # get_default_agent assembles the maintained coding toolset (terminal,
        # file editor, grep/glob, task tracker, ...) plus the default condenser.
        # cli_mode=True drops the browser tools, which we don't want under a
        # headless sandbox. For gpt-5 family models there is also
        # `from openhands.tools.preset.gpt5 import get_gpt5_agent`, tuned for
        # the Responses API -- swap it in if you standardize on gpt-5.5.
        agent = get_default_agent(llm=llm, cli_mode=True)

        # --- Capture the agent's final message ------------------------------
        # Tool output isn't a stdout stream anymore; we observe the event bus.
        # Collect text from agent-sourced messages and return the last one as
        # the run's "stdout"-equivalent.
        agent_texts: list[str] = []

        def on_event(event):
            if isinstance(event, MessageEvent) and event.source == "agent":
                parts = [
                    c.text for c in event.llm_message.content
                    if isinstance(c, TextContent)
                ]
                if parts:
                    agent_texts.append("".join(parts))

        # --- Conversation ---------------------------------------------------
        # workspace=cwd is THE answer to the workspace question: the repo
        # checkout, edited in place. persistence_dir is left at its default
        # (None) so no state files land in cwd and dirty the git worktree that
        # SWE-bench evaluates.
        conversation = Conversation(
            agent=agent,
            workspace=str(cwd),
            callbacks=[on_event],
            max_iteration_per_run=MAX_ITERATIONS,
        )

        # --- Run with a wall-clock timeout ----------------------------------
        # run() blocks until the agent finishes or hits max_iteration_per_run.
        # It's in-process, so unlike subprocess.run there's no native timeout;
        # we run it on a worker thread and bound it with join(). A timed-out
        # thread can't be force-killed mid-LLM-call -- it's daemonized so it
        # won't block process exit, and MAX_ITERATIONS caps runaway loops.
        conversation.send_message(prompt)

        run_error: list[BaseException] = []

        def _run():
            try:
                conversation.run()
            except BaseException as exc:  # noqa: BLE001 - surfaced via meta
                run_error.append(exc)

        t0 = time.time()
        worker = threading.Thread(target=_run, daemon=True)
        worker.start()
        worker.join(timeout=AGENT_TIMEOUT_S)
        wall = round(time.time() - t0, 2)

        meta = {"agent": self.name, "wall_time_s": wall}

        if worker.is_alive():
            meta["timeout"] = True
            meta["returncode"] = None
        elif run_error:
            meta["error"] = f"{type(run_error[0]).__name__}: {run_error[0]}"[:500]
            meta["returncode"] = 1
        else:
            meta["returncode"] = 0

        # --- Telemetry into the common schema -------------------------------
        # ConversationStats aggregates per-LLM Metrics. Map TokenUsage onto the
        # input/output/cache_read schema aggregate_telemetry.py expects, so the
        # OpenHands row lines up with Codex CLI and Claude Code.
        try:
            metrics = conversation.conversation_stats.get_combined_metrics()
            usage = metrics.accumulated_token_usage
            if usage is not None:
                meta["input_tokens"] = usage.prompt_tokens
                meta["output_tokens"] = usage.completion_tokens
                meta["cache_read_tokens"] = usage.cache_read_tokens
                meta["reasoning_tokens"] = usage.reasoning_tokens
            meta["cost_usd"] = round(metrics.accumulated_cost, 6)
        except Exception as exc:  # noqa: BLE001 - telemetry is best-effort
            meta["telemetry_error"] = str(exc)[:200]

        output = agent_texts[-1] if agent_texts else ""
        return output, meta