# Discord Orchestration - Dynamic Agent System

## Overview

**Architecture:** Dynamic agent spawning (no persistent workers)
- Orchestrator polls #task-queue
- Spawns fresh OpenClaw agent per task
- Agent executes, posts result, exits cleanly
- No race conditions, no zombie processes

## Quick Start

### 1. Submit a Task
```bash
./bin/submit-to-queue.sh "Your task here" "cheap" "low"
```

**Model aliases:**
- `cheap` → step-3.5-flash:free (FREE)
- `primary` → kimi-k2.5
- `coder` → qwen3-coder-next
- `research` → gemini-3-pro-preview

### 2. Run Orchestrator
```bash
./bin/orchestrator-dynamic.sh
```

This will:
- Scan #task-queue for unassigned tasks
- Spawn fresh agents for each task
- Post results to #results
- Clean up when done

### 3. Set Up Automation (Optional)

**Cron (run every minute):**
```bash
*/1 * * * * cd /path/to/discord-orchestration && ./bin/orchestrator-dynamic.sh >> /tmp/orchestrator.log 2>&1
```

## File Structure

```
discord-orchestration/
├── bin/
│   ├── orchestrator-dynamic.sh    # Main orchestrator
│   ├── submit-to-queue.sh         # Submit tasks
│   ├── trigger-orchestrator.sh    # Manual trigger
│   └── ...
├── workers/                        # Agent workspaces (auto-created)
│   └── agent-<timestamp>-<random>/
│       ├── AGENTS.md              # Task instructions
│       ├── TOOLS.md               # Environment tools (optional)
│       └── tasks/
│           └── <task-id>/
│               ├── TASK.txt       # Task description
│               └── RESULT.txt     # Agent output
├── .runtime/                       # State tracking
│   └── assigned-tasks.txt         # Tasks we've claimed
└── archive/                        # Legacy files
```

## How It Works

### Task Flow

```
User submits task → #task-queue
         ↓
Orchestrator detects unassigned task
         ↓
Marks with ✅ reaction (claims it)
         ↓
Spawns fresh agent process
         ↓
Agent writes AGENTS.md + TASK.txt
         ↓
Agent runs via OpenClaw Gateway
         ↓
Agent writes RESULT.txt
         ↓
Orchestrator posts to #results
         ↓
Cleans up workspace
```

### Why This Works Better

| Problem (Old) | Solution (New) |
|--------------|----------------|
| Race conditions | Single orchestrator decides |
| Zombie workers | Fresh agent per task, exits cleanly |
| Complex caching | Simple state file |
| Hard to debug | Isolated agent workspaces |
| Coordination overhead | No worker coordination needed |

## Discord Channels

| Channel | Purpose |
|---------|---------|
| #task-queue | Submit tasks here |
| #results | Agent outputs posted here |
| #worker-pool | Agent spawn/finish notices |

## Configuration

Edit `discord-config.env`:
```bash
CHIP_TOKEN="your-bot-token"
TASK_QUEUE_CHANNEL="..."
RESULTS_CHANNEL="..."
WORKER_POOL_CHANNEL="..."
GUILD_ID="..."
```

## Troubleshooting

### Orchestrator not finding tasks
- Check #task-queue has unassigned tasks (no ✅ reaction)
- Verify `discord-config.env` has correct channel IDs

### Agents failing with "No result"
- Check Gateway is running: `openclaw gateway status`
- Check agent logs in `workers/agent-*/agent-output.log`

### Too many agents spawned
- Orchestrator marks tasks with ✅ to prevent duplicates
- Check `.runtime/assigned-tasks.txt` for claimed tasks

## Migration from Old System

**Old:** 3 persistent workers polling 24/7
**New:** Orchestrator spawns agents on demand

**No changes needed for:**
- Task submission (same `submit-to-queue.sh`)
- Discord channels (same structure)
- Agent capabilities (full filesystem access)

**Removed:**
- `worker-reaction.sh` (archived)
- `worker-manager.sh` (archived)
- Persistent worker pools

## License

Same as parent project.
