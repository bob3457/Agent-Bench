"""Parse token-usage and timing stats from Codex CLI rollout/session JSONL files.

Codex emits one JSON object per line. The records relevant to telemetry are:

  session_meta                       -> session_id, cli_version, model_provider, cwd, git
  event_msg / task_started           -> turn_id, started_at (unix s), model_context_window
  event_msg / token_count            -> info.{total_token_usage,last_token_usage}, one per API round-trip
  event_msg / task_complete          -> turn_id, completed_at (unix s), duration_ms, time_to_first_token_ms
  turn_context                       -> model, effort, reasoning summary mode
  response_item / function_call etc. -> tool activity (used for per-tool latency)

`total_token_usage` is the running cumulative sum within a turn; `last_token_usage`
is the per-call delta. We treat each token_count event as one API round-trip.

The normalized output mirrors the shape produced by parse_claude_metrics so the two
agents can be aggregated side by side. Field name mapping to the Claude Code schema:

  Codex                       Claude Code
  ----------------------      -----------------------------
  input_tokens                input_tokens
  cached_input_tokens         cache_read_input_tokens
  (no direct equivalent)      cache_creation_input_tokens
  output_tokens               output_tokens
  reasoning_output_tokens     (folded into output for CC)
  duration_ms                 duration_ms
  time_to_first_token_ms      ttft_ms
"""

from __future__ import annotations

import csv
import json
import sys
from dataclasses import dataclass, field, asdict
from datetime import datetime, timezone
from pathlib import Path


# ----------------------------------------------------------------------------- #
# helpers
# ----------------------------------------------------------------------------- #

def _parse_ts(iso: str) -> float | None:
    """ISO-8601 (with trailing Z) -> unix seconds (float). None on failure."""
    if not iso:
        return None
    try:
        return datetime.fromisoformat(iso.replace("Z", "+00:00")).timestamp()
    except (ValueError, AttributeError):
        return None


def _safe_div(a: float, b: float) -> float | None:
    return a / b if b else None


# ----------------------------------------------------------------------------- #
# data model
# ----------------------------------------------------------------------------- #

@dataclass
class ApiCall:
    """One model round-trip, anchored on a token_count event."""
    index: int
    wall_ts: float | None                 # event wall-clock (unix s, from line timestamp)
    delta_since_prev_s: float | None      # wall gap from previous logged event
    input_tokens: int = 0
    cached_input_tokens: int = 0
    output_tokens: int = 0
    reasoning_output_tokens: int = 0
    total_tokens: int = 0

    @property
    def cache_hit_rate(self) -> float | None:
        return _safe_div(self.cached_input_tokens, self.input_tokens)


