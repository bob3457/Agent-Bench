#!/usr/bin/env python3
"""
Example PLUGIN agent: OpenHands (V1 / agent-SDK architecture).

This shows how a framework-style agent that doesn't fit the "invoke a binary,
edit cwd" mold plugs in. As of OpenHands V1 the agent loop is a *Python library*
(`openhands-sdk`), not a headless CLI. The old `python -m openhands.core.main`
entrypoint, the `RUNTIME` / `WORKSPACE_BASE` env vars, and the self-managed
Docker runtime are all gone. So this plugin drives the SDK in-process instead of
shelling out.

Verified against openhands-sdk==1.27.0 and openhands-tools==1.27.0 (the deps
actually installed in the `bench` env; `pip show openhands-sdk` to confirm).

A plugin agent is just a class that subclasses the harness Agent and implements
run(). The harness imports it by module/class name and treats it like any other
agent -- it never knows this is "special".

Key concept for the original "what is the workspace env var?" question: there
ISN'T one anymore. The workspace is the repo checkout directory, passed as the
`workspace=` argument to Conversation. It is a filesystem path (your `cwd`), not
a conda env name and not an OpenHands-internal identifier.

Terminal noise: the SDK prints a boxed banner and state.py INFO/WARNING lines
(including the expected "No persistence_dir provided" fallback). Both are
silenced at import time below; neither is data.

TELEMETRY -- the resolved story. An OpenHands run drives MORE THAN ONE LLM:
conversation_stats.usage_to_metrics is keyed by usage_id and contains at least
['agent', 'condenser'] -- the coding agent plus the context condenser that
compresses history. Consequences that cost several debugging rounds:
  * get_combined_metrics() reports cost correctly but ZEROES the aggregate
    token_usage (an artifact of how it merges the per-usage records). So cost
    looked fine while every token column came out null.
  * The locally constructed `llm` is a copy and stays at zero; only the live
    per-usage metrics accumulate.
The fix: read per-usage metrics via get_metrics_for_usage(<id>).
  - COST + TOKENS are SUMMED across all usages (agent + condenser). That sum is
    the true per-task spend -- the condenser is real money, intrinsic to running
    this agent, so excluding it would flatter OpenHands against Codex CLI /
    Claude Code, which have no separate condenser line.
  - TURNS + LATENCY + per-call cost spread are read from the AGENT usage only --
    those describe the reasoning loop, not the compressor.
Record in run metadata that OpenHands cost = agent + condenser summed.

Field names are mapped onto the CANONICAL schema keys (total_cost_usd,
cache_read_input_tokens, cache_creation_input_tokens) the JSONL writer and
aggregate_telemetry.py expect; mismatched names are silently dropped. The
harness's flatten_telemetry is pass-through, so any extra key emitted here
(reasoning_tokens, usage_breakdown, num_turns, latency_*, cost_max_call_usd)
lands in the metrics file with no harness change. Per-instance CSV is written by
the harness (which has instance_id); this plugin only populates meta.

The extra-telemetry block introspects field names defensively (getattr with
fallbacks) so a version bump degrades a field to "absent" rather than crashing
the whole telemetry read. If latency_* or cost_max_call_usd come back missing
after a real run, probe the Metrics object's response_latencies / costs shapes
and adjust the accessors.
"""

import os
import time
import logging
import threading

