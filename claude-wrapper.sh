#!/bin/bash

# Claude Session Monitor Wrapper
# Captures Claude's exit message via script() to reliably extract the session ID
# Requires Full Disk Access for the terminal app (one-time macOS setup)

PROMPT_FOR_CONTEXT="${CLAUDE_PROMPT_CONTEXT:-true}"

# Source shared functions (add_session_to_log, UUID_REGEX, etc.)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Only source function definitions, skip the case dispatcher
eval "$(sed '/^# Main command dispatcher$/,$d' "$SCRIPT_DIR/claude-sessions.sh")"

# Find the real claude binary (not this wrapper)
REAL_CLAUDE=$(which -a claude | grep -v claude-wrapper | head -1)
if [[ -z "$REAL_CLAUDE" ]]; then
    for loc in /usr/local/bin/claude "$HOME/.claude/bin/claude" "$HOME/.local/bin/claude"; do
        if [[ -x "$loc" ]]; then
            REAL_CLAUDE="$loc"
            break
        fi
    done
fi

if [[ -z "$REAL_CLAUDE" ]]; then
    echo "Error: Could not find claude binary"
    exit 1
fi

# Ensure log file exists
touch "$LOG_FILE"

TEMP_OUTPUT=$(mktemp)
trap 'rm -f "$TEMP_OUTPUT"' EXIT

# Run claude with script to capture output while preserving TTY
if [[ "$OSTYPE" == "darwin"* ]]; then
    script -q "$TEMP_OUTPUT" "$REAL_CLAUDE" "$@"
    EXIT_CODE=$?
else
    script -q -c "$(printf '%q ' "$REAL_CLAUDE" "$@")" "$TEMP_OUTPUT"
    EXIT_CODE=$?
fi

# Extract the resume value from the exit message (could be a UUID or a /rename name)
RESUME_LINE=$(grep -A1 "Resume this session with:" "$TEMP_OUTPUT" | tail -1)

RESUME_VALUE=""
if [[ -n "$RESUME_LINE" ]]; then
    CLEAN_LINE=$(echo "$RESUME_LINE" | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g' | tr -d '\r')
    RESUME_VALUE=$(echo "$CLEAN_LINE" | sed -n 's/.*--resume "\([^"]*\)".*/\1/p')
    if [[ -z "$RESUME_VALUE" ]]; then
        RESUME_VALUE=$(echo "$CLEAN_LINE" | sed -n 's/.*--resume \([^ ]*\).*/\1/p')
    fi
fi

rm -f "$TEMP_OUTPUT"
trap - EXIT

if [[ -n "$RESUME_VALUE" ]]; then
    PROJECT_KEY=$(pwd | sed 's|/|-|g')

    # Determine if RESUME_VALUE is a UUID or a display name (UUID_REGEX from claude-sessions.sh)
    if [[ "$RESUME_VALUE" =~ $UUID_REGEX ]]; then
        SESSION_ID="$RESUME_VALUE"
        SESSION_NAME=""
    else
        # It's a /rename display name — resolve to UUID via transcript customTitle
        SESSION_NAME="$RESUME_VALUE"
        SESSION_ID=""
        TRANSCRIPT_DIR="$CLAUDE_PROJECTS_DIR/$PROJECT_KEY"
        if [[ -d "$TRANSCRIPT_DIR" ]]; then
            # Batch search: single grep across all transcripts instead of per-file jq
            MATCH=$(grep -rl "\"customTitle\":\"$SESSION_NAME\"" "$TRANSCRIPT_DIR"/*.jsonl 2>/dev/null | head -1)
            if [[ -n "$MATCH" ]]; then
                SESSION_ID=$(basename "$MATCH" .jsonl)
            fi
        fi
    fi

    # If we still don't have a UUID, use the name as-is (backwards compatible)
    if [[ -z "$SESSION_ID" ]]; then
        SESSION_ID="$RESUME_VALUE"
    fi

    # Look up the project directory from Claude's history
    PROJECT_DIR=""
    if [[ -f "$CLAUDE_HISTORY" ]]; then
        PROJECT_DIR=$(jq -r --arg sid "$SESSION_ID" 'select(.sessionId == $sid) | .project // empty' "$CLAUDE_HISTORY" 2>/dev/null | head -1)
    fi

    # Update PROJECT_KEY if project dir differs from cwd
    if [[ -n "$PROJECT_DIR" ]]; then
        PROJECT_KEY=$(echo "$PROJECT_DIR" | sed 's|/|-|g')
    fi

    # Look up custom session name from transcript if not already set
    if [[ -z "$SESSION_NAME" ]]; then
        TRANSCRIPT="$CLAUDE_PROJECTS_DIR/$PROJECT_KEY/$SESSION_ID.jsonl"
        if [[ -f "$TRANSCRIPT" ]]; then
            SESSION_NAME=$(get_custom_title "$TRANSCRIPT")
        fi
    fi

    # Look up existing description (used for display and fallback)
    EXISTING_DESC=$(jq -r --arg session "$SESSION_ID" '.[] | select(.session == $session) | .description // empty' "$LOG_FILE" 2>/dev/null | head -1)

    DESCRIPTION=""

    if [[ "$PROMPT_FOR_CONTEXT" == "true" ]]; then
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        if [[ -n "$SESSION_NAME" ]]; then
            echo "📝 Session ended: $SESSION_NAME ($SESSION_ID)"
        else
            echo "📝 Session ended: $SESSION_ID"
        fi

        if [[ -n "$EXISTING_DESC" ]]; then
            echo "📋 Existing description: $EXISTING_DESC"
        fi

        read -p "Enter session description (or press Enter to skip): " DESCRIPTION
    fi

    # Preserve old description if no new one provided
    if [[ -z "$DESCRIPTION" ]] && [[ -n "$EXISTING_DESC" ]]; then
        DESCRIPTION="$EXISTING_DESC"
    fi

    # Write to log (add_session_to_log from claude-sessions.sh handles locking)
    add_session_to_log "$SESSION_ID" "$SESSION_NAME" "$PROJECT_DIR" "$DESCRIPTION"

    echo "✅ Session logged to $LOG_FILE"
fi

exit $EXIT_CODE
