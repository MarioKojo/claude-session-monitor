# Claude Session Monitor

A tool that monitors Claude CLI sessions and logs resume commands with descriptions. Uses `script(1)` to capture Claude's exit message, extracting the exact session ID for reliable logging — even with multiple concurrent sessions.

## Prerequisites

- [jq](https://jqlang.github.io/jq/) - Required for JSON parsing
  ```bash
  brew install jq
  ```
- **Full Disk Access** for your terminal app (System Settings > Privacy & Security > Full Disk Access). Required per terminal app (Warp, iTerm2, Terminal.app, etc.) because `script(1)` creates a pseudo-TTY under macOS-protected directories.

## Features

- Captures the exact session ID from Claude's exit message via `script(1)`
- Handles both UUID sessions and `/rename`d sessions (resolves names to UUIDs)
- Prompts for session description (optional)
- Tracks the project directory for each session — resumes in the correct folder
- Resume by position (most recent first) or by UUID
- Search and list logged sessions (by name, description, or UUID)
- Add unlogged sessions manually — browse current project, all projects, or by UUID
- Backup and clear with confirmation prompts
- Automatically updates existing sessions (no duplicates)
- Preserves previous descriptions when resuming sessions
- File locking for safe concurrent writes
- Short flags for all commands (`-r`, `-l`, `-s`, `-a`, `-b`)

## Installation

```bash
# Clone the repo
git clone https://github.com/MarioKojo/claude-session-monitor.git ~/claude-session-monitor

# Make scripts executable
chmod +x ~/claude-session-monitor/claude-wrapper.sh ~/claude-session-monitor/claude-sessions.sh

# Add to your ~/.zshrc (both lines are required):
export PATH="$HOME/claude-session-monitor:$PATH"
alias claude="claude-wrapper.sh"
alias cs="claude-sessions"
```

Then reload your shell:
```bash
source ~/.zshrc
```

**Note:** Both the PATH export AND the alias are required. The alias ensures `claude` runs through the wrapper instead of the real binary.

> You can clone to any directory — just update the `PATH` export to match your chosen location.

## How It Works

1. The wrapper runs Claude inside `script(1)` to capture terminal output while preserving full TTY interactivity
2. After Claude exits, it parses the "Resume this session with" message to extract the session ID
3. If the exit message contains a `/rename` name instead of a UUID, it searches session transcripts (`~/.claude/projects/`) to resolve the UUID
4. It looks up the project directory from `~/.claude/history.jsonl`
5. Everything is saved to the log file with an optional description

## Usage

### Automatic Logging

Just use `claude` as normal. When a session ends:

**New session** (no existing description) — you're prompted to describe it:
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📝 Session ended: d3d3d743-48f2-4201-a011-e07244becf2f
Enter session description (or press Enter to skip): Planning k8s 1.33 upgrade
✅ Session logged to ~/.claude-sessions.log
```

**Known session** (already has a description) — logged automatically, no prompt:
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📝 Session ended: The Ansible (e1cea1a6-bf61-4182-8d77-5e90ac438f43)
📋 Existing description: The Ansible Team configuration
⚙️  Change description: claude -desc e1cea1a6-bf61-4182-8d77-5e90ac438f43
✅ Session logged to ~/.claude-sessions.log
```

Sessions without a resume message (e.g., quick `/exit` with no interaction) are not logged.
Sessions where you press Enter without providing a description for a new session are also skipped.

### Managing Sessions

```bash
# List all sessions
cs                          # or: cs list, cs -ls

# Show last N sessions (default: 5)
cs last                     # or: cs -l
cs -l 10

# Search sessions by keyword (case-insensitive, searches name + description)
cs search "database"        # or: cs -s "database"

# Resume by position (1 = most recent) or by UUID
cs resume 1                 # or: cs -r 1
cs -r 3
cs -r a1b2c3d4-e5f6-7890-abcd-ef1234567890

# Add unlogged sessions manually
cs add                      # or: cs -a (browse current project)
cs add --scan               # browse all projects
cs add <uuid>               # add a specific session by UUID

# Update a session's description
cs desc <uuid>              # or: claude -desc <uuid>

# Move a session to a different project directory
cs move <uuid> ~/Documents/GitHub/kojo-ansible

# Archive expired sessions (no transcript = Claude cleaned them up after 30 days)
cs archive                  # moves expired sessions to ~/.claude-sessions-archive.log

# Backup and clear
cs backup                   # or: cs -b (timestamped backup)
cs clear                    # prompts for backup before clearing

# Show help
cs help                     # or: cs -h
```

`cs` is an alias for `claude-sessions`. All short flags (`-r`, `-l`, `-s`, `-ls`, `-a`, `-b`, `-h`) work interchangeably with full command names.

## Configuration

Environment variables:

| Variable | Description | Default |
|----------|-------------|---------|
| `CLAUDE_SESSION_LOG` | Path to active session log | `~/.claude-sessions.log` |
| `CLAUDE_SESSION_ARCHIVE` | Path to archive file | `~/.claude-sessions-archive.log` |
| `CLAUDE_PROMPT_CONTEXT` | Prompt for description on exit | `true` |

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
    "session": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
    "session_name": "eks upgrade",
    "resume_cmd": "claude --resume a1b2c3d4-e5f6-7890-abcd-ef1234567890",
    "description": "Planning k8s 1.33 upgrade",
    "project": "/Users/you/Documents/GitHub"
  }
]
```

| Field | Description |
|-------|-------------|
| `session` | UUID session ID (always used for `--resume`) |
| `session_name` | Display name from `/rename` (empty if not renamed) |
| `project` | Working directory where the session was started |
| `description` | User-provided description of the session |
