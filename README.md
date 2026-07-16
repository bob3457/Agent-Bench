# Agent-Bench

Benchmarking harness for AI coding/QA agents (**Codex CLI**, **Claude Code**,
**OpenHands**) across five benchmarks — **SWE-bench Lite**, **Terminal-Bench
2.0**, **HotpotQA**, **FreshQA**, and **WebArena**

The workflow is two-phase and agent-agnostic:

1. **Generation** — an agent produces predictions (`slurm/run_*.sh` →
   `harness/run_*_agent.py`), written to `data/<family>/`.
2. **Evaluation** — predictions are graded independently of the agent that
   produced them (`slurm/grade_*.sh` → `eval/*.py`).

## Repository layout

| Path | Contents |
|---|---|
| `slurm/` | SLURM batch scripts: `run_*.sh` (generation) and `grade_*.sh` (evaluation) |
| `harness/` | Agent-agnostic generation runners (`run_swebench_agent.py`, `run_hotpot_agent.py`, `run_freshqa_agent.py`, shared `agent_core.py`) |
| `eval/` | Graders: `swebench_singularity_eval.py` (Apptainer-based SWE-bench), `hotpot_evaluate_v1.py` (official EM/F1), `eval_freshqa.py` (LLM judge) |
| `configs/` | `agents.yaml` — agent definitions (command lines, flags, env); campaign selection lists (`instances75.txt` — the 75 SWE-bench instance IDs, `image_names.txt` — their SIF image names, `__` encoded as `_1776_`) |
| `agent_plugins/` | Plugin interface for agents needing Python-side integration (OpenHands) |
| `setup/` | One-time environment setup: `setup_hopper_deps.sh`, `prebake_harbor_sifs.sh` |
| `datasets/` | Benchmark inputs: `hotpot_dev_fullwiki_v1.json` (default HotpotQA mode; fetch on a login node), `hotpot_dev_distractor_v1.json`, `freshqa.csv` |
| `data/` | Per-family agent outputs (`claude/`, `codexlow/`, `codexmed/`, `codexhigh/`, `openhands/`), Harbor run dirs (`harbor_jobs/`), telemetry parser (`parse_codex.py`), storage measurements (`swebench_sizes.csv`) |
| `jobs/` | Harbor job artifacts from Terminal-Bench runs |
| `logs/` | SLURM stdout/stderr and evaluation logs |
| `webarena-verified-hopper/` | Self-contained rootless WebArena toolkit (own README) |
| `misc/` | Historical artifacts (reformat patch) |

A "family" (`FAM`) is one agent×effort configuration — e.g. `codexlow`,
`codexhigh`, `claude` — and names the output directory under `data/`.

## Setup

### 0. Hopper notes

- **No Docker, no root.** All container workloads run via rootless Apptainer.
  One install serves both roles: a self-installed Apptainer **>= 1.5** with
  bundled FUSE tools (`squashfuse_ll`/`fuse2fs`/`fuse-overlayfs`).
  - **Runtime** (executing SIFs): `install-unprivileged.sh` creates a
    `bin/singularity -> apptainer` symlink, so Harbor's singularity backend
    resolves this install once its `bin/` leads `PATH` (the SLURM scripts
    prepend it). SIFs FUSE-mount directly instead of sandbox-unpacking per
    container start. The retired system module
    (`module load hosts/hopper apptainer/1.4.1`) is only a failsafe when the
    self-install is absent — expect slow, tmp-heavy starts under it.
  - **Image building/prebaking**: the same install enables def-file
    `--fakeroot` builds. `setup/prebake_harbor_sifs.sh` picks it up
    via `APPTAINER=` (default `/projects/kzhou6/czhai/apptainer/bin/apptainer` —
    override for your own install). Rootless `--fakeroot` works via
    root-mapped user namespaces — no `/etc/subuid` entry needed.
- **`git` comes from a module** (`git/2.39.1-vd` via the `gnu10/10.3.0-ya`
  chain — Harbor's `--filter=blob:none` clones need git >= 2.19, so the
  ungated `git/2.27.1` is NOT sufficient; also never reload `hosts/hopper`
  after the git chain, or the compiler flips to gnu9 and inactivates it).
  Batch scripts must
  source `/etc/profile.d/lmod.sh` before `module load` — login init doesn't
  run in batch shells. The provided SLURM scripts handle this.

