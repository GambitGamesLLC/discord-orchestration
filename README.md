# Discord Orchestration

Distributed multi-agent orchestration using Discord as the message bus. Bypass OpenClaw's buggy `sessions_spawn` by using external worker processes that communicate via Discord channels.

## Overview

This system allows you to run multiple AI agent workers across different machines, coordinated through Discord. Each worker:
- Polls for tasks from a Discord channel
- Claims tasks atomically via emoji reactions (no race conditions)
- Executes tasks in isolated OpenClaw sessions
- Posts results back to Discord
- Restarts after each task for clean context

**Key Benefits:**
- ✅ No OpenClaw session lock bugs
- ✅ Clean context per task (process restart)
- ✅ Cross-machine support (anyone with Discord can run workers)
- ✅ Visible audit trail (all coordination in Discord)
- ✅ Atomic task claiming (reaction-based)

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Your Machine                         │
│  ┌─────────────────────────────────────────────────┐   │
│  │           Discord Server (e.g.,                  │   │
│  │        "OpenButter Workers")                     │   │
│  │                                                  │   │
│  │  📋 #task-queue                                 │   │
│  │     Tasks posted here (with ✅ when claimed)    │   │
│  │                                                  │   │
│  │  📊 #results                                    │   │
│  │     Completed work posted here                  │   │
│  │                                                  │   │
│  │  🔄 #worker-pool                                │   │
│  │     Worker status (READY, CLAIMED, RESTARTING)  │   │
│  └─────────────────────────────────────────────────┘   │
│                          ▲                              │
│           ┌──────────────┼──────────────┐              │
│           │              │              │               │
│     ┌─────▼────┐   ┌─────▼────┐   ┌─────▼────┐       │
│     │ Worker 1 │   │ Worker 2 │   │ Worker 3 │       │
│     │ (Your    │   │ (Cookie's│   │ (Cloud   │       │
│     │  Machine)│   │  Laptop) │   │   VPS)   │       │
│     └──────────┘   └──────────┘   └──────────┘       │
└─────────────────────────────────────────────────────────┘
```

## How It Works

### Task Lifecycle

1. **Task Submission**
   - You (or an orchestrator) posts a task to `#task-queue`
   - Format: `"Write a Python function to sort a list [model:gpt-4o] [thinking:medium]"`

2. **Task Claiming** (Atomic)
   - Workers poll `#task-queue` every few seconds
   - Worker finds a message without ✅ reaction
   - Worker attempts to add ✅ reaction
   - **If successful:** Worker claims the task (atomic operation)
   - **If failed:** Another worker got it first, skip and retry

3. **Task Execution**
   - Worker parses task description, model, thinking level
   - Worker executes task in fresh OpenClaw session
   - Worker writes result to local workspace

4. **Result Reporting**
   - Worker posts result to `#results` channel
   - Worker posts status update to `#worker-pool`
   - Worker exits (clean context)

5. **Worker Restart**
   - Worker manager detects exit, restarts worker
   - Fresh process, clean OpenClaw context
   - Worker posts "READY" to `#worker-pool`

## Quick Start

### 1. Create Discord Server

1. Open Discord → Click "+" → "Create My Own"
2. Name it (e.g., "OpenButter Workers")
3. Create channels:
   - `#task-queue` - Tasks waiting to be claimed
   - `#results` - Completed work
   - `#worker-pool` - Worker status updates

### 2. Create Discord Bots

For each worker (plus one orchestrator bot):

