# discord-sanitize Skill

A custom OpenClaw skill for sanitizing Discord messages to prevent markdown formatting issues.

## Overview

Discord's markdown parser has limitations with code blocks containing backticks. This skill provides a wrapper around the `message` tool that automatically sanitizes content before sending to Discord.

## Problem

Discord's triple-backtick code blocks (```) cannot contain triple backticks. When bash scripts or code examples contain backticks, they break Discord's formatting:

```bash
# This breaks Discord formatting
echo "```"
```

## Solution

The `discord-safe-send` tool automatically:
1. Replaces triple backticks (```) with tildes (~~~)
2. Sanitizes other problematic markdown patterns
3. Sends the sanitized message via the Discord channel

## Installation

1. Copy or symlink this skill to your OpenClaw skills directory:

```bash
# Option A: Copy
cp -r ~/Documents/GitHub/discord-orchestration/skills/discord-sanitize ~/.openclaw/skills/

# Option B: Symlink (recommended for development)
ln -s ~/Documents/GitHub/discord-orchestration/skills/discord-sanitize ~/.openclaw/skills/discord-sanitize
```

2. Restart OpenClaw or reload skills:
```bash
openclaw gateway restart
```

3. Verify installation:
```bash
openclaw skills list
```

## Usage

### Basic Usage

Replace `message` tool calls with `discord-safe-send`:

```bash
# Instead of:
message action=send to="#general" message="```bash\ncode```"

# Use:
discord-safe-send action=send to="#general" message="```bash\ncode```"
```

### Parameters

All parameters from the `message` tool are supported:

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `action` | string | Yes | `send`, `edit`, `delete`, etc. |
| `to` | string | Yes | Target channel/user |
| `message` | string | Yes | Message content (will be sanitized) |
| `channel` | string | No | Channel type (defaults to discord) |

### Supported Actions

- `send` - Send new message (sanitized)
- `edit` - Edit existing message (sanitized)
- All other actions pass through unchanged

## What Gets Sanitized

| Pattern | Replacement | Reason |
|---------|-------------|--------|
| ``` | ~~~ | Prevents code block breaking |
| `` ` `` | `` ` `` | Preserved (inline code) |
| `\n\n\n+` | `\n\n` | Collapses excessive newlines |

## Best Practices

### For Orchestrators

Add this rule to your `AGENTS.md`:

```markdown
## Discord Messaging Rule

When sending messages to Discord channels, ALWAYS use:
`discord-safe-send` instead of `message` tool

This ensures proper markdown sanitization and prevents formatting issues with code blocks containing backticks.
```

### For Workers

Workers using the DiscordOrchestration system don't need to worry about this - the orchestrator handles sanitization automatically in the result posting logic.

## Testing

Test the sanitization:

```bash
# Test with problematic content
discord-safe-send action=send to="#test" message="```bash\necho '\`\`\`'\n```"

# Should render correctly in Discord with tildes instead of backticks
```

## Troubleshooting

### Skill not appearing

```bash
# Check skills directory
ls -la ~/.openclaw/skills/

# Verify skill structure
ls -la ~/.openclaw/skills/discord-sanitize/
# Should show: SKILL.md, bin/
```

### Sanitization not working

1. Check that the tool is being called (not falling back to `message`)
2. Verify the message contains problematic patterns
3. Check OpenClaw logs for errors

## Integration with DiscordOrchestration

This skill complements the `discord-orchestration` system:

- **Orchestrator**: Automatically sanitizes worker results before posting to Discord
- **Skill**: Provides manual sanitization for orchestrator messages to Discord
- **Together**: Complete sanitization coverage for all Discord interactions

## Credits

Part of the DiscordOrchestration system for OpenClaw.
Created by Derrick with his OpenClaw buddy Chip.

## License

MIT