### 1. Install Miniconda, then restart your terminal

```bash
wget https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh
bash Miniconda3-latest-Linux-x86_64.sh -b -p /path/to/project/miniconda3
/path/to/project/miniconda3/bin/conda init bash
# restart the shell, or:  source ~/.bashrc
```

### 2. Accept conda channel terms of service

(The terminal will also print these if you skip them.)

```bash
conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main
conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r
```

### 3. Clone the repo

```bash
cd /projects/kzhou6/czhai # Or to whatever other folder you want it
git clone https://github.com/bob3457/Agent-Bench.git
cd Agent-Bench
```

### 4. Create and activate the environment

```bash
conda env create -f environment.yml     # builds and names the env ("bench") from the file
conda activate bench
```

### 5. Install the agents you plan to use

```bash
# Node needs to be manually installed as conda has a few dependency conflicts
wget https://nodejs.org/dist/v22.14.0/node-v22.14.0-linux-x64.tar.xz
tar xf node-v22.14.0-linux-x64.tar.xz
export PATH=/path/to/project/node-v22.14.0-linux-x64/bin:$PATH
# Claude Code -- npm 11 blocks lifecycle scripts by default; the package name
# must appear in BOTH the whitelist and install-target positions:
npm install -g --allow-scripts=@anthropic-ai/claude-code @anthropic-ai/claude-code

npm install -g @openai/codex               # Codex CLI (requires Node.js)
pip install openhands-ai                    # OpenHands (into the activated env)
```

> Claude Code install + Node version requirements:
> https://docs.claude.com/en/docs/claude-code/overview

Optionally run the one-shot dependency installer + preflight:

```bash
bash setup/setup_hopper_deps.sh              # install + local preflight
bash setup/setup_hopper_deps.sh --check-only # no installs, preflight only
```

### 6. Authentication

Set the key(s) for whichever agent you're running — you don't need all of them at once.
These are session-scoped: re-export them each time you open a terminal (or put them in a
`.env` and source it; do **not** commit real keys).

```bash
# Claude Code (OAuth)
export CLAUDE_CODE_OAUTH_TOKEN=...
export CLAUDE_FORCE_OAUTH=1

# Codex (used by Harbor's codex agent and passed through by the SLURM scripts)
export OPENAI_API_KEY=...

# OpenHands (LiteLLM provider key + model)
export LLM_API_KEY=...
export LLM_MODEL=<provider/model, e.g. anthropic/claude-sonnet-4-6>
```

> **Codex CLI auth caveat:** the Codex CLI build used
> authenticates from `auth.json` inside `CODEX_HOME` (default `~/.codex`) —
> **not** from `OPENAI_API_KEY`. Leave `CODEX_HOME` unset and log in once on
> the cluster so `~/.codex/auth.json` exists. `OPENAI_API_KEY` is still
> required for Harbor's containerized codex agent and for OpenHands.

Confirm an agent is registered and reachable before a full run:

```bash
python harness/run_swebench_agent.py --list-agents
```

> Run harnesses **by file path** (`python harness/run_*.py`), not `python -m`;
> module-mode puts the repo root on `sys.path` and breaks the flat
> `import agent_core`.

---

## Running agents (generation)

Two modes. Both use the same scripts — the `#SBATCH` lines are comments to
bash, so every script runs under `sbatch` *or* plain `bash` inside an
allocation. **Always submit from the repo root** so `logs/` paths resolve.

### A. Batch (sbatch) — for validated full runs

```bash
cd Agent-Bench
export OPENAI_API_KEY=...
sbatch slurm/run_swebench.sh           # or any of the scripts below
squeue -u $USER                        # watch it
tail -f logs/agentbench-*-<jobid>.out
```

### B. Interactive (salloc) — for pilots and flag iteration

```bash
# from a login node
salloc --partition=normal --nodes=1 --ntasks=1 --cpus-per-task=48 --mem=16G --time=04:00:00

cd Agent-Bench
export OPENAI_API_KEY=sk-...           # set once, run many times
SWE_N=1 bash slurm/run_swebench.sh
```

