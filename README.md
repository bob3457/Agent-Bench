# Agent-Bench

## Setup

### 0. Hopper notes

- **No Docker, no root.** All container workloads run via rootless Apptainer
  (`module load hosts/hopper apptainer/1.4.1`). The module ships a
  `singularity` symlink, which Harbor's singularity backend uses. Rootless
  `--fakeroot` works via root-mapped user namespaces — no `/etc/subuid` entry
  needed.
- **`git` comes from a module** (`git/2.27.1`, ungated). Batch scripts must
  source `/etc/profile.d/lmod.sh` before `module load` — login init doesn't
  run in batch shells. The provided SLURM scripts handle this.

### 1. Install Miniconda, then restart your terminal

```bash
wget https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh
bash Miniconda3-latest-Linux-x86_64.sh -b -p $HOME/miniconda3
$HOME/miniconda3/bin/conda init bash
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
cd /scratch/$USER # Or to whatever other folder you want it
git clone https://github.com/bob3457/Agent-Bench.git
cd Agent-Bench
```

### 4. Create and activate the environment

```bash
conda env create -f envs/bench.yml     # builds and names the env ("bench") from the file
conda activate bench
```

### 5. Install the agents you plan to use

```bash
# Claude Code -- npm 11 blocks lifecycle scripts by default; the package name
# must appear in BOTH the whitelist and install-target positions:
npm install -g --allow-scripts=@anthropic-ai/claude-code @anthropic-ai/claude-code

npm install -g @openai/codex               # Codex CLI (requires Node.js)
pip install openhands-ai                    # OpenHands (into the activated env)
```

> Claude Code install + Node version requirements:
> https://docs.claude.com/en/docs/claude-code/overview

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

## Running on Hopper

Two modes. Both use the same scripts — the `#SBATCH` lines are comments to
bash, so every script runs under `sbatch` *or* plain `bash` inside an
allocation.

### A. Batch (sbatch) — for validated full runs

```bash
cd Agent-Bench
export OPENAI_API_KEY=...
sbatch run_swe.sh           # or any of the scripts below
squeue -u $USER                        # watch it
tail -f logs/agentbench-*-<jobid>.out
```

### B. Interactive (salloc) — for pilots and flag iteration

```bash
# from a login node
salloc --partition=normal --nodes=1 --ntasks=1 --cpus-per-task=4 --mem=16G --time=04:00:00
srun --pty bash        # land on the compute node (check with `hostname`)

cd Agent-Bench
export OPENAI_API_KEY=sk-...           # set once, run many times
N_TASKS=1 bash run_swebench.sh
```

### Per-benchmark SLURM scripts

| Script | Benchmark | Key knobs (env-overridable) |
|---|---|---|
| `run_swebench.sh` | SWE-bench Lite (generation) | `SWE_N` (default 25) |
| `run_hotpot.sh` | HotpotQA | `HOTPOT_LIMIT` (50), `RESUME=1` |
| `run_fresh.sh` | FreshQA | `FRESHQA_LIMIT` (50), `FRESHQA_AGENT=codex-search`, `RESUME=1` |

Common knobs across all scripts: `AGENT`, `REPO_DIR`, `CONDA_ENV`. Pilot
before a full run, e.g. `SWE_N=3 sbatch run_swebench_codex.sh`.

---
### Terminal-Bench 2.0 via Harbor

Hopper's rootless setup breaks Harbor's in-container installs, so two one-time
steps are required before any run. Details + failure table: `RUNBOOK.md`.

**1. Patch Harbor** (re-run after every `pip install --upgrade harbor` — upgrades revert it):

```bash
bash ~/bin/patch_harbor_hopper.sh
```

**2. Pre-bake the task images** (runtime package installs fail on Hopper; baking installs everything ahead of time):