@dataclass
class TurnMetrics:
    turn_id: str
    model: str | None = None
    effort: str | None = None

    # authoritative timing reported by Codex
    started_at: float | None = None           # unix s
    completed_at: float | None = None          # unix s
    duration_ms: int | None = None             # turn wall time per task_complete
    time_to_first_token_ms: int | None = None

    # token usage (cumulative for the turn, taken from the final total_token_usage)
    input_tokens: int = 0
    cached_input_tokens: int = 0
    output_tokens: int = 0
    reasoning_output_tokens: int = 0
    total_tokens: int = 0

    model_context_window: int | None = None
    n_api_calls: int = 0
    n_tool_calls: int = 0
    api_calls: list[ApiCall] = field(default_factory=list)

    # ---- derived ---- #
    @property
    def wall_clock_s(self) -> float | None:
        """started_at -> completed_at, the true end-to-end turn time."""
        if self.started_at is not None and self.completed_at is not None:
            return self.completed_at - self.started_at
        return None

    @property
    def cache_hit_rate(self) -> float | None:
        return _safe_div(self.cached_input_tokens, self.input_tokens)

    @property
    def peak_context_tokens(self) -> int:
        """Largest single-call input — the true peak context occupancy.

        Note: total_tokens is the cumulative sum across all round-trips in the
        turn, NOT a point-in-time figure, so it must not be used for fill.
        """
        return max((c.input_tokens for c in self.api_calls), default=0)

    @property
    def context_fill(self) -> float | None:
        """Fraction of the context window occupied at the turn's peak."""
        return _safe_div(self.peak_context_tokens, self.model_context_window)

    @property
    def output_tokens_per_s(self) -> float | None:
        """Generation throughput over the turn's active duration."""
        if self.duration_ms:
            return _safe_div(self.output_tokens, self.duration_ms / 1000.0)
        return None

    @property
    def mean_api_gap_s(self) -> float | None:
        gaps = [c.delta_since_prev_s for c in self.api_calls
                if c.delta_since_prev_s is not None]
        return _safe_div(sum(gaps), len(gaps)) if gaps else None

    def summary(self) -> dict:
        """Flat, JSON/CSV-friendly record. Excludes the per-call breakdown."""
        d = asdict(self)
        d.pop("api_calls", None)
        d["wall_clock_s"] = self.wall_clock_s
        d["cache_hit_rate"] = self.cache_hit_rate
        d["context_fill"] = self.context_fill
        d["output_tokens_per_s"] = self.output_tokens_per_s
        d["mean_api_gap_s"] = self.mean_api_gap_s
        return d


@dataclass
class SessionMetrics:
    session_id: str | None = None
    cli_version: str | None = None
    model_provider: str | None = None
    cwd: str | None = None
    git_commit: str | None = None
    turns: list[TurnMetrics] = field(default_factory=list)

    def totals(self) -> dict:
        """Roll the turns up into one session-level record."""
        agg = {
            "session_id": self.session_id,
            "cli_version": self.cli_version,
            "model_provider": self.model_provider,
            "n_turns": len(self.turns),
            "input_tokens": sum(t.input_tokens for t in self.turns),
            "cached_input_tokens": sum(t.cached_input_tokens for t in self.turns),
            "output_tokens": sum(t.output_tokens for t in self.turns),
            "reasoning_output_tokens": sum(t.reasoning_output_tokens for t in self.turns),
            "total_tokens": sum(t.total_tokens for t in self.turns),
            "n_api_calls": sum(t.n_api_calls for t in self.turns),
            "n_tool_calls": sum(t.n_tool_calls for t in self.turns),
            "total_duration_ms": sum(t.duration_ms or 0 for t in self.turns),
        }
        agg["cache_hit_rate"] = _safe_div(agg["cached_input_tokens"], agg["input_tokens"])
        ttfts = [t.time_to_first_token_ms for t in self.turns
                 if t.time_to_first_token_ms is not None]
        agg["mean_ttft_ms"] = _safe_div(sum(ttfts), len(ttfts)) if ttfts else None
        return agg


# ----------------------------------------------------------------------------- #
# parsing
# ----------------------------------------------------------------------------- #