### Per-benchmark SLURM scripts

| Script | Benchmark | Key knobs (env-overridable) |
|---|---|---|
| `slurm/run_swebench.sh` | SWE-bench Lite (generation) | `SWE_N` (default 25) |
| `slurm/run_hotpot.sh` | HotpotQA | `HOTPOT_MODE` (`fullwiki` default / `distractor`), `HOTPOT_N` (50), `RESUME=1` |
| `slurm/run_fresh.sh` | FreshQA | `FRESHQA_N` (50), `FRESHQA_AGENT=codex-search`, `RESUME=1` |
| `slurm/run_terminalbench.sh` | Terminal-Bench 2.0 via Harbor | `AGENT`, `EFFORT`, `TBENCH_N`, `N_CONCURRENT`, `EXTRA_ARGS` |
| `slurm/job.sh` | Combined multi-benchmark driver | union of the above |

Common knobs across all scripts: `AGENT`, `REPO_DIR`, `CONDA_ENV`. Agents are
defined in `configs/agents.yaml`; on Hopper, all Codex agent rows need
`--skip-git-repo-check` there. Pilot before a full run, e.g.
`SWE_N=3 sbatch slurm/run_swebench.sh`.

Generation writes predictions/responses into `data/<FAM>/`
(`predictions.jsonl`, `hotpot_fullwiki_predictions.json` — or unsuffixed
`hotpot_predictions.json` for `HOTPOT_MODE=distractor` — and
`freshqa_responses.jsonl`), which is what the graders below consume.

---

### Terminal-Bench 2.0 via Harbor

Hopper's rootless setup breaks Harbor's in-container installs, so two one-time
steps are required before any run.

**1. Patch Harbor** (re-run after every `pip install --upgrade harbor` — upgrades revert it):

```bash
bash setup/patch_harbor_hopper.sh
```