```bash
module load hosts/hopper apptainer/1.4.1
git clone --depth 1 https://github.com/laude-institute/terminal-bench-2.git /scratch/$USER/tb2

# all tasks (resumable):
bash prebake_harbor_sifs.sh --from-tasks /scratch/$USER/tb2

# or a subset, e.g. first 40 (the list also drives the runs):
ls -d /scratch/$USER/tb2/*/ | xargs -n1 basename | sort | grep -v '^gpt2-codegolf$' | head -40 > tasks_first40.txt
while read -r t; do grep -h '^docker_image' "/scratch/$USER/tb2/$t/task.toml"; done < tasks_first40.txt \
    | sed 's/.*= *"\(.*\)"/\1/' > images_first40.txt
bash prebake_harbor_sifs.sh $(cat images_first40.txt)
```

Tasks flagged **UNBAKEABLE** (e.g. `gpt2-codegolf`) can't run on this backend —
drop them from the list and add to `EXCLUDE_TASKS` on every submission.

**3. Run** (credentials: `OPENAI_API_KEY` for codex/openhands, `CLAUDE_CODE_OAUTH_TOKEN` for claude-code — exported env only, never on the command line):

```bash
# pilot (inside an salloc, see section B):
EXTRA_ARGS="-i llm-inference-batching-scheduler" N_TASKS=1 N_CONCURRENT=1 AGENT=claude-code \
    bash run_terminalbench.sh 2>&1 | tee logs/tbench-pilot-$(date +%s).log

# campaign — pin the task set (task order is unstable without -i) and keep it
# identical across all agents/efforts:
INC=$(sed 's/^/-i /' tasks_first40.txt | tr '\n' ' ')
for eff in low medium high; do
    EXTRA_ARGS="$INC" AGENT=codex EFFORT=$eff N_TASKS=40 N_CONCURRENT=4 \
        sbatch --time=08:00:00 --cpus-per-task=8 --mem=32G run_terminalbench.sh
done
EXTRA_ARGS="$INC" AGENT=claude-code N_TASKS=40 N_CONCURRENT=4 \
    sbatch --time=08:00:00 --cpus-per-task=8 --mem=32G run_terminalbench.sh
```

**Reading results:** success = `errored=0` in the script's trials line (`harbor
run` itself exits 0 even when trials fail; the script post-checks
`result.json`). Reward `0.000` with zero errors = agent ran but didn't solve
the task — a result, not a failure. Outputs land in
`data/harbor_jobs/<run_id>/`; codex rollouts in each trial's
`agent/sessions/.../rollout-*.jsonl` (feed to `data/parse_codex.py`). To debug
a failed trial:

```bash
J=$(ls -dt data/harbor_jobs/tbench_* | head -1)
grep -E '\[server\]|\[harbor\]|FATAL' $(find "$J" -name trial.log | head -1) | tail -30
```
## Running evaluations
WIP
### Notes

```
for HotpotQA, FreshQA and Terminal-Bench, change --agent to the one you want.
Agents are defined in configs/agents.yaml; list them with:
    python harness/run_swebench_agent.py --list-agents
On Hopper, all Codex agent rows need --skip-git-repo-check in agents.yaml.
```

---

## Accessing Agent information

### Claude

The following information is stored under data/claude (one example below):

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

### Openhands

The data is also in the data folder but under openhands instead. One example set of data is displayed below:

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

Codex statistics are stored under a separate codex folder and a script needs to be run to create a csv of the filtered data.

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
    --csv /home/czhai/Agent-Bench/data/codex/<benchmark>_<level>.csv
```

The following information is parsed by the script:

```
session_id, cli_version, turn_id, model, effort, started_at,
completed_at, duration_ms, time_to_first_token_ms, input_tokens,
cached_input_tokens, output_tokens, reasoning_output_tokens, total_tokens,
model_context_window, n_api_calls, n_tool_calls, wall_clock_s,
cache_hit_rate, context_fill, output_tokens_per_s, mean_api_gap_s
```
