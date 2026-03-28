# Claude Session Monitor

A simple tool that monitors Claude CLI exit messages and logs session resume commands with descriptions.

## Prerequisites

- [jq](https://jqlang.github.io/jq/) - Required for JSON parsing
  ```bash
  brew install jq
  ```

## Features

- 📝 Captures all resume messages when Claude sessions end
- 💬 Prompts for session description (optional)
- 🔍 Search and list logged sessions
- 🔄 Quick resume from logged sessions
- 🔁 Automatically updates existing sessions (no duplicates)
- 📋 Preserves previous descriptions when resuming sessions

## Installation

```bash
# Make scripts executable
chmod +x claude-wrapper.sh claude-sessions.sh

# Add to your ~/.zshrc (both lines are required):
export PATH="$HOME/Documents/GitHub/claude-session-monitor:$PATH"
alias claude="claude-wrapper.sh"
```

Then reload your shell:
```bash
source ~/.zshrc
```

**Note:** Both the PATH export AND the alias are required. The alias ensures `claude` runs through the wrapper instead of the real binary.

## Usage

### Automatic Logging

Just use `claude` as normal. When a session ends with a resume message, you'll be prompted:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📝 Session ended: DB rd/wr investigation
Enter session description (or press Enter to skip): Fixed database read/write issue in auth module
✅ Session logged to ~/.claude-sessions.log
```

### Managing Sessions

```bash
# List all sessions (default command)
claude-sessions
claude-sessions list

# Show last N sessions (default: 5)
claude-sessions last
claude-sessions last 10

# Search sessions by keyword (case-insensitive)
claude-sessions search "database"

# Resume Nth most recent session (1 = most recent)
claude-sessions resume 1
claude-sessions resume 3

# Clear all logs (with confirmation)
claude-sessions clear

# Show help
claude-sessions help
```

## Configuration

Environment variables:

| Variable | Description | Default |
|----------|-------------|---------|
| `CLAUDE_SESSION_LOG` | Path to log file | `~/.claude-sessions.log` |
| `CLAUDE_PROMPT_CONTEXT` | Prompt for description | `true` |

To disable prompts:
```bash
export CLAUDE_PROMPT_CONTEXT=false
```

## Log Format

Sessions are stored in JSON format at `~/.claude-sessions.log`:

```json
[
  {
    "timestamp": "2026-02-06 15:19:30",
    "session": "DB rd/wr investigation",
    "resume_cmd": "claude --resume \"DB rd/wr investigation\"",
    "description": "Fixed database read/write issue in auth module"
  }
]
```