1. Go to [Discord Developer Portal](https://discord.com/developers/applications)
2. Click "New Application" → Name it (e.g., "Worker-1")
3. Go to "Bot" tab:
   - Click "Reset Token" and copy it
   - Enable "Public Bot" (ON)
   - Disable "Requires OAuth2 Code Grant" (OFF)
   - Enable "Message Content Intent" (ON)
4. Go to "OAuth2" → "URL Generator":
   - Select `bot` scope
   - Permissions: `Send Messages`, `Read Message History`, `Add Reactions`
   - Copy the generated URL
   - Open URL in browser and invite to your server

Repeat for each worker (Worker-1, Worker-2, Worker-3, etc.) and an orchestrator bot.

### 3. Configure Workers

```bash
cd discord-orchestration

# Run setup script
./bin/setup-discord.sh

# Enter bot tokens and channel IDs when prompted
```

This creates `discord-config.env` with your configuration.

### 4. Start Workers

On each machine that will run workers:

```bash
# Terminal 1: Start worker manager with 3 workers
./bin/worker-manager-discord-curl.sh --workers 3

# Workers will:
# - Post "READY" to #worker-pool
# - Poll #task-queue for tasks
# - Claim tasks via ✅ reaction
# - Execute and post results
# - Restart after each task
```

### 5. Submit Tasks

From any machine (or via orchestrator):

```bash
# Submit task to Discord queue
./bin/submit-to-queue.sh "Write a hello world program in Python"

# Or with specific model/thinking:
./bin/submit-to-queue.sh "Review this code" "claude-sonnet-4" "high"

# Or inline tags:
./bin/submit-to-queue.sh "Optimize this function [model:gpt-4o] [thinking:high]"
```

Watch `#worker-pool` for worker status and `#results` for completed work.

## Scripts Reference

### Primary Scripts (`bin/`)

| Script | Purpose |
|--------|---------|
| `worker-reaction.sh` | Main worker - polls Discord, claims via reactions, executes tasks |
| `worker-manager-discord-curl.sh` | Manages N workers, auto-restarts them |
| `submit-to-queue.sh` | Submit tasks to Discord #task-queue |
| `submit-to-discord.sh` | Alternative submission method |
| `setup-discord.sh` | Interactive configuration for bot tokens |
| `clear-task-queue.sh` | Delete all messages from #task-queue |
| `emergency-stop.sh` | Kill all worker processes |

### Test Scripts (`tests/`)

| Script | Purpose |
|--------|---------|
| `test-simple.sh` | Single-terminal test (start worker + submit task) |
| `test-reaction-permissions.sh` | Verify bot can add reactions |
| `debug-discord.sh` | Debug Discord API connectivity |

## Managing Workers

### Add a New Worker

1. **Create new Discord bot** (see Quick Start step 2)
   - Name it "Worker-N" (where N is next number)
   - Copy the bot token

2. **Add token to config**:
   ```bash
   # Edit discord-config.env
   echo 'WORKER4_TOKEN="your-new-token"' >> discord-config.env
   ```

3. **Start the new worker** on a machine:
   ```bash
   WORKER_ID="worker-4" \
   BOT_TOKEN="your-new-token" \
   ./bin/worker-reaction.sh
   ```

   Or use the manager:
   ```bash
   # Edit worker-manager to include worker-4
   # Then restart manager
   ```

### Remove a Worker

1. **Kill the worker process**:
   ```bash
   # Find worker PID
   pgrep -f "worker-4"
   
   # Kill it
   kill <PID>
   ```

2. **Or stop the manager** (if using manager):
   ```bash
   # Press 'q' in manager terminal
   # Or Ctrl+C
   ```

3. **Remove from config** (optional):
   ```bash
   # Edit discord-config.env and remove WORKERN_TOKEN line
   ```

### Emergency Stop (All Workers)

```bash
./bin/emergency-stop.sh
# Or manually:
pkill -f "worker-reaction"
pkill -f "worker-manager"
```

## Configuration

### Environment Variables

Create `discord-config.env` (generated by setup script):

```bash
# Bot Tokens (KEEP SECRET!)
CHIP_TOKEN="your-orchestrator-bot-token"
WORKER1_TOKEN="your-worker-1-token"
WORKER2_TOKEN="your-worker-2-token"
WORKER3_TOKEN="your-worker-3-token"

# Channel IDs (right-click channel → Copy Channel ID)
TASK_QUEUE_CHANNEL="1234567890123456789"
RESULTS_CHANNEL="1234567890123456789"
WORKER_POOL_CHANNEL="1234567890123456789"

# Server ID (right-click server name → Copy Server ID)
GUILD_ID="1234567890123456789"
```

### Worker Settings

Edit in scripts or set as environment variables:

```bash
export POLL_INTERVAL="5"        # Seconds between polls (default: 5)
export MAX_IDLE_TIME="300"      # Exit after idle seconds (default: 300)
export WORKER_ID="worker-1"     # Worker identifier
```

## Troubleshooting

### Workers not picking up tasks

1. **Check bot permissions**:
   ```bash
   ./tests/debug-discord.sh
   ```

2. **Verify channel IDs** in `discord-config.env`

3. **Check if bot is in server**:
   - Discord Server Settings → Integrations → Check bot is listed

### Rate limiting

Discord API has rate limits:
- 5 requests per second per channel
- If you see 429 errors, increase `POLL_INTERVAL`

### Task not found errors

The "Unknown Message" error is normal - it happens when:
- Another worker already claimed the task
- Message was deleted
- Race condition (harmless, worker will retry)

### Clean up stuck state

```bash
# Clear task queue
./bin/clear-task-queue.sh

# Kill all workers
./bin/emergency-stop.sh

# Remove local state
rm -rf /tmp/discord-tasks /tmp/discord-workers
```

## Architecture Details

### Why Reactions for Claiming?

- **Atomic:** Adding a reaction succeeds or fails entirely
- **No race conditions:** Only one worker can add the first reaction
- **Visible:** You can see which worker claimed which task
- **No polling conflicts:** Workers don't fight over the same task

### Why Process Restart?

OpenClaw's `sessions_spawn` has bugs:
- Session lock timeouts
- Context pollution between sub-agents
- Model override ignored

By restarting the entire process after each task:
- ✅ Clean OpenClaw context every time
- ✅ No session lock contention
- ✅ Predictable behavior

### Fallback to File Queue

If Discord API fails (network issues, rate limits), workers automatically fall back to file-based queue (`/tmp/discord-tasks/queue.txt`). This ensures reliability even when Discord is unavailable.

## Contributing

This system was built as a workaround for OpenClaw sub-agent bugs. When OpenClaw fixes `sessions_spawn`, this can serve as:
- A fallback for cross-machine coordination
- A blueprint for distributed agent systems
- An example of Discord-as-a-message-bus architecture

## License

Same as OpenClaw project.

## Credits

Built by Chip (OpenClaw agent) with guidance from Derrick.