def parse_codex_session(path: str | Path) -> SessionMetrics:
    session = SessionMetrics()
    turns: dict[str, TurnMetrics] = {}
    order: list[str] = []
    prev_line_ts: float | None = None

    def get_turn(turn_id: str) -> TurnMetrics:
        if turn_id not in turns:
            turns[turn_id] = TurnMetrics(turn_id=turn_id)
            order.append(turn_id)
        return turns[turn_id]

    # token_count and turn_context records don't always carry a turn_id, so we
    # attribute them to the most recently started turn.
    current_turn_id: str | None = None

    with open(path, "r", encoding="utf-8") as fh:
        for raw in fh:
            raw = raw.strip()
            if not raw:
                continue
            try:
                rec = json.loads(raw)
            except json.JSONDecodeError:
                continue

            line_ts = _parse_ts(rec.get("timestamp", ""))
            rtype = rec.get("type")
            payload = rec.get("payload", {}) or {}

            if rtype == "session_meta":
                session.session_id = payload.get("session_id") or payload.get("id")
                session.cli_version = payload.get("cli_version")
                session.model_provider = payload.get("model_provider")
                session.cwd = payload.get("cwd")
                git = payload.get("git") or {}
                session.git_commit = git.get("commit_hash")

            elif rtype == "turn_context":
                tid = payload.get("turn_id") or current_turn_id
                if tid:
                    t = get_turn(tid)
                    t.model = payload.get("model") or t.model
                    t.effort = payload.get("effort") or t.effort

            elif rtype == "event_msg":
                etype = payload.get("type")

                if etype == "task_started":
                    tid = payload.get("turn_id")
                    current_turn_id = tid
                    t = get_turn(tid)
                    t.started_at = payload.get("started_at")
                    t.model_context_window = payload.get("model_context_window")

                elif etype == "token_count":
                    info = payload.get("info") or {}
                    last = info.get("last_token_usage") or {}
                    total = info.get("total_token_usage") or {}
                    tid = current_turn_id
                    if tid is None:
                        # token_count before any task_started: bucket it loosely
                        tid = "__orphan__"
                    t = get_turn(tid)

                    call = ApiCall(
                        index=t.n_api_calls,
                        wall_ts=line_ts,
                        delta_since_prev_s=(line_ts - prev_line_ts
                                            if line_ts and prev_line_ts else None),
                        input_tokens=last.get("input_tokens", 0),
                        cached_input_tokens=last.get("cached_input_tokens", 0),
                        output_tokens=last.get("output_tokens", 0),
                        reasoning_output_tokens=last.get("reasoning_output_tokens", 0),
                        total_tokens=last.get("total_tokens", 0),
                    )
                    t.api_calls.append(call)
                    t.n_api_calls += 1

                    # cumulative figures: last total_token_usage seen wins
                    if total:
                        t.input_tokens = total.get("input_tokens", t.input_tokens)
                        t.cached_input_tokens = total.get("cached_input_tokens",
                                                           t.cached_input_tokens)
                        t.output_tokens = total.get("output_tokens", t.output_tokens)
                        t.reasoning_output_tokens = total.get(
                            "reasoning_output_tokens", t.reasoning_output_tokens)
                        t.total_tokens = total.get("total_tokens", t.total_tokens)
                    if info.get("model_context_window"):
                        t.model_context_window = info["model_context_window"]

                elif etype == "task_complete":
                    tid = payload.get("turn_id") or current_turn_id
                    if tid:
                        t = get_turn(tid)
                        t.completed_at = payload.get("completed_at")
                        t.duration_ms = payload.get("duration_ms")
                        t.time_to_first_token_ms = payload.get("time_to_first_token_ms")

            elif rtype == "response_item":
                ptype = payload.get("type")
                if ptype in ("function_call", "custom_tool_call",
                             "local_shell_call", "mcp_tool_call"):
                    tid = (payload.get("internal_chat_message_metadata_passthrough", {})
                           or {}).get("turn_id") or current_turn_id
                    if tid:
                        get_turn(tid).n_tool_calls += 1

            if line_ts is not None:
                prev_line_ts = line_ts

    session.turns = [turns[tid] for tid in order]
    return session


# ----------------------------------------------------------------------------- #
# output helpers + CLI
# ----------------------------------------------------------------------------- #

def _fmt(v, nd=2):
    if v is None:
        return "-"
    if isinstance(v, float):
        return f"{v:.{nd}f}"
    return str(v)


