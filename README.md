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
    --max_workers 8 --report_dir .

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
    --agent-cmd "claude -p" \
    --input hotpot_dev_distractor_v1.json \
    --output data/claude/hotpot_predictions.json \
    --metrics data/claude/hotpot_metrics.jsonl \
    --limit 50 --resume            # --no-isolate to allow external tools; --stdin to pipe the prompt

# 2. Grade against the gold file
python eval/hotpot_evaluate_v1.py data/claude/hotpot_predictions.json hotpot_dev_distractor_v1.json
# optional third arg caps the number of cases scored
```

### FreshQA

```bash
# 1. Run
python harness/run_freshqa_agent.py \
    --agent-cmd "claude -p --output-format json" \
    --input freshqa.csv \
    --output data/claude/freshqa_responses.jsonl \
    --limit 50 --prompt-via arg --resume
#   --allowed-tools "..." controls which tools the agent may use (web search for FreshQA)

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
# 2. Automatically graded, results can be found using
harbor view jobs
```
---
