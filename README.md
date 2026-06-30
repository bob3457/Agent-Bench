# Agent-Bench

## Setup

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
npm install -g @anthropic-ai/claude-code   # Claude Code (requires Node.js)
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

# Codex
export OPENAI_API_KEY=...

# OpenHands (LiteLLM provider key + model)
export LLM_API_KEY=...
export LLM_MODEL=<provider/model, e.g. anthropic/claude-sonnet-4-6>
```

Confirm an agent is registered and reachable before a full run:

```bash
python run_swebench_agent.py --list-agents
```

---

## Running evaluations

All commands run from the repo root. Each benchmark is **run, then graded** as two steps.
Use a distinct `--run_id` / output path per run so you never overwrite prior results.

### SWE-bench

```bash
# 1. Run the agent over N instances -> data/<agent>/predictions.jsonl + metrics.jsonl
python harness/run_swebench_agent.py --agent claude --n 25            # add --model to override

# 2a. Grade locally (Docker)
python eval/swebench_eval.py \
    --predictions_path data/claude/predictions.jsonl \
    --dataset_name SWE-bench/SWE-bench --split test \
    --run_id claude_code_run_v2 \
    --max_workers 2 --report_dir .

# 2b. Grade on a SLURM/Apptainer cluster (e.g. Hopper, no Docker)
python eval/swebench_singularity_eval.py \
    --predictions data/claude/predictions.jsonl \
    --dataset SWE-bench/SWE-bench --split test \
    --sif-dir ./sifs --overlay-size 4096 --timeout 1800
```

The grader writes a report keyed by `run_id`; the resolved/unresolved verdicts live there,
not in the runner's output.

### HotpotQA

```bash
# 1. Run (tool-isolated by default for closed-context QA)
python harness/run_hotpot_agent.py \
    --agent claude-closedbook \ #specifically blocks searching
    --input hotpot_dev_distractor_v1.json \
    --limit 50 --resume     

# 2. Grade against the gold file
python eval/hotpot_evaluate_v1.py data/claude/hotpot_predictions.json hotpot_dev_distractor_v1.json
# optional third arg caps the number of cases scored
```

### FreshQA

```bash
# 1. Run
python harness/run_freshqa_agent.py \
    --agent claude-search \ #allows searching
    --input freshqa.csv \
    --limit 50

# 2. Grade with an LLM judge
python eval/eval_freshqa.py \
    --responses data/claude/freshqa_responses.jsonl \
    --mode both \
    --judge-cmd "claude -p" \
    --graded-out data/claude/freshqa_graded.jsonl
```
### Terminal Bench 2.0
```bash
# 1. Run
harbor run --dataset terminal-bench@2.0 \
   --agent claude-code \
   --n-concurrent 1 --n-tasks 1 --ae “CLAUDE_CODE_OAUTH_TOKEN=$CLAUDE_CODE_OAUTH_TOKEN”
OR
harbor run --dataset terminal-bench@2.0    --agent codex    --model gpt-5.5    --ak reasoning_effort=medium    --n-concurrent 1 --n-tasks 25    --ae "OPENAI_API_KEY=$OPENAI_API_KEY"
OR
harbor run -d terminal-bench@2.0 -a openhands-sdk   -m gpt-5.5   --ak reasoning_effort=medium   --ak version=1.27.0
 --ae "LLM_API_KEY=$OPENAI_API_KEY"   -e docker -l 25 -n 1 --env-file ./.env
# 2. Automatically graded, results can be found using
harbor view jobs
```

### Notes
```
for HotpotQA, freshQA and terminal bench, change --agent to the one you want \
You can find the list of agents by 
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

### Codex
Codex statistics are stored under a seperate codex folder and a script needs to be run to create a csv of the filtered data \
In order to run, first create a csv with a good name \
then, run the following code in the Agent-Bench directory \
The path to the data can be found under data/codex/ in the json file correlating to that run \
The name of the csv should be the same as the chosen name \
The following information is parsed by the script: 
```
session_id, cli_version, turn_id, model, effort, started_at,
completed_at, duration_ms, time_to_first_token_ms, input_tokens, 
cached_input_tokens, output_tokens, reasoning_output_tokens, total_tokens, 
model_context_window, n_api_calls, n_tool_calls, wall_clock_s,
cache_hit_rate, context_fill, output_tokens_per_s, mean_api_gap_s
```

```
python data/parse_codex.py /path/to/data --csv /home/czhai/Agent-Bench/data/codex/<changeName>.csv