# Quiet the SDK before anything imports it.
os.environ.setdefault("OPENHANDS_SUPPRESS_BANNER", "1")
logging.getLogger("openhands").setLevel(logging.ERROR)

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
        # Lazy import: keeps harness startup cheap.
        from openhands.sdk import LLM, Conversation, TextContent
        from openhands.sdk.event import MessageEvent
        from openhands.tools import get_default_agent

        # --- LLM config -----------------------------------------------------
        # NOTE: model strings route through LiteLLM, so they need a provider
        # prefix -- e.g. "openai/gpt-5.5", not bare "gpt-5.5".
        llm = LLM(
            usage_id="agent",
            model=model or os.environ.get("LLM_MODEL", "openai/gpt-5.5"),
            api_key=os.environ.get("LLM_API_KEY"),
            base_url=os.environ.get("LLM_BASE_URL")
            or os.environ.get("OPENHANDS_PROVIDER_BASE_URL"),
        )

        # --- Agent ----------------------------------------------------------
        # cli_mode=True drops the browser tools we don't want under a headless
        # sandbox.
        agent = get_default_agent(llm=llm, cli_mode=True)

        # --- Capture the agent's final message ------------------------------
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
        # workspace=cwd is the repo checkout, edited in place. persistence_dir
        # left at default (None) so no state files dirty the worktree.
        conversation = Conversation(
            agent=agent,
            workspace=str(cwd),
            callbacks=[on_event],
            max_iteration_per_run=MAX_ITERATIONS,
        )

        # --- Run with a wall-clock timeout ----------------------------------
        # In-process, so we bound it on a daemon worker thread via join().
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
        # Sum per-usage metrics across ALL usages (agent + condenser + any
        # others). get_combined_metrics() zeroes the aggregate token_usage, so
        # we iterate usage_to_metrics and sum the per-usage records instead.
        #
        # SDK name (1.27.0)        -> canonical schema key
        #   prompt_tokens          -> input_tokens
        #   completion_tokens      -> output_tokens
        #   cache_read_tokens      -> cache_read_input_tokens
        #   cache_write_tokens     -> cache_creation_input_tokens
        #   reasoning_tokens       -> reasoning_tokens
        #   accumulated_cost       -> total_cost_usd
        try:
            cs = conversation.conversation_stats
            keys = list(getattr(cs, "usage_to_metrics", {}) or {})
            mets = [cs.get_metrics_for_usage(k) for k in keys]
            usages = [m.accumulated_token_usage for m in mets]

            tok = {
                "input_tokens": sum(u.prompt_tokens for u in usages),
                "output_tokens": sum(u.completion_tokens for u in usages),
                "cache_read_input_tokens": sum(u.cache_read_tokens for u in usages),
                "cache_creation_input_tokens": sum(u.cache_write_tokens for u in usages),
                "reasoning_tokens": sum(u.reasoning_tokens for u in usages),
            }
            # Top-level for anything reading meta directly (CSV writer, direct calls).
            meta.update(tok)
            # Nested under "usage" too: the harness flatten lifts these (Claude
            # Code shape). Mirroring lets the existing read path pick them up.
            meta["usage"] = dict(tok)

            meta["total_cost_usd"] = round(sum(m.accumulated_cost for m in mets), 6)
            meta["usage_breakdown"] = {
                k: round(m.accumulated_cost, 6) for k, m in zip(keys, mets)
            }

            # --- extra telemetry: per-call latency, turn count, cost spread ---
            # AGENT usage only (not condenser): turns/latency describe the
            # reasoning loop. All best-effort; field names introspected so a
            # version bump degrades a field to "absent", not a crash.
            agent_m = mets[keys.index("agent")] if "agent" in keys else None
            if agent_m is not None:
                # token_usages has one record per LLM call -> turn count
                tus = getattr(agent_m, "token_usages", None)
                if tus is not None:
                    meta["num_turns"] = len(tus)
                    meta["llm_calls"] = len(tus)

                # response_latencies: list of per-call latency records
                lats = getattr(agent_m, "response_latencies", None) or []
                vals = []
                for l in lats:
                    v = getattr(l, "latency", None)
                    if v is None:
                        v = getattr(l, "latency_s", None)
                    if isinstance(v, (int, float)):
                        vals.append(v)
                if vals:
                    meta["latency_total_s"] = round(sum(vals), 3)
                    meta["latency_mean_s"] = round(sum(vals) / len(vals), 3)
                    meta["latency_max_s"] = round(max(vals), 3)

                # costs: per-call cost list -> spot the expensive call (cost
                # outlier flagging, like the Codex RST retry)
                costs = getattr(agent_m, "costs", None) or []
                cvals = [getattr(c, "cost", c) for c in costs]
                cvals = [c for c in cvals if isinstance(c, (int, float))]
                if cvals:
                    meta["cost_max_call_usd"] = round(max(cvals), 6)
        except Exception as exc:  # noqa: BLE001 - telemetry is best-effort
            meta.setdefault("telemetry_error", str(exc)[:200])

        output = agent_texts[-1] if agent_texts else ""
        return output, meta