**2. Pre-bake the task images** (runtime package installs fail on Hopper; baking installs everything ahead of time). The v2 prebaker builds via `apptainer build --fakeroot` from a generated def file and needs the self-installed Apptainer >= 1.5 (set `APPTAINER=` if yours isn't at the default path):

```bash
git clone --depth 1 https://github.com/laude-institute/terminal-bench-2.git /scratch/$USER/tb2

# all tasks (resumable):
bash setup/prebake_harbor_sifs.sh --from-tasks /scratch/$USER/tb2

# or a subset, e.g. first 40 (the list also drives the runs):
ls -d /scratch/$USER/tb2/*/ | xargs -n1 basename | sort | grep -v '^gpt2-codegolf$' | head -40 > tasks_first40.txt
while read -r t; do grep -h '^docker_image' "/scratch/$USER/tb2/$t/task.toml"; done < tasks_first40.txt \
    | sed 's/.*= *"\(.*\)"/\1/' > images_first40.txt
bash setup/prebake_harbor_sifs.sh $(cat images_first40.txt)
```

Tasks flagged **UNBAKEABLE** (e.g. `gpt2-codegolf`) can't run on this backend —
drop them from the list and add to `EXCLUDE_TASKS` on every submission.

**3. Run** (credentials: `OPENAI_API_KEY` for codex/openhands, `CLAUDE_CODE_OAUTH_TOKEN` for claude-code — exported env only, never on the command line):

```bash
# pilot (inside an salloc, see section B):
EXTRA_ARGS="-i llm-inference-batching-scheduler" N_TASKS=1 N_CONCURRENT=1 AGENT=claude-code \
    bash slurm/run_terminalbench.sh 2>&1 | tee logs/tbench-pilot-$(date +%s).log

# campaign — pin the task set (task order is unstable without -i) and keep it
# identical across all agents/efforts:
INC=$(sed 's/^/-i /' tasks_first40.txt | tr '\n' ' ')
for eff in low medium high; do
    EXTRA_ARGS="$INC" AGENT=codex EFFORT=$eff N_TASKS=40 N_CONCURRENT=4 \
        sbatch --time=08:00:00 --cpus-per-task=8 --mem=32G slurm/run_terminalbench.sh
done
EXTRA_ARGS="$INC" AGENT=claude-code N_TASKS=40 N_CONCURRENT=4 \
    sbatch --time=08:00:00 --cpus-per-task=8 --mem=32G slurm/run_terminalbench.sh
```

---

## Evaluating agents (grading)

Grading is decoupled from generation: each `slurm/grade_*.sh` script reads an
output family directory `data/$FAM/` and writes metrics back into it. Select
the family with `FAM=` at submit time (default `codexlow`). All three scripts
support `RESUME=1` (skip if the graded output already exists) and the usual
`REPO_DIR` / `CONDA_ENV` overrides.

```bash
cd Agent-Bench
mkdir -p logs
FAM=claude    sbatch slurm/grade_swebench.sh
FAM=codexhigh sbatch slurm/grade_hotpot.sh
FAM=codexhigh sbatch slurm/grade_fresh.sh
```

### SWE-bench Lite — `slurm/grade_swebench.sh`

Local but **heavy**: each prediction's patch is applied inside an isolated
container and the repo's test suite is run. On Hopper (no Docker) this goes
through the Apptainer-based evaluator `eval/swebench_singularity_eval.py`
rather than the stock Docker harness.

- Input: `data/$FAM/predictions.jsonl` · Output: `data/$FAM/swebench_report.json`
  (`resolved_instances / submitted_instances` is the headline number).
- The dataset loads offline (`HF_HUB_OFFLINE=1`) — pre-cache it first
  ```bash
  python -c "from datasets import load_dataset; load_dataset('princeton-nlp/SWE-bench_Lite')"
  ```
- `MAX_WORKERS` (default 4) controls parallel instance grading; keep
  `--cpus-per-task >= MAX_WORKERS` and watch memory — each worker builds and
  runs a container.

### HotpotQA — `slurm/grade_hotpot.sh`

Fully **offline**: the official EM/F1 script (`eval/hotpot_evaluate_v1.py`)
scores predictions against the gold file for the mode. `HOTPOT_MODE` defaults
to `fullwiki` (matching the runner): it grades
`data/$FAM/hotpot_fullwiki_predictions.json` against
`datasets/hotpot_dev_fullwiki_v1.json` and writes
`data/$FAM/hotpot_fullwiki_metrics.txt`. `HOTPOT_MODE=distractor` grades the
unsuffixed `hotpot_predictions.json` against
`hotpot_dev_distractor_v1.json`. No API key or network needed; runs in
seconds. Reports answer EM/F1, supporting-facts `sp_em`/`sp_f1`, and
`joint_*` metrics. Note that in fullwiki mode `sp_*`/`joint_*` are
best-effort by construction (the agent cites live Wikipedia, so gold sentence
indices are hard to match); answer EM/F1 is the headline metric.

### FreshQA — `slurm/grade_fresh.sh`

Uses an **LLM judge** shelled out via `JUDGE_CMD`: `eval/eval_freshqa.py`
appends the judge prompt as the final argv element and parses the trailing
TRUE/FALSE from stdout. Grades `data/$FAM/freshqa_responses.jsonl` →
`data/$FAM/freshqa_graded.jsonl`.

- Default judge: Codex CLI at low reasoning effort
  (`codex exec --skip-git-repo-check -s read-only -c model_reasoning_effort=low`).
  Needs the `codex` binary on PATH, `auth.json` under `CODEX_HOME` (log in on
  a login node), and API egress from the compute node. Bare `codex` launches
  the interactive TUI and hangs batch jobs — `codex exec` is the headless mode.
- To judge with Claude Code instead:
  ```bash
  export CLAUDE_CODE_OAUTH_TOKEN=...   # `claude setup-token` on a login node
  JUDGE_CMD="claude -p" FAM=claude sbatch slurm/grade_fresh.sh
  ```

### Terminal-Bench — graded inline by Harbor

There is no separate grading script: Harbor runs each task's hidden pytest
verification suite immediately after the agent finishes, producing a binary
pass/fail reward per trial.

**Viewing Harbor data:** Harbor has a command to automatically view jobs ran
Use "Harbor view jobs" to open a local host with previous runs
OR follow the steps below to manually look at the folders where the data is stored

**Reading results:** success = `errored=0` in the script's trials line
(`harbor run` itself exits 0 even when trials fail; the script post-checks
`result.json`). Reward `0.000` with zero errors = agent ran but didn't solve
the task — a result, not a failure. Outputs land in
`data/harbor_jobs/<run_id>/`; codex rollouts in each trial's
`agent/sessions/.../rollout-*.jsonl` (feed to `data/parse_codex.py`). To debug
a failed trial:

```bash
J=$(ls -dt data/harbor_jobs/tbench_* | head -1)
grep -E '\[server\]|\[harbor\]|FATAL' $(find "$J" -name trial.log | head -1) | tail -30
```

### WebArena

WebArena is self-contained under `webarena-verified-hopper/` (rootless site
containers, SLURM launchers, config generation) — see its README for the full
site-hosting and evaluation workflow.

---

## Accessing agent telemetry

### Claude

The following information is stored under `data/claude` (one example below):

```
"5a8b57f25542995d1e6f1371": {
    "agent": "claude",
    "wall_time_s": 5.58,
    "returncode": 0,
    "total_cost_usd": 0.058498,
    "input_tokens": 2,
    "output_tokens": 215,
    "cache_read_input_tokens": 16730,
    "cache_creation_input_tokens": 8017,
    "num_turns": 1,
    "duration_ms": 4839,
    "duration_api_ms": 5882,
    "ttft_ms": 4056,
    "session_id": "78c503ac-6b69-44ee-9fea-5ac3b1b376dc",
    "codex_session_file": null
  }
```

### OpenHands

The data is also in the data folder but under `openhands` instead. One example
set of data is displayed below:

```
"5a8b57f25542995d1e6f1371": {
    "agent": "openhands",
    "wall_time_s": 1.02,
    "returncode": 0,
    "input_tokens": 8051,
    "output_tokens": 98,
    "cache_read_input_tokens": 0,
    "cache_creation_input_tokens": 0,
    "reasoning_tokens": 65,
    "usage": {
      "input_tokens": 8051,
      "output_tokens": 98,
      "cache_read_input_tokens": 0,
      "cache_creation_input_tokens": 0,
      "reasoning_tokens": 65
    },
    "total_cost_usd": 0.043195,
    "usage_breakdown": {
      "agent": 0.043195,
      "condenser": 0.0
    },
    "num_turns": 1,
    "llm_calls": 1,
    "latency_total_s": 1.006,
    "latency_mean_s": 1.006,
    "latency_max_s": 1.006,
    "cost_max_call_usd": 0.043195
  },
```

> OpenHands runs two LLMs (agent + condenser). `get_combined_metrics()` zeroes
> aggregate token usage — the per-instance numbers above come from
> `get_metrics_for_usage("agent")`.

### Codex

Codex statistics are stored under separate `data/codex<effort>` folders and a
script needs to be run to create a csv of the filtered data.

- Rollout files live under the default `CODEX_HOME` (`~/.codex`) sessions
  root; the harness resolves the exact file by regex-parsing `session id:`
  from stderr (mtime fallback is flagged with `codex_session_fallback`).
- After a run, rollout files are reorganized by session subfolder
  (`low_fresh`, `med_fresh`, `high_fresh`, `high_hotpot`, ...).
- CSV naming convention: `<benchmark>_<level>.csv` (e.g. `hotpot_low.csv`,
  `fresh_high.csv`).
- Telemetry caveat: `total_token_usage` is a **cumulative running sum** — only
  the last record is the true total; `last_token_usage` is the per-call delta.
  Context-fill uses per-call peak input tokens.

Run in the Agent-Bench directory:

```bash
python data/parse_codex.py /path/to/session/subfolder \
    --csv data/codexlow/<benchmark>_<level>.csv
```

The following information is parsed by the script:

```
session_id, cli_version, turn_id, model, effort, started_at,
completed_at, duration_ms, time_to_first_token_ms, input_tokens,
cached_input_tokens, output_tokens, reasoning_output_tokens, total_tokens,
model_context_window, n_api_calls, n_tool_calls, wall_clock_s,
cache_hit_rate, context_fill, output_tokens_per_s, mean_api_gap_s
```
