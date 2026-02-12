# Discord Orchestration - Dynamic Agent System

A production-ready multi-agent orchestration system using Discord as the message bus. Spawns fresh OpenClaw agents on-demand for each task, eliminating race conditions and zombie processes.

## Overview

**Architecture:** Dynamic agent spawning (no persistent workers)
- Orchestrator polls Discord #task-queue for pending tasks
- Spawns fresh OpenClaw agent per task with isolated workspace
- Agent executes via Gateway, writes result, exits cleanly
- Orchestrator posts formatted results back to Discord
- Automatic retry logic with exponential backoff for API failures

### Why This Works

| Feature | Benefit |
|---------|---------|
| **Dynamic Spawning** | Fresh agent context for every task - no state pollution |
| **No Race Conditions** | Single orchestrator claims tasks atomically via Discord reactions |
| **No Zombie Processes** | Agents exit after completing work - no idle workers consuming resources |
| **Full Filesystem Access** | Agents can read/write anywhere on the system for real work |
| **Parallel Execution** | Multiple agents run simultaneously - no coordination overhead |
| **Automatic Retries** | Exponential backoff (2s→4s→8s→16s→32s) handles transient Discord API failures |
| **Cost Tracking** | Every result shows token usage and calculated cost |
| **Isolated Debugging** | Each agent has its own workspace and logs |

## Quick Start

### 1. Configure OpenClaw

Copy the example config and add your API keys:

```bash
cp openclaw-example.json ~/.openclaw/openclaw.json
# Edit ~/.openclaw/openclaw.json and add:
# - Your OpenRouter API key
# - Your Discord bot token
# - Any other API keys you need
```

See [openclaw-example.json](openclaw-example.json) for the full configuration structure with multiple model aliases.

### 2. Configure Discord Channels

Copy and edit the Discord config:

```bash
cp discord-config.env.example discord-config.env
# Edit discord-config.env with your:
# - Bot tokens
# - Channel IDs
# - Server (Guild) ID
```

### 3. Submit a Task

```bash
./bin/submit-to-queue.sh "Your task description here" "cheap" "low"
```

**Model aliases** (defined in your `openclaw.json`):
- `cheap` → step-3.5-flash:free (**FREE**)
- `primary` → kimi-k2..5
- `coder` → qwen3-coder-next
- `research` → gemini-3-pro-preview

### 4. Run Orchestrator

```bash
./bin/orchestrator.sh
```

This will:
- Scan #task-queue for unassigned tasks (no ✅ reaction)
- Claim tasks by adding ✅ reaction
- Spawn fresh agents for each task
- Post formatted results to #results
- Clean up agent workspaces when done

### 5. Set Up Automation (Optional)

**Cron (run every minute):**
```bash
*/1 * * * * cd /path/to/discord-orchestration && ./bin/orchestrator.sh >> /tmp/orchestrator.log 2>&1
```

Or run manually whenever you have tasks queued.

### 6. Custom Timeout (Optional)

By default, agents timeout after:
- **120 seconds** for `low` or `medium` thinking
- **300 seconds** (5 minutes) for `high` thinking

You can override this with the `TIMEOUT` environment variable:

```bash
# 10 minute timeout for all tasks
TIMEOUT=600 ./bin/orchestrator.sh

# 1 hour for extremely complex tasks
TIMEOUT=3600 ./bin/orchestrator.sh
```

**Note:** The timeout is per-agent. If you have 5 tasks, each agent gets the full timeout.

## File Structure

```
discord-orchestration/
├── bin/
│   ├── orchestrator.sh          # Main orchestrator - spawn agents
│   ├── submit-to-queue.sh       # Submit tasks to Discord
│   ├── trigger-orchestrator.sh  # Manual orchestrator trigger
│   ├── setup-discord.sh         # Initial Discord setup
│   └── ...
├── workers/                     # Agent workspaces (auto-created)
│   └── agent-<timestamp>-<random>/
│       ├── AGENTS.md           # Task instructions for agent
│       ├── TOOLS.md            # Environment-specific tools (optional)
│       └── tasks/
│           └── <task-id>/
│               ├── TASK.txt    # Task description
│               ├── RESULT.txt  # Agent output
│               └── agent-output.log  # Agent execution log
├── .runtime/                   # Orchestrator state
│   └── assigned-tasks.txt     # Tasks claimed by this orchestrator
├── openclaw-example.json      # Example OpenClaw config (redacted)
├── discord-config.env         # Your Discord bot tokens & channels
└── README.md                  # This file
```