def print_report(session: SessionMetrics) -> None:
    print(f"session   : {session.session_id}")
    print(f"cli       : {session.cli_version}   provider: {session.model_provider}")
    print(f"git       : {session.git_commit}")
    print(f"cwd       : {session.cwd}")
    print()
    for t in session.turns:
        print(f"turn {t.turn_id}  [{t.model or '?'} / effort={t.effort or '?'}]")
        print(f"  timing   wall={_fmt(t.wall_clock_s)}s  "
              f"duration={_fmt(t.duration_ms)}ms  ttft={_fmt(t.time_to_first_token_ms)}ms")
        print(f"  tokens   total={t.total_tokens}  in={t.input_tokens}  "
              f"cached={t.cached_input_tokens}  out={t.output_tokens}  "
              f"reasoning={t.reasoning_output_tokens}")
        print(f"  derived  cache_hit={_fmt(t.cache_hit_rate)}  "
              f"ctx_fill={_fmt(t.context_fill)}  "
              f"out_tok/s={_fmt(t.output_tokens_per_s)}  "
              f"api_calls={t.n_api_calls}  tool_calls={t.n_tool_calls}  "
              f"mean_api_gap={_fmt(t.mean_api_gap_s)}s")
        for c in t.api_calls:
            print(f"    call#{c.index:<2} +{_fmt(c.delta_since_prev_s)}s  "
                  f"in={c.input_tokens} cached={c.cached_input_tokens} "
                  f"out={c.output_tokens} reasoning={c.reasoning_output_tokens} "
                  f"(hit={_fmt(c.cache_hit_rate)})")
        print()
    print("SESSION TOTALS:")
    for k, v in session.totals().items():
        print(f"  {k:<24} {_fmt(v)}")


def collect_rollout_files(path: str | Path) -> list[Path]:
    """A single .jsonl path -> [that file]; a directory -> every .jsonl under it
    (recursively), sorted. Codex stores rollouts in dated subfolders, so the
    recursive walk lets you point at any level (a day, a month, or the root)."""
    p = Path(path)
    if p.is_dir():
        return sorted(p.rglob("*.jsonl"))
    return [p]


def write_turn_csv(sessions: list[SessionMetrics], path: str | Path) -> None:
    """One row per turn, across all sessions. Leading session_id/cli_version
    columns keep rows traceable back to their rollout."""
    rows = []
    for s in sessions:
        for t in s.turns:
            row = {"session_id": s.session_id, "cli_version": s.cli_version}
            row.update(t.summary())
            rows.append(row)
    if not rows:
        return
    fieldnames = list(rows[0].keys())
    with open(path, "w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=fieldnames)
        w.writeheader()
        w.writerows(rows)


def main(argv: list[str]) -> int:
    if not argv:
        print("usage: parse_codex_metrics.py <rollout.jsonl | dir/> "
              "[--json] [--csv out.csv]", file=sys.stderr)
        return 2

    files = collect_rollout_files(argv[0])
    if not files:
        print(f"no .jsonl rollouts found under {argv[0]}", file=sys.stderr)
        return 1

    sessions = []
    parsed_files = []
    for f in files:
        try:
            sessions.append(parse_codex_session(f))
            parsed_files.append(f)
        except Exception as exc:  # one bad file shouldn't sink the batch
            print(f"skipped {f}: {type(exc).__name__}: {exc}", file=sys.stderr)

    if "--json" in argv:
        out = [{
            "source_file": str(f),
            "session": {k: v for k, v in asdict(s).items() if k != "turns"},
            "turns": [t.summary() for t in s.turns],
            "totals": s.totals(),
        } for f, s in zip(parsed_files, sessions)]
        # stay a single object when only one file was parsed
        print(json.dumps(out[0] if len(out) == 1 else out, indent=2))
    else:
        for f, s in zip(parsed_files, sessions):
            if len(sessions) > 1:
                print(f"### {f}")
            print_report(s)
            if len(sessions) > 1:
                print()

    if "--csv" in argv:
        csv_path = argv[argv.index("--csv") + 1]
        write_turn_csv(sessions, csv_path)
        n_turns = sum(len(s.turns) for s in sessions)
        print(f"\nwrote {n_turns} turn rows from {len(sessions)} session(s) "
              f"-> {csv_path}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))