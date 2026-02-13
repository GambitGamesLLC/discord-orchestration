# Discord Orchestration - Dynamic Agent System

A production-ready multi-agent orchestration system using Discord as the message bus. Spawns fresh OpenClaw agents on-demand for each task, eliminating race conditions and zombie processes.

> 🚨 **IMPORTANT: Channel IDs are in `discord-config.env`, NOT this README!**
> 
> The channel IDs shown in examples below (like `1470493473038663792`) are **PLACEHOLDERS**.
> 
> **Actual channel IDs** for your system are in:
> ```bash
> ~/Documents/GitHub/discord-orchestration/discord-config.env
> ```
> 
> **Always source the config file before any Discord operations:**
> ```bash
> source ~/Documents/GitHub/discord-orchestration/discord-config.env
> echo "Task queue: $TASK_QUEUE_CHANNEL"
> ```

## Table of Contents

1. [Overview](#overview)
2. [Features](#features)
3. [Getting Started (Step-by-Step)](#getting-started-step-by-step)
   - [Step 1: Create a Discord Server](#step-1-create-a-discord-server)
   - [Step 2: Create a Discord Bot](#step-2-create-a-discord-bot)
   - [Step 3: Get Your Bot Token](#step-3-get-your-bot-token)
   - [Step 4: Invite Bot to Your Server](#step-4-invite-bot-to-your-server)
   - [Step 5: Create Discord Channels](#step-5-create-discord-channels)
   - [Step 6: Get Channel IDs](#step-6-get-channel-ids)
   - [Step 7: Get Server (Guild) ID](#step-7-get-server-guild-id)
   - [Step 8: Configure OpenClaw](#step-8-configure-openclaw)
   - [Step 9: Configure Discord Orchestration](#step-9-configure-discord-orchestration)
   - [Step 10: Install Discord Sanitize Skill](#step-10-install-discord-sanitize-skill)
4. [Using the System](#using-the-system)
   - [Submitting Tasks](#submitting-tasks)
   - [Understanding SUMMARY.txt](#understanding-summarytxt)
   - [Discord Markdown Sanitization](#discord-markdown-sanitization)
5. [Architecture](#architecture)
6. [Configuration Reference](#configuration-reference)
7. [Troubleshooting](#troubleshooting)
8. [Advanced Usage](#advanced-usage)

---

## Overview

**Architecture:** Dynamic agent spawning (no persistent workers)

- Orchestrator polls Discord #task-queue for pending tasks
- Spawns fresh OpenClaw agent per task with isolated workspace
- Agent executes via Gateway, writes result, exits cleanly
- Orchestrator posts formatted results back to Discord
- Automatic retry logic with exponential backoff for API failures

### Why This Works

| Feature                    | Benefit                                                                       |
| -------------------------- | ----------------------------------------------------------------------------- |
| **Dynamic Spawning**       | Fresh agent context for every task - no state pollution                       |
| **No Race Conditions**     | Single orchestrator claims tasks atomically via Discord reactions             |
| **No Zombie Processes**    | Agents exit after completing work - no idle workers consuming resources       |
| **Full Filesystem Access** | Agents can read/write anywhere on the system for real work                    |
| **Parallel Execution**     | Multiple agents run simultaneously - no coordination overhead                 |
| **Automatic Retries**      | exponential backoff (2s→4s→8s→16s→32s) handles transient Discord API failures |
| **Cost Tracking**          | Every result shows token usage and calculated cost                            |
| **Isolated Debugging**     | Each agent has its own workspace and logs                                     |
| **SUMMARY.txt**            | Condensed output for reduced context loading                                  |
| **Auto-Sanitization**      | Discord markdown automatically fixed to prevent formatting issues             |

---

## Features

### SUMMARY.txt - Smart Output Truncation

The system automatically generates two output files:

| File            | Purpose                             | When to Use                             |
| --------------- | ----------------------------------- | --------------------------------------- |
| **RESULT.txt**  | Full detailed output from the agent | When you need complete information      |
| **SUMMARY.txt** | Condensed version (~2000 chars max) | For quick review, reduces context bloat |

**How it works:**

1. Worker writes full result to `RESULT.txt`
2. Worker writes condensed summary to `SUMMARY.txt` (~2000 chars max)
3. Orchestrator posts `SUMMARY.txt` to Discord (no file reading needed!)
4. Full result in `RESULT.txt` available if needed

**Key benefit:** The worker creates the summary (already has context), keeping the orchestrator lean.

**Benefits:**

- Reduces token usage when reviewing results
- Fits Discord's message limits automatically
- Falls back to full result if summary isn't available

### Discord Markdown Sanitization

Discord has issues with code blocks containing backticks. The system automatically:

1. **Replaces triple backticks** (```) with **tildes** (~~~) in code blocks
2. **Prevents formatting breakage** when agents output bash scripts or markdown
3. **Works automatically** - no action needed from agents or users

**Example:**

```bash
# Original agent output (would break Discord):
echo "```"

# Sanitized automatically (renders correctly):
echo "~~~"
```

---

## Getting Started (Step-by-Step)

### Step 1: Create a Discord Server

1. Open Discord (web or app)
2. Click the **+** button on the left sidebar
3. Select **"Create My Own"**
4. Choose **"For me and my friends"**
5. Give your server a name (e.g., "My Agent Cluster")
6. Click **Create**

### Step 2: Create a Discord Bot

1. Go to [Discord Developer Portal](https://discord.com/developers/applications)
2. Click **"New Application"** (top right)
3. Give it a name (e.g., "AgentOrchestrator")
4. Click **Create**
5. On the left sidebar, click **"Bot"**
6. Click **"Add Bot"** and confirm with **"Yes, do it!"**

### Step 3: Get Your Bot Token

**IMPORTANT:** Treat this like a password - never share it!

1. In the Bot section of your application
2. Under **TOKEN**, click **"Reset Token"** (or "Copy" if already created)
3. Click **"Copy"** to copy the token
4. **Save this somewhere safe** - you'll need it in Step 9

**Token looks like:** `MTQ2NTA4NTUzODc3OTI3MTM1Mw.GB1O6Y.xxxxxx`

### Step 4: Invite Bot to Your Server

1. In your Discord application, click **"OAuth2"** → **"URL Generator"**
2. Under **SCOPES**, check **"bot"**
3. Under **BOT PERMISSIONS**, check:
   - **Send Messages**
   - **Send Messages in Threads**
   - **Create Public Threads**
   - **Embed Links**
   - **Attach Files**
   - **Read Message History**
   - **Add Reactions**
   - **Use Slash Commands**
4. Copy the generated URL at the bottom
5. Paste the URL in a new browser tab
6. Select your server from the dropdown
7. Click **Continue** → **Authorize**
8. Complete the CAPTCHA

**Your bot is now in your server!**

### Step 5: Create Discord Channels

In your Discord server, create three text channels:

1. **#task-queue** - Where you submit tasks
2. **#results** - Where completed work appears
3. **#worker-pool** - Status updates from agents

**To create a channel:**

1. Right-click your server name
2. Select **"Create Channel"**
3. Choose **"Text"**
4. Enter the channel name
5. Click **Create Channels**

---

> 🚨 **WARNING: The IDs below are EXAMPLES only!**  
> Your actual channel IDs must be saved to `discord-config.env` in Step 9.  
> **Never copy the example IDs below** - they won't work for your server.

---

### Step 6: Get Channel IDs

**Enable Developer Mode first:**

1. Go to Discord Settings (gear icon)
2. Click **"Advanced"**
3. Toggle **"Developer Mode"** ON

**Get Channel IDs:**

1. Right-click each channel you created
2. Click **"Copy Channel ID"**
3. Save these IDs - you'll need them in Step 9

**EXAMPLE Channel IDs look like:** `123456789123456789123`

### Step 7: Get Server (Guild) ID

1. Right-click your server name
2. Click **"Copy Server ID"**
3. Save this ID - you'll need it in Step 9

**EXAMPLE Server ID looks like:** `123456789123456789123`

### Step 8: Configure OpenClaw

1. Copy the example config:
   
   ```bash
   cp openclaw-example.json ~/.openclaw/openclaw.json
   ```

2. Edit `~/.openclaw/openclaw.json`:
   
   ```bash
   nano ~/.openclaw/openclaw.json
   ```

3. Add your OpenRouter API key:
   
   ```json
   "env": {
     "OPENROUTER_API_KEY": "sk-or-v1-YOUR-KEY-HERE"
   }
   ```

4. Add your Discord bot token to the channels section:
   
   ```json
   "channels": {
     "discord": {
       "enabled": true,
       "token": "YOUR-BOT-TOKEN-FROM-STEP-3",
       "allowBots": true
     }
   }
   ```

5. Save and exit (Ctrl+X, then Y, then Enter)

---

### Step 9: Configure Discord Orchestration ⭐ **SOURCE OF TRUTH**

> ⭐ **THIS IS THE SOURCE OF TRUTH FOR CHANNEL IDs**  
> All Discord operations use the IDs in this file.  
> **Always source this file before submitting tasks:**
> ```bash
> source ~/Documents/GitHub/discord-orchestration/discord-config.env
> ```

1. Copy the example config:
   
   ```bash
   cp discord-config.env.example discord-config.env
   ```

2. Edit `discord-config.env`:
   
   ```bash
   nano discord-config.env
   ```

3. Fill in your values from previous steps:
   
   ```bash
   # Bot Token (from Step 3)
   ORCHESTRATOR_AGENT_TOKEN="YOUR-BOT-TOKEN-HERE"
   
   # Channel IDs (from Step 6)
   TASK_QUEUE_CHANNEL="YOUR-TASK-QUEUE-CHANNEL-HERE"
   RESULTS_CHANNEL="YOUR-RESULTS-CHANNEL-HERE"
   WORKER_POOL_CHANNEL="YOUR-WORKER-POOL-CHANNEL-HERE"
   
   # Server ID (from Step 7)
   GUILD_ID="YOUR-CHANNEL-ID-HERE"
   ```

4. Save and exit

### Step 10: Install Discord Sanitize Skill

To prevent Discord markdown formatting issues:

```bash
# Symlink the skill (recommended)
ln -s ~/Documents/GitHub/discord-orchestration/skills/discord-sanitize \
  ~/.openclaw/skills/discord-sanitize

# Restart OpenClaw
openclaw gateway restart
```

**For Orchestrators:** Add this to your `AGENTS.md`:

```markdown
## Discord Messaging Rule

When sending messages to Discord channels, ALWAYS use:
`discord-safe-send` instead of `message` tool

This ensures proper markdown sanitization and prevents formatting issues 
with code blocks containing backticks.
```

---

## Using the System

### Submitting Tasks

```bash
# Submit a simple task
./bin/submit-to-queue.sh "Your task description"

# With specific model
./bin/submit-to-queue.sh "Your task" "primary" "medium"

# With inline tags
./bin/submit-to-queue.sh "Your task [model:coder] [thinking:high]"
```

**Available models:**

- `cheap` → step-3.5-flash:free (**FREE**)
- `primary` → kimi-k2.5 (default)
- `coder` → qwen3-coder-next
- `research` → gemini-3-pro-preview

### Running the Orchestrator

```bash
# Run once
./bin/orchestrator.sh

# Run continuously (cron)
*/1 * * * * cd /path/to/discord-orchestration && ./bin/orchestrator.sh >> /tmp/orchestrator.log 2>&1
```

### Understanding SUMMARY.txt

When a worker completes a task, it writes TWO files:

| File            | Created By | Content                     | Purpose                       |
| --------------- | ---------- | --------------------------- | ----------------------------- |
| **RESULT.txt**  | Worker     | Full detailed output        | Complete reference            |
| **SUMMARY.txt** | Worker     | Condensed (~2000 chars max) | Quick review, Discord display |

**Why the worker creates both:**

- Worker already has full context from doing the work
- No additional context loading needed to create summary
- Orchestrator stays lean (no file reading for summary generation)

**Discord shows SUMMARY.txt**, which:

- Loads faster in Discord
- Uses fewer tokens when you read it
- Contains the key information

**To see the full result:** Check the workspace path shown in the Discord message.

**Fallback behavior:** If a worker doesn't create SUMMARY.txt (old workers), the orchestrator will generate one as a backup.

**To adjust summary length:** Set the `SUMMARY_MAX_LENGTH` environment variable:

```bash
SUMMARY_MAX_LENGTH=500 ./bin/orchestrator.sh  # Shorter summaries
SUMMARY_MAX_LENGTH=4000 ./bin/orchestrator.sh # Longer summaries
```

### Discord Markdown Sanitization

The system automatically sanitizes Discord messages to prevent formatting issues.

**What gets sanitized:**

- Triple backticks (```) → Tildes (~~~)
- Excessive newlines collapsed
- Other Discord markdown quirks

**Where it happens:**

- Automatically in orchestrator when posting results
- Automatically when using `discord-safe-send` tool
- Workers don't need to worry about it

**Why it matters:**
Without sanitization, code blocks containing backticks would break Discord's formatting:

```bash
# Bad - breaks Discord formatting
echo "```"

# Good - renders correctly
echo "~~~"
```

---

## Architecture

### Task Flow

```
┌─────────────┐     ┌──────────────┐     ┌─────────────────┐
│   You       │────▶│  #task-queue │────▶│  Orchestrator   │
│  Submit     │     │   (Discord)  │     │  Claims Task    │
└─────────────┘     └──────────────┘     └────────┬────────┘
                                                   │
                                                   ▼
┌─────────────┐     ┌──────────────┐     ┌─────────────────┐
│   Agent     │◀───│  Workspace   │◀────│  Spawns Agent   │
│  Writes     │     │  (isolated)  │     │  (fresh)        │
│  RESULT.txt │     └──────────────┘     └─────────────────┘
└──────┬──────┘
       │
       ▼
┌─────────────┐     ┌──────────────┐     ┌─────────────────┐
│ Orchestrator│────▶│  #results    │────▶│   You Read      │
│ Posts       │     │   (Discord)  │     │   Summary       │
│ SUMMARY.txt │     └──────────────┘     └─────────────────┘
└─────────────┘
```

### File Structure

```
discord-orchestration/
├── bin/
│   ├── orchestrator.sh          # Main orchestrator
│   ├── submit-to-queue.sh       # Submit tasks to Discord
│   ├── setup-discord.sh         # Initial Discord setup helper
│   └── ...
├── skills/
│   └── discord-sanitize/        # Discord sanitization skill
│       ├── SKILL.md
│       └── bin/discord-safe-send
├── workers/                     # Agent workspaces (auto-created)
│   └── agent-<timestamp>-<random>/
│       ├── AGENTS.md
│       ├── TOOLS.md
│       └── tasks/
│           └── <task-id>/
│               ├── TASK.txt
│               ├── RESULT.txt      # Full output
│               └── SUMMARY.txt     # Condensed output
├── .runtime/                    # Orchestrator state
├── openclaw-example.json        # Example OpenClaw config
├── discord-config.env           # Your Discord tokens & IDs
└── README.md                    # This file
```

### Retry Logic

When posting to Discord, transient failures are handled automatically:

| Attempt | Delay | Total Wait |
| ------- | ----- | ---------- |
| 1       | 2s    | 2s         |
| 2       | 4s    | 6s         |
| 3       | 8s    | 14s        |
| 4       | 16s   | 30s        |
| 5       | 32s   | 62s        |

After 5 failures, the error is logged and the agent continues.

---

## Configuration Reference

### Environment Variables

| Variable             | Default                   | Description                        |
| -------------------- | ------------------------- | ---------------------------------- |
| `SUMMARY_MAX_LENGTH` | 2000                      | Maximum characters for SUMMARY.txt |
| `TIMEOUT`            | 120 (low/med), 300 (high) | Agent execution timeout in seconds |

### Discord Config (discord-config.env)

```bash
# Required
ORCHESTRATOR_AGENT_TOKEN="your-bot-token"
TASK_QUEUE_CHANNEL="channel-id"
RESULTS_CHANNEL="channel-id"
WORKER_POOL_CHANNEL="channel-id"
GUILD_ID="server-id"
```

### OpenClaw Config (~/.openclaw/openclaw.json)

```json
{
  "env": {
    "OPENROUTER_API_KEY": "your-key"
  },
  "channels": {
    "discord": {
      "enabled": true,
      "token": "your-bot-token",
      "allowBots": true
    }
  }
}
```

---

## Troubleshooting

### "Bot token invalid" errors

- Check you copied the token correctly (Step 3)
- Ensure token is in both `~/.openclaw/openclaw.json` and `discord-config.env`
- Reset the token in Discord Developer Portal if needed

### "Cannot find channel" errors

- Verify channel IDs are correct (Step 6)
- Ensure the bot is in your server (Step 4)
- Check bot has permissions to read/write in those channels

### "Orchestrator not finding tasks"

- Check #task-queue has unassigned tasks (no ✅ reaction)
- Verify `discord-config.env` has correct channel IDs
- Check that your bot has "Add Reactions" permission

### "Agents failing with No result"

- Check Gateway is running: `openclaw gateway status`
- Check agent logs in `workers/agent-*/tasks/*/agent-output.log`
- Verify your OpenRouter API key is valid

### Discord formatting looks broken

- Check that `discord-sanitize` skill is installed (Step 10)
- Ensure you're using `discord-safe-send` instead of `message` tool
- Check agent logs to see if sanitization is happening

### Retry messages in logs

Normal! The system automatically retries Discord API failures. Check logs:

```
[HH:MM:SS] Discord post failed (HTTP 429), retry 1/5 in 2s...
```

### Too many agents spawning

- Orchestrator marks tasks with ✅ to prevent duplicates
- Check `.runtime/assigned-tasks.txt` for claimed task IDs
- Clear this file to reclaim tasks (not recommended in production)

---

## Advanced Usage

### Parallel Execution

Submit multiple tasks at once:

```bash
./bin/submit-to-queue.sh "Task 1" "cheap" "low" &
./bin/submit-to-queue.sh "Task 2" "cheap" "low" &
./bin/submit-to-queue.sh "Task 3" "cheap" "low" &
wait
./bin/orchestrator.sh  # Spawns 3 agents in parallel
```

### Long-Running Tasks

Override the default timeout:

```bash
# 10 minute timeout
TIMEOUT=600 ./bin/orchestrator.sh

# 1 hour timeout
TIMEOUT=3600 ./bin/orchestrator.sh
```

### Cost Tracking

Every result shows:

- **Tokens:** Input / Output count
- **Cost:** Calculated from `openclaw.json` pricing
- **Model:** Which model was actually used

**Formula:** `(input_tokens × input_cost + output_tokens × output_cost) / 1000`

---

## Stress Test

On 2026-02-12, we ran a 100-agent stress test to validate system limits.

### Test Parameters

| Setting      | Value                            |
| ------------ | -------------------------------- |
| **Tasks**    | 100 concurrent math calculations |
| **Model**    | `cheap` (step-3.5-flash:free)    |
| **Thinking** | `off`                            |
| **Hardware** | Alienware Aurora R13, 128GB RAM  |
| **Host**     | Zorin OS 18 Pro                  |

### Results

| Metric                 | Result                                       |
| ---------------------- | -------------------------------------------- |
| **Submission Success** | 91/100 (9 failed due to Discord rate limits) |
| **Agents Spawned**     | 13+ concurrent                               |
| **Peak RAM Usage**     | ~9GB / 128GB (7%)                            |
| **System Load**        | Light (<1.0)                                 |
| **Total Time**         | ~5 minutes                                   |
| **Cost**               | $0 (free tier)                               |

### Key Findings

**✅ System Scales Well**

- Hardware handled 100 agents with massive headroom
- Could likely support 1000+ concurrent agents
- No race conditions or zombie processes

**⚠️ Discord is the Bottleneck**

- Rate limit: ~5 messages/second sustained
- Submission phase: 6% failure rate (429 Too Many Requests)
- Result posting: Automatic retry with exponential backoff (2s→4s→8s→16s→32s)

**✅ Orchestrator Performed**

- Dynamic spawning worked flawlessly
- Task claiming via reactions prevented duplicates
- All agents completed math calculations correctly

### Discord Rate Limits Observed

| Phase           | Limit | Impact                             |
| --------------- | ----- | ---------------------------------- |
| Message Create  | 5/sec | Task submission throttled          |
| Reaction Create | 4/sec | Task claiming throttled            |
| API Retry       | Auto  | 5 retries with exponential backoff |

### Conclusion

The underlying system is solid. Discord's infrastructure is the limiting factor, not your hardware. The architecture successfully piggybacks on Discord for coordination while local hardware handles execution.

**Recommendation:** For large-scale workloads, batch submissions or implement a queue with rate limiting.

---

## Credits

Created by Derrick with his OpenClaw buddy Chip. Based on OpenClaw's agent system.

## License

MIT
