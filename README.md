# Discord Orchestration

Distributed multi-agent orchestration using Discord as the message bus. This system allows you to run multiple AI agent workers across different machines, coordinated through Discord channels. It bypasses OpenClaw's buggy `sessions_spawn` by using external worker processes that communicate via Discord.

## Table of Contents

- [What This System Does](#what-this-system-does)
- [System Architecture](#system-architecture)
- [How It Works](#how-it-works)
- [Prerequisites](#prerequisites)
- [Quick Start Guide](#quick-start-guide)
- [Detailed Setup](#detailed-setup)
- [OpenClaw Configuration](#openclaw-configuration)
- [Using the System](#using-the-system)
- [Model Types and Pricing](#model-types-and-pricing)
- [Understanding Results](#understanding-results)
- [Managing Workers](#managing-workers)
- [Troubleshooting](#troubleshooting)
- [Scripts Reference](#scripts-reference)
- [Advanced Configuration](#advanced-configuration)
- [Architecture Details](#architecture-details)
- [FAQ](#faq)

---

## What This System Does

This system lets you:
- **Submit tasks** to a Discord channel
- **Have multiple workers** (on different machines) pick up and complete tasks
- **Track costs** for each task (tokens used × model pricing)
- **Get results** posted back to Discord automatically
- **Run workers anywhere** - your laptop, a cloud VPS, a friend's computer

**Key Benefits:**
- ✅ No OpenClaw session lock bugs
- ✅ Clean context per task (workers restart after each task)
- ✅ Cross-machine support (anyone with Discord can run workers)
- ✅ Visible audit trail (all coordination happens in Discord)
- ✅ Atomic task claiming (no race conditions via Discord reactions)
- ✅ Automatic cost tracking (see exact cost per task)

---

## System Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Your Machine                         │
│  ┌─────────────────────────────────────────────────┐    │
│  │           Discord Server (e.g.,                 │    │
│  │        "OpenClaw Workers")                      │    │
│  │                                                 │    │
│  │  📋 #task-queue                                 │    │
│  │     Tasks posted here (with ✅ when claimed)    │    │
│  │                                                 │    │
│  │  📊 #results                                    │    │
│  │     Completed work with tokens & cost           │    │
│  │                                                 │    │
│  │  🔄 #worker-pool                                │    │
│  │     Worker status (READY, CLAIMED, RESTARTING)  │    │
│  └─────────────────────────────────────────────────┘    │
│                          ▲                              │
│           ┌──────────────┼──────────────┐               │
│           │              │              │               │
│     ┌─────▼────┐   ┌─────▼────┐   ┌─────▼────┐          │
│     │ Worker 1 │   │ Worker 2 │   │ Worker 3 │          │
│     │ (Your    │   │ (Another │   │ (Cloud   │          │
│     │  Machine)│   │  Device) │   │   VPS)   │          │
│     └──────────┘   └──────────┘   └──────────┘          │
└─────────────────────────────────────────────────────────┘
```

### Workers Read From
- **#task-queue**: Poll for new tasks (check every 3-8 seconds)
- **Their own state**: `workers/worker-N/` directory for task files

### Workers Write To
- **#task-queue**: Add ✅ reaction when claiming a task
- **#results**: Post completed task results with tokens and cost
- **#worker-pool**: Post status updates (READY, CLAIMED, RESTARTING)
- **Local workspace**: `workers/worker-N/tasks/TASK-ID/` for files

---

## How It Works

### Task Lifecycle

```
1. SUBMIT TASK
   You post: "Calculate 25 × 4 [model:cheap] [thinking:low]"
   → Goes to #task-queue

2. WORKER CLAIMS TASK (Atomic)
   Worker-2 polls #task-queue
   Worker-2 sees message without ✅ reaction
   Worker-2 tries to add ✅ reaction
   SUCCESS → Worker-2 claims the task
   FAILURE → Another worker got it first, try next task

3. WORKER EXECUTES TASK
   Worker-2 reads task from Discord
   Worker-2 spawns OpenClaw agent with:
     - Task description
     - Model (cheap = step-3.5-flash:free)
     - Thinking level (low)
   Agent writes result to RESULT.txt

4. WORKER REPORTS RESULT
   Worker-2 extracts:
     - Tokens used (from session file)
     - Cost (calculated from pricing config)
   Worker-2 posts to #results:
     ═══════════════════════════════════════
     [SUCCESS] discord-xxx by worker-2
     Model: openrouter/stepfun/step-3.5-flash:free | Thinking: low | Tokens: 172 in / 48 out | Cost: $0.00
     Task: Calculate 25 × 4
     Result: 100
   Worker-2 posts RESTARTING to #worker-pool
   Worker-2 exits

5. WORKER RESTARTS
   Manager detects worker exit
   Manager restarts worker-2
   Fresh OpenClaw context
   Worker posts READY to #worker-pool
   Loop back to step 2
```

### Race Condition Prevention

Multiple workers polling at the same time could claim the same task. We prevent this with:

1. **Discord Reaction Atomicity**: Only one worker can add the first ✅ reaction
2. **Exponential Backoff**: If multiple workers detect each other, they back off with increasing delays
3. **Randomized Polling**: Each worker polls every 3-8 seconds (randomized), so they don't synchronize

---

## Prerequisites

Before you start, you need:

1. **A Discord account** (free)
2. **A Discord server** where you can create channels
3. **OpenClaw installed** on machines running workers
4. **Discord bot tokens** (we'll create these in setup)

---

## Quick Start Guide

### Step 1: Create Discord Server

1. Open Discord
2. Click the **+** button (left sidebar)
3. Select **"Create My Own"**
4. Name your server (e.g., "AI Workers")
5. Click **Create**

### Step 2: Create Discord Channels

In your new server, create three channels:

1. **#task-queue** (type: Text Channel)
   - Where you post tasks
2. **#results** (type: Text Channel)
   - Where workers post completed tasks
3. **#worker-pool** (type: Text Channel)
   - Where workers post status updates

### Step 3: Create Discord Bots

Each worker needs its own bot. You'll also want one for submitting tasks.

**For each bot (repeat this for Worker-1, Worker-2, etc.):**

1. Go to https://discord.com/developers/applications
2. Click **"New Application"**
3. Name it (e.g., "Worker-1")
4. Go to **"Bot"** tab (left sidebar)
5. Click **"Reset Token"** and copy the token (save it!)
6. Enable these settings:
   - **Public Bot**: ON
   - **Requires OAuth2 Code Grant**: OFF
   - **Message Content Intent**: ON (important!)
7. Go to **"OAuth2"** → **"URL Generator"**
8. Select scopes:
   - Check **bot**
9. Select bot permissions:
   - **Send Messages**
   - **Read Message History**
   - **Add Reactions**
10. Copy the generated URL at the bottom
11. Open that URL in a new browser tab
12. Select your server and click **Authorize**

**Repeat** for each worker you want to create.

### Step 4: Get Channel and Server IDs

You need the numeric IDs for your channels:

1. In Discord, go to **User Settings** (gear icon)
2. Go to **Advanced**
3. Enable **Developer Mode**: ON
4. Close settings
5. Right-click on `#task-queue` → **Copy Channel ID**
6. Save this ID
7. Repeat for `#results` and `#worker-pool`
8. Right-click your **server name** → **Copy Server ID**
9. Save this ID

### Step 5: Configure Workers

```bash
cd ~/Documents/GitHub/discord-orchestration

# Run the setup script
./bin/setup-discord.sh

# It will ask for:
# - Bot tokens (from Step 3)
# - Channel IDs (from Step 4)
# - Server ID (from Step 4)
```

This creates `discord-config.env` with all your settings.

### Step 6: Start Workers

```bash
# Start the worker manager with 3 workers
./bin/worker-manager-discord-curl.sh --workers 3

# You'll see output like:
# [MANAGER] Starting worker-1...
# [MANAGER] Starting worker-2...
# [MANAGER] Starting worker-3...
# [worker-1] [READY] Online and waiting
```

Check your Discord **#worker-pool** channel - you should see READY messages!

### Step 7: Submit a Test Task

In a new terminal:

```bash
./bin/submit-to-queue.sh "Calculate 5 × 5" "cheap" "low"
```

Watch **#results** in Discord - you should see the completed task with tokens and cost!

---

## Detailed Setup

### Understanding the Discord Config File

After running `setup-discord.sh`, you'll have `discord-config.env`:

```bash
# Bot Tokens (KEEP THESE SECRET!)
# Each worker needs its own bot token
WORKER1_TOKEN="FAKE_DISCORD_TOKEN_PLACEHOLDER"
WORKER2_TOKEN="abc123..."
WORKER3_TOKEN="xyz789..."

# Channel IDs (from Discord Developer Mode)
# These are the channels workers will use
TASK_QUEUE_CHANNEL="1234567890123456789"
RESULTS_CHANNEL="1234567890123456789"
WORKER_POOL_CHANNEL="1234567890123456789"

# Server ID (Guild ID)
GUILD_ID="1234567890123456789"
```

**Security**: Never share or commit `discord-config.env`. It contains your bot tokens.

### Adding Workers on Different Machines

You can run workers on multiple machines (your laptop, a cloud server, a friend's computer):

1. **Copy the repository** to the new machine:
   ```bash
   git clone <your-repo-url>
   cd discord-orchestration
   ```

2. **Copy the config** (securely!):
   ```bash
   # From your main machine, securely transfer discord-config.env
   # Don't use email or public channels!
   ```

3. **Start workers** on the new machine:
   ```bash
   ./bin/worker-manager-discord-curl.sh --workers 2
   ```

Now you have workers on multiple machines all coordinated through Discord!

---

## OpenClaw Configuration

Discord Orchestration requires OpenClaw with multiple model configurations. Here's how to set up your `~/.openclaw/openclaw.json` for multiple OpenRouter models with nicknames and pricing.

### Example Configuration

**⚠️ Note:** These models are examples from early 2026. You should swap them out for the best models available in your time period. Check https://openrouter.ai/models for current pricing and capabilities.

**🔒 Security Note:** Workers run with **full filesystem access** (no `--local` flag). This allows them to:
- Read/write files anywhere on the system
- Execute shell commands
- Access environment variables

**For our use case:** We want workers to have full access to get real work done efficiently.

**For your use case:** If you need sandboxed/restricted workers, modify `bin/worker-reaction.sh` to add the `--local` flag to the `openclaw agent` command:

```bash
# Change this (full access):
local AGENT_CMD="openclaw agent --session-id ${WORKER_ID}-${TASK_ID}"

# To this (sandboxed/restricted):
local AGENT_CMD="openclaw agent --session-id ${WORKER_ID}-${TASK_ID} --local"
```

**Trade-offs:**
| Mode | Access | Use Case |
|------|--------|----------|
| **No `--local`** (default) | Full filesystem | Real work, file operations, system commands |
| **`--local`** | Restricted/sandboxed | Untrusted code, security-sensitive environments |

**Recommendation:** Keep the default (full access) for personal/team use where you trust the workers. Use `--local` only if running untrusted sub-agent code.

```json
{
  "env": {
    "OPENROUTER_API_KEY": "<YOUR-OPENROUTER-KEY-HERE>"
  },
  "models": {
    "providers": {
      "openrouter": {
        "baseUrl": "https://openrouter.ai/api/v1",
        "api": "openai-completions",
        "models": [
          {
            "id": "moonshotai/kimi-k2.5",
            "name": "Kimi K2.5",
            "contextWindow": 262001,
            "maxTokens": 262001,
            "reasoning": true,
            "cost": {
              "input": 0.00045,
              "output": 0.00225,
              "cacheRead": 0.00007,
              "cacheWrite": 0.00
            }
          },
          {
            "id": "qwen/qwen3-coder-next",
            "name": "Qwen 3 Coder",
            "contextWindow": 262001,
            "maxTokens": 262001,
            "reasoning": true,
            "cost": {
              "input": 0.00015,
              "output": 0.0008,
              "cacheRead": 0.00,
              "cacheWrite": 0.00
            }
          },
          {
            "id": "stepfun/step-3.5-flash:free",
            "name": "Step 3.5 Flash (Free)",
            "contextWindow": 256000,
            "maxTokens": 256000,
            "cost": {
              "input": 0.00,
              "output": 0.00,
              "cacheRead": 0.00,
              "cacheWrite": 0.00
            }
          },
          {
            "id": "google/gemini-3-pro-preview",
            "name": "Gemini 3 Pro",
            "contextWindow": 1000005,
            "maxTokens": 65500,
            "cost": {
              "input": 0.002,
              "output": 0.012,
              "cacheRead": 0.0002,
              "cacheWrite": 0.00
            }
          }
        ]
      }
    }
  },
  "agents": {
    "defaults": {
      "thinkingDefault": "medium",
      "workspace": "~/.openclaw/workspace",
      "maxConcurrent": 4,
      "subagents": {
        "maxConcurrent": 8
      },
      "compaction": {
        "mode": "safeguard"
      },
      "model": {
        "primary": "openrouter/moonshotai/kimi-k2.5"
      }
    }
  }
}
```

### Converting OpenRouter Pricing to OpenClaw Format

**Important:** OpenClaw's cost values are **per 1,000 tokens**, but OpenRouter displays prices **per 1,000,000 tokens**.

**Conversion Formula:**
```
openclaw_cost = openrouter_price_per_1m ÷ 1000

Examples:
- OpenRouter: $0.50 per 1M input tokens
  → OpenClaw: 0.50 ÷ 1000 = 0.0005

- OpenRouter: $2.25 per 1M output tokens
  → OpenClaw: 2.25 ÷ 1000 = 0.00225

- OpenRouter: FREE ($0.00 per 1M)
  → OpenClaw: 0.00
```

**Quick Reference:**
| OpenRouter (per 1M) | OpenClaw (per 1K) |
|--------------------|-------------------|
| $0.15 | 0.00015 |
| $0.50 | 0.0005 |
| $2.25 | 0.00225 |
| $12.00 | 0.012 |
| $0.00 (FREE) | 0.00 |

### Model Aliases (Nicknames)

The Discord Orchestration system uses these model aliases (customize these to match your config):

| Alias | Full Model ID | Cost per 1K tokens |
|-------|---------------|-------------------|
| **cheap** | `stepfun/step-3.5-flash:free` | FREE |
| **primary** | `moonshotai/kimi-k2.5` | $0.00045 in / $0.00225 out |
| **coder** | `qwen/qwen3-coder-next` | $0.00015 in / $0.0008 out |
| **research** | `google/gemini-3-pro-preview` | $0.002 in / $0.012 out |

**💡 Tip:** These are just examples from early 2026. Check https://openrouter.ai/models for current best models and pricing in your time period. Update the aliases in `bin/worker-reaction.sh` to match your preferred models.

### Setup Steps

1. **Get OpenRouter API Key**: https://openrouter.ai/keys
2. **Edit config**: `openclaw config edit` or edit `~/.openclaw/openclaw.json` directly
3. **Add your API key**: Replace `<YOUR-OPENROUTER-KEY-HERE>` with your actual key
4. **Convert pricing**: Use the formula above to convert OpenRouter's per-1M pricing to OpenClaw's per-1K format
5. **Customize models**: Replace the example models with the best available models for your use case
6. **Verify config**: Run `openclaw config get` to check your configuration

**Note**: The cost tracking in Discord results reads from the `models.providers.openrouter.models[].cost` section. Make sure your pricing matches OpenRouter's current rates and uses the **per 1K token** format.

---

## Using the System

### Submitting Tasks

```bash
# Basic usage
./bin/submit-to-queue.sh "Your task here"

# With specific model
./bin/submit-to-queue.sh "Your task" "primary" "low"
#                                   ^ model  ^ thinking

# With inline tags (any order)
./bin/submit-to-queue.sh "Review this code [model:coder] [thinking:high]"
./bin/submit-to-queue.sh "[thinking:medium] Write a poem about cats [model:primary]"
```

### Task Format

You can include special tags in your task:

- `[model:MODEL]` - Request a specific model (cheap, primary, coder, research)
- `[thinking:LEVEL]` - Set thinking level (off, low, medium, high)

**Examples:**
```
Write a Python function to sort a list [model:coder] [thinking:medium]

[model:research] [thinking:high] Explain the implications of quantum computing for cryptography

Quick math: 25 × 4 [model:cheap] [thinking:low]
```

### Monitoring Workers

Watch these Discord channels:

- **#worker-pool**: See worker status (READY, CLAIMED, RESTARTING)
- **#results**: See completed tasks with tokens and cost
- **#task-queue**: See pending tasks (ones without ✅ are waiting)

---

## Model Types and Pricing

Workers can use different AI models. Each has different capabilities and costs.

### Available Models

| Alias | Full Model Name | Best For | Input Cost | Output Cost |
|-------|-----------------|----------|------------|-------------|
| **cheap** | stepfun/step-3.5-flash:free | Quick tasks, testing | **FREE** ($0.00) | **FREE** ($0.00) |
| **primary** | moonshotai/kimi-k2.5 | General-purpose work | $0.00045/1K tokens | $0.00225/1K tokens |
| **coder** | qwen/qwen3-coder-next | Code generation | $0.00015/1K tokens | $0.0008/1K tokens |
| **research** | google/gemini-3-pro-preview | Deep research, long context | $0.002/1K tokens | $0.012/1K tokens |

### Cost Calculation

**Formula:**
```
cost = (input_tokens × input_cost + output_tokens × output_cost) ÷ 1000
```

**Example with primary model:**
- Task uses 1000 input tokens and 500 output tokens
- Input cost: (1000 × $0.00045) ÷ 1000 = $0.00045
- Output cost: (500 × $0.00225) ÷ 1000 = $0.001125
- **Total: $0.001575** (about 0.16 cents)

**Pricing Notes:**
- Costs are read from `~/.openclaw/openclaw.json`
- The `cheap` model is completely FREE
- Research model is most expensive but has highest quality
- Coder model is cheapest paid option and optimized for code

---

## Understanding Results

When a task completes, you'll see this in **#results**:

```
═══════════════════════════════════════

[SUCCESS] discord-1471241464699945010 by worker-2
Model: openrouter/moonshotai/kimi-k2.5 | Thinking: low | Tokens: 180 in / 61 out | Cost: $0.000218

Task Prompt:
```
Calculate 25 × 4
```

Result:
```
25 × 4 = 100
```

📁 Workspace: `workers/worker-2/tasks/discord-1471241464699945010`
```

### Breaking Down the Format

- **═══ Separator**: Visual break between different task results
- **[SUCCESS]**: Task completed successfully (or [FAILED])
- **discord-xxx**: Unique task ID
- **by worker-2**: Which worker completed it
- **Model**: Which AI model was used
- **Thinking**: Thinking level (off/low/medium/high)
- **Tokens**: Input tokens (your prompt) / Output tokens (AI response)
- **Cost**: Total cost in dollars
- **Task Prompt**: What you asked for
- **Result**: The AI's response
- **📁 Workspace**: Where files are stored locally

### Local Files

Each task creates files in `workers/worker-N/tasks/TASK-ID/`:

```
workers/worker-2/tasks/discord-1471241464699945010/
├── AGENTS.md      # Task context for the agent
├── TASK.txt       # Task description
├── RESULT.txt     # Final result
└── agent-output.log  # Debug output
```

---

## Managing Workers

### Starting Workers

```bash
# Start 3 workers with manager
./bin/worker-manager-discord-curl.sh --workers 3

# Start specific number
./bin/worker-manager-discord-curl.sh --workers 5

# Start a single worker manually
WORKER_ID="worker-1" BOT_TOKEN="your-token" ./bin/worker-reaction.sh
```

### Stopping Workers

```bash
# Stop all workers (emergency)
./bin/emergency-stop.sh

# Stop manager (press 'q' in the manager terminal)

# Stop individual worker
kill <worker-pid>
```

### Adding More Workers

1. Create a new Discord bot (see Step 3 in Quick Start)
2. Add its token to `discord-config.env`
3. Start the new worker:
   ```bash
   WORKER_ID="worker-4" BOT_TOKEN="new-token" ./bin/worker-reaction.sh
   ```

### Worker Status Meanings

| Status | Meaning |
|--------|---------|
| **READY** | Worker is online, waiting for tasks |
| **CLAIMED** | Worker has claimed a task and is working on it |
| **RESTARTING** | Worker finished a task, restarting for clean context |
| **IDLE** | Worker timed out after 5 minutes with no tasks |

---

## Troubleshooting

### Workers Not Picking Up Tasks

**Symptoms:** Tasks sit in #task-queue with no ✅ reaction

**Check:**
1. Are workers showing as READY in #worker-pool?
2. Can workers read the #task-queue channel?
   ```bash
   ./tests/debug-discord.sh
   ```
3. Are channel IDs correct in `discord-config.env`?
4. Do bots have proper permissions?
   - Send Messages
   - Read Message History
   - Add Reactions

### Rate Limiting

**Symptoms:** Workers show 429 errors, slow response

**Fix:**
- Increase poll interval: `export POLL_INTERVAL=10`
- Discord limits: 5 requests/second per channel
- Workers automatically back off when rate limited

### Task Execution Failed

**Symptoms:** Task shows [FAILED] in #results

**Check:**
1. Look at `workers/worker-N/tasks/TASK-ID/agent-output.log`
2. Check if RESULT.txt was created
3. Verify model name is valid
4. Check OpenClaw gateway is running: `openclaw gateway status`

### Workers Keep Claiming Same Task

**Symptoms:** Multiple workers claim and complete the same task

**Fix:**
- This shouldn't happen with reaction claiming
- Check that Discord API is accessible
- Clear completed tasks from #task-queue periodically

### High Costs

**Symptoms:** Tasks are expensive

**Tips:**
- Use `cheap` model for simple tasks (try to use a FREE model!)
- Use `primary` thinking for straightforward tasks
- Use `coder` model for code (cheaper than primary)
- Save `research` for complex tasks requiring deep reasoning

---

## Scripts Reference

### Main Scripts (`bin/`)

| Script | Purpose | Example |
|--------|---------|---------|
| `worker-reaction.sh` | Core worker process | Called by manager |
| `worker-manager-discord-curl.sh` | Manages N workers, auto-restarts | `./bin/worker-manager-discord-curl.sh --workers 3` |
| `submit-to-queue.sh` | Submit task to Discord | `./bin/submit-to-queue.sh "Task" "cheap" "low"` |
| `setup-discord.sh` | Interactive setup for tokens | `./bin/setup-discord.sh` |
| `clear-task-queue.sh` | Delete all tasks from queue | `./bin/clear-task-queue.sh` |
| `emergency-stop.sh` | Kill all workers immediately | `./bin/emergency-stop.sh` |

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `POLL_INTERVAL` | 5 | Seconds between Discord polls |
| `MAX_IDLE_TIME` | 300 | Seconds before worker exits if idle |
| `WORKER_ID` | worker-unknown | Worker identifier |
| `BOT_TOKEN` | (from config) | Discord bot token |
| `OPENCLAW_STATE_DIR` | (auto) | Isolated OpenClaw state directory |

---

## Advanced Configuration

### Customizing Worker Behavior

Edit `bin/worker-reaction.sh` to change:

- **Task timeout**: Change `timeout 120` to desired seconds
- **Max idle time**: Change `MAX_IDLE_TIME` default
- **Poll interval**: Change `POLL_INTERVAL` default

### File-Based Fallback

If Discord API is unavailable, workers automatically use file-based queue:

```
.runtime/queue.txt       # Pending tasks
.runtime/claimed.txt     # Claimed tasks
.runtime/results.txt    # Local results log
```

This ensures tasks complete even if Discord is down.

### Cost Tracking Configuration

Costs are read from `~/.openclaw/openclaw.json`. To update pricing:

```bash
# Edit your OpenClaw config
openclaw config edit

# Or directly edit:
~/.openclaw/openclaw.json
```

Update the `models.providers.openrouter.models[].cost` section.

---

## Architecture Details

### Why Discord Reactions?

Discord's reaction API provides **atomic operations**:

1. Worker A checks: "No reactions yet"
2. Worker B checks: "No reactions yet"
3. Both try to add ✅ simultaneously
4. Discord guarantees only ONE succeeds
5. Winner claims the task, loser tries next task

This is called **first-reactor-wins** and prevents race conditions without complex locking.

### Why Process Restart?

OpenClaw's built-in `sessions_spawn` has known issues:
- Session locks can timeout
- Context gets polluted between tasks
- Model overrides sometimes ignored

By restarting the entire worker process after each task:
- ✅ Fresh OpenClaw session every time
- ✅ No session lock contention
- ✅ Clean, predictable behavior
- ✅ Memory leaks prevented

### Worker State Isolation

Each worker uses `OPENCLAW_STATE_DIR` to isolate its state:

```
workers/worker-1/          # Worker 1's isolated state
├── AGENTS.md              # Task context (no orchestrator identity)
├── identity/              # OpenClaw device auth
└── tasks/                 # Task outputs
    └── discord-xxx/
        ├── RESULT.txt
        └── agent-output.log
```

This prevents workers from corrupting each other's state or the main OpenClaw workspace.

---

## FAQ

**Q: Can I run workers on different machines?**
A: Yes! Workers just need Discord access. Run them on your laptop, desktop, cloud VPS, anywhere.

**Q: What happens if a worker crashes?**
A: The manager automatically restarts it. If you're not using the manager, manually restart the worker.

**Q: Can I use this with non-OpenClaw agents?**
A: The workers are designed for OpenClaw, but you could modify `execute_task()` in `worker-reaction.sh` to use other systems.

**Q: How much does this cost?**
A: The system itself is free. You only pay for AI model usage (OpenRouter API). The `cheap` model is completely free.

**Q: Can workers see my personal OpenClaw files?**
A: No. Workers use `OPENCLAW_STATE_DIR` for isolation. They can't access your main `~/.openclaw/workspace/` files.

**Q: What if Discord goes down?**
A: Workers automatically fall back to file-based queue (`runtime/queue.txt`). Tasks will still complete, just without Discord notifications.

**Q: Can I submit tasks programmatically?**
A: Yes! Just call `./bin/submit-to-queue.sh` from scripts, cron jobs, or other applications.

**Q: How do I update worker code?**
A: Pull latest changes from git, then restart workers. The manager will restart them with new code.

---

## Credits

Built by **Chip** (OpenClaw agent) with guidance from **Derrick**.

This system was created as a workaround for OpenClaw's buggy `sessions_spawn` system. It serves as:
- A production-ready distributed agent orchestration system
- A blueprint for Discord-as-a-message-bus architectures
- An example of atomic task claiming without locks

## License

Same as OpenClaw project.

---

## Getting Help

If something isn't working:

1. Check this README's Troubleshooting section
2. Look at the test scripts in `tests/`
3. Check logs in `workers/worker-N/tasks/TASK-ID/agent-output.log`
4. Review Discord channels for status messages

Remember: Workers restart automatically, so transient failures usually resolve themselves!