## How It Works

### Task Flow

```
User submits task via submit-to-queue.sh
         ↓
Task appears in Discord #task-queue
         ↓
Orchestrator detects unassigned task
         ↓
Orchestrator adds ✅ reaction (atomic claim)
         ↓
Orchestrator spawns fresh agent process
         ↓
Agent writes AGENTS.md + TASK.txt in isolated workspace
         ↓
Agent executes via OpenClaw Gateway (full filesystem access)
         ↓
Agent writes RESULT.txt
         ↓
Orchestrator reads RESULT.txt
         ↓
Orchestrator posts formatted result to #results (with retry logic)
         ↓
Orchestrator cleans up workspace
         ↓
Agent process exits cleanly
```

### Retry Logic

When posting to Discord, transient failures (401, 429, 5xx) are handled automatically:

| Attempt | Delay | Total Wait |
|---------|-------|------------|
| 1 | 2s | 2s |
| 2 | 4s | 6s |
| 3 | 8s | 14s |
| 4 | 16s | 30s |
| 5 | 32s | 62s |

After 5 failures, the agent logs the error but continues cleanup.

## Discord Channels

| Channel | Purpose |
|---------|---------|
| #task-queue | Submit tasks here. Orchestrator claims tasks with ✅ reaction. |
| #results | Agent outputs posted here with full details (model, tokens, cost). |
| #worker-pool | Agent spawn/finish notices for monitoring. |

## Configuration

### OpenClaw Models

See [openclaw-example.json](openclaw-example.json) for a complete example with:
- 4 model configurations (cheap, primary, coder, research)
- Cost tracking per 1K tokens
- Model aliases mapping

**Key sections:**
- `env.OPENROUTER_API_KEY` - Your OpenRouter API key
- `models.providers.openrouter.models` - Model definitions with pricing
- `agents.defaults.models` - Alias mappings (cheap, primary, coder, research)

### Discord Config

Edit `discord-config.env`:

```bash
# Bot Tokens
ORCHESTRATOR_AGENT_TOKEN="your-main-bot-token"
WORKER1_TOKEN="your-worker-bot-token-1"
WORKER2_TOKEN="your-worker-bot-token-2"
WORKER3_TOKEN="your-worker-bot-token-3"

# Channel IDs
TASK_QUEUE_CHANNEL="1470493473038663792"
RESULTS_CHANNEL="1470494384016462107"
WORKER_POOL_CHANNEL="1470493843496501502"

# Server ID
GUILD_ID="1470491656913686786"
```

## Troubleshooting

### Orchestrator not finding tasks
- Check #task-queue has unassigned tasks (no ✅ reaction)
- Verify `discord-config.env` has correct channel IDs
- Check that your bot has "Add Reactions" permission

### Agents failing with "No result"
- Check Gateway is running: `openclaw gateway status`
- Check agent logs in `workers/agent-*/tasks/*/agent-output.log`
- Verify your OpenRouter API key is valid

### Retry messages in logs
Normal! The system automatically retries Discord API failures. Check `workers/agent-*/tasks/*/agent-output.log` for:
```
[HH:MM:SS] Discord post failed (HTTP 401), retry 1/5 in 2s...
```

### Too many agents spawning
- Orchestrator marks tasks with ✅ to prevent duplicate claims
- Check `.runtime/assigned-tasks.txt` for claimed task IDs
- Clear this file if you need to reclaim tasks (not recommended in production)

## Advanced Usage

### Parallel Execution

The orchestrator naturally handles parallel execution. Just submit multiple tasks:

```bash
./bin/submit-to-queue.sh "Task 1" "cheap" "low" &
./bin/submit-to-queue.sh "Task 2" "cheap" "low" &
./bin/submit-to-queue.sh "Task 3" "cheap" "low" &
wait
./bin/orchestrator.sh  # Spawns 3 agents in parallel
```

### Long-Running Tasks

For tasks that may take >2 minutes, increase the timeout in `orchestrator.sh`:

```bash
timeout 300 openclaw agent ...  # 5 minutes instead of 2
```

### Cost Tracking

Every result shows:
- **Tokens:** Input / Output count
- **Cost:** Calculated from your `openclaw.json` pricing
- **Model:** Which model was actually used

Cost formula: `(input_tokens × input_cost + output_tokens × output_cost) / 1000`

## Credits

Created by Derrick with his OpenClaw buddy Chip. Based on OpenClaw's agent system.

## License

MIT
