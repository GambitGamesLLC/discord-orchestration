# Discord Orchestration

External worker pool system for OpenClaw, designed to bypass the native `sessions_spawn` bugs using process-based isolation with auto-restart.

## Status: ✅ PHASE 0 COMPLETE

The worker pool system is working! Workers successfully:
- Poll for tasks from a queue
- Execute tasks using OpenClaw agent
- Return results
- Exit and restart for clean context (no session bugs)

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                  Worker Pool Manager                    │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │
│  │   Worker 1   │  │   Worker 2   │  │   Worker 3   │  │
│  │  (restarts   │  │  (restarts   │  │  (restarts   │  │
│  │   per task)  │  │   per task)  │  │   per task)  │  │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘  │
│         │                  │                  │         │
│         └──────────────────┼──────────────────┘         │
│                            │                           │
│  ┌─────────────────────────┼───────────────────────┐   │
│  │      Task Queue         │                       │   │
│  │  (file-based for now,   │                       │   │
│  │   Discord later)        │                       │   │
│  └─────────────────────────┴───────────────────────┘   │
└─────────────────────────────────────────────────────────┘

Process Flow:
1. Manager starts N workers
2. Each worker polls for tasks
3. Worker claims task → executes → exits
4. Manager restarts worker (fresh context)
5. Worker posts "READY" → back to polling
```

## Quick Start

### 1. Single Worker Test

```bash
./quick-test.sh
```

Tests one worker completing a single task.

### 2. Multi-Worker Pool Test

```bash
./test-multi-worker.sh
```

Tests 3 workers processing 5 tasks in parallel.

### 3. Manual Worker Pool

```bash
# Terminal 1: Start worker manager
DISCORD_CHANNEL="my-channel" ./worker-manager.sh --workers 3

# Terminal 2: Submit tasks
./submit-task.sh "Write a Python function to calculate fibonacci numbers"
./submit-task.sh "Create a hello world JavaScript program"
./submit-task.sh "Review this code for bugs"

# Monitor results
watch -n 2 cat /tmp/discord-tasks/results.txt
```

## Files

| File | Purpose |
|------|---------|
| `worker.sh` | Individual worker that polls, executes, exits |
| `worker-manager.sh` | Manages N workers, auto-restarts them |
| `submit-task.sh` | Submit tasks to the queue |
| `quick-test.sh` | Single worker test |
| `test-multi-worker.sh` | Multi-worker parallel test |

## How It Works

### Worker Lifecycle

```
START → POLL → CLAIM → EXECUTE → REPORT → EXIT → RESTART
  │                                              │
  └──────────────────────────────────────────────┘
         (Manager restarts with fresh context)
```

**Key Points:**
- Workers **exit after each task** for clean context
- Manager **auto-restarts** workers immediately
- No `sessions_spawn` = no OpenClaw bugs
- No context accumulation
- Process-per-task isolation

### Task Queue

Currently file-based (Phase 0). Format:
```
task-id|description|model|thinking
```

Example:
```
task-1770661329|Write a hello world program|openrouter/moonshotai/kimi-k2.5|low
```

### Result Storage

Results written to `/tmp/discord-tasks/results.txt`:
```
task-id|worker-id|STATUS|timestamp|result-preview
```

## Worker Manager Commands

When running `worker-manager.sh`:
- Press **s** → Show status of all workers
- Press **q** → Quit gracefully
- Press **Ctrl+C** → Emergency stop

## Testing

### Test 1: Basic Worker
```bash
./quick-test.sh
```
Expected: ✅ SUCCESS result

### Test 2: Multiple Workers
```bash
./test-multi-worker.sh
```
Expected: 5/5 tasks completed by 3 workers

### Test 3: Interactive
```bash
# Terminal 1
DISCORD_CHANNEL="test" ./worker-manager.sh --workers 2

# Terminal 2
./submit-task.sh "Task 1"
./submit-task.sh "Task 2"
./submit-task.sh "Task 3"
```

## Next Steps (Phase 1)

### Discord Integration
- Replace file-based queue with Discord channels
- Workers read tasks from Discord messages
- Workers post results to Discord
- Orchestrator (Chip) coordinates via Discord

### Dynamic Model Selection
- Orchestrator analyzes tasks
- Selects appropriate model/thinking level
- Injects into task queue

### Worker Capabilities
- Workers register their capabilities
- Orchestrator routes tasks to matching workers
- Support for specialized workers (local models, etc.)

## Why This Works

**The Problem with OpenClaw `sessions_spawn`:**
- Session lock timeout (10s default)
- Model override ignored
- "(no output)" bug
- Context pollution between sub-agents

**Our Solution:**
- ✅ No `sessions_spawn` → No session locks
- ✅ Process exit → Clean context every task
- ✅ Manager restart → Fresh OpenClaw process
- ✅ File-based coordination → Simple, debuggable

## Configuration

Environment variables:
- `DISCORD_CHANNEL` - Channel ID (or any identifier for now)
- `WORKERS` - Number of workers (default: 3)
- `POLL_INTERVAL` - Seconds between polls (default: 5)
- `MAX_IDLE_TIME` - Exit after idle (default: 300s)
- `OPENCLAW_BIN` - Path to openclaw binary

## Troubleshooting

### Workers not starting
Check OpenClaw is installed:
```bash
openclaw --version
```

### Tasks not being claimed
Check queue file:
```bash
cat /tmp/discord-tasks/queue.txt
```

### Workers stuck
Check status:
```bash
cat /tmp/discord-tasks/status.txt
```

Kill all workers:
```bash
pkill -f worker.sh
pkill -f worker-manager.sh
```

## Migration to Discord

Current state (Phase 0):
- ✅ Workers spawn and execute
- ✅ Task queue via files
- ✅ Results via files
- ✅ Manager with auto-restart

Next (Phase 1):
- Replace file queue with Discord `#task-queue` channel
- Replace file results with Discord `#results` channel
- Add orchestrator bot that coordinates via Discord
- Workers become Discord bots that poll channels

## Credits

Built as a workaround for OpenClaw sub-agent bugs. When OpenClaw fixes `sessions_spawn`, we can migrate to native sub-agents while keeping the Discord coordination layer for cross-machine support.

## License

Same as OpenClaw project.
