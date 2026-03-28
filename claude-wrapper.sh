#!/bin/bash

# Claude Session Monitor Wrapper
# Captures Claude's exit message via script() to reliably extract the session ID
# Requires Full Disk Access for the terminal app (one-time macOS setup)

LOG_FILE="${CLAUDE_SESSION_LOG:-$HOME/.claude-sessions.log}"
PROMPT_FOR_CONTEXT="${CLAUDE_PROMPT_CONTEXT:-true}"
CLAUDE_HISTORY="$HOME/.claude/history.jsonl"
CLAUDE_PROJECTS_DIR="$HOME/.claude/projects"

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

# Create a temp file to capture output
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
    # Strip ANSI escape codes and carriage returns
    CLEAN_LINE=$(echo "$RESUME_LINE" | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g' | tr -d '\r')

    # Extract value: try with quotes first, then without
    RESUME_VALUE=$(echo "$CLEAN_LINE" | sed -n 's/.*--resume "\([^"]*\)".*/\1/p')
    if [[ -z "$RESUME_VALUE" ]]; then
        RESUME_VALUE=$(echo "$CLEAN_LINE" | sed -n 's/.*--resume \([^ ]*\).*/\1/p')
    fi
fi

rm -f "$TEMP_OUTPUT"
trap - EXIT

if [[ -n "$RESUME_VALUE" ]]; then
    # Determine if RESUME_VALUE is a UUID or a display name
    UUID_REGEX='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    if [[ "$RESUME_VALUE" =~ $UUID_REGEX ]]; then
        SESSION_ID="$RESUME_VALUE"
        SESSION_NAME=""
    else
        # It's a /rename display name — resolve to UUID via history.jsonl
        SESSION_NAME="$RESUME_VALUE"
        SESSION_ID=""
        if [[ -f "$CLAUDE_HISTORY" ]]; then
            # Search history for the most recent session with this display name
            # The display field won't match, but we can find it via the transcript customTitle
            PROJECT_KEY=$(pwd | sed 's|/|-|g')
            TRANSCRIPT_DIR="$CLAUDE_PROJECTS_DIR/$PROJECT_KEY"
            if [[ -d "$TRANSCRIPT_DIR" ]]; then
                # Search transcripts for matching customTitle
                for transcript in $(ls -t "$TRANSCRIPT_DIR"/*.jsonl 2>/dev/null); do
                    TITLE=$(jq -r 'select(has("customTitle")) | .customTitle' "$transcript" 2>/dev/null | tail -1)
                    if [[ "$TITLE" == "$SESSION_NAME" ]]; then
                        SESSION_ID=$(basename "$transcript" .jsonl)
                        break
                    fi
                done
            fi
        fi
    fi

    # If we still don't have a UUID, use the name as-is (backwards compatible)
    if [[ -z "$SESSION_ID" ]]; then
        SESSION_ID="$RESUME_VALUE"
    fi

    RESUME_CMD="claude --resume $SESSION_ID"

    # Look up the project directory from Claude's history
    PROJECT_DIR=""
    if [[ -f "$CLAUDE_HISTORY" ]]; then
        PROJECT_DIR=$(jq -r --arg sid "$SESSION_ID" 'select(.sessionId == $sid) | .project' "$CLAUDE_HISTORY" 2>/dev/null | head -1)
    fi

    # If session_name wasn't set from resume value, look up customTitle from transcript
    if [[ -z "$SESSION_NAME" ]]; then
        PROJECT_KEY=$(pwd | sed 's|/|-|g')
        if [[ -n "$PROJECT_DIR" ]]; then
            PROJECT_KEY=$(echo "$PROJECT_DIR" | sed 's|/|-|g')
        fi
        TRANSCRIPT="$CLAUDE_PROJECTS_DIR/$PROJECT_KEY/$SESSION_ID.jsonl"
        if [[ -f "$TRANSCRIPT" ]]; then
            SESSION_NAME=$(jq -r 'select(has("customTitle")) | .customTitle' "$TRANSCRIPT" 2>/dev/null | tail -1)
        fi
    fi

    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

    # Ensure log file exists as JSON array
    if [[ ! -s "$LOG_FILE" ]]; then
        echo '[]' > "$LOG_FILE"
    fi

    # Try to get description
    DESCRIPTION=""

    if [[ "$PROMPT_FOR_CONTEXT" == "true" ]]; then
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        if [[ -n "$SESSION_NAME" ]]; then
            echo "📝 Session ended: $SESSION_NAME ($SESSION_ID)"
        else
            echo "📝 Session ended: $SESSION_ID"
        fi

        # Check if session already exists and has a description
        EXISTING_DESC=$(jq -r --arg session "$SESSION_ID" '.[] | select(.session == $session) | .description' "$LOG_FILE" 2>/dev/null | head -1)
        if [[ -n "$EXISTING_DESC" ]] && [[ "$EXISTING_DESC" != "null" ]] && [[ "$EXISTING_DESC" != "" ]]; then
            echo "📋 Existing description: $EXISTING_DESC"
        fi

        read -p "Enter session description (or press Enter to skip): " DESCRIPTION
    fi

    # Preserve old description if no new one provided
    if [[ -z "$DESCRIPTION" ]]; then
        OLD_DESCRIPTION=$(jq -r --arg session "$SESSION_ID" '.[] | select(.session == $session) | .description' "$LOG_FILE" 2>/dev/null | head -1)
        if [[ -n "$OLD_DESCRIPTION" ]] && [[ "$OLD_DESCRIPTION" != "null" ]]; then
            DESCRIPTION="$OLD_DESCRIPTION"
        fi
    fi

    # Remove old entry for this session, then append updated one
    # Use a lock file to prevent concurrent writes from clobbering the log
    LOCK_FILE="${LOG_FILE}.lock"
    TEMP_LOG=$(mktemp)
    trap 'rm -f "$TEMP_LOG" "$LOCK_FILE"' EXIT

    # Simple spin lock (wait up to 5 seconds)
    for i in $(seq 1 50); do
        if (set -o noclobber; echo $$ > "$LOCK_FILE") 2>/dev/null; then
            break
        fi
        sleep 0.1
    done

    jq --arg session "$SESSION_ID" 'map(select(.session != $session))' "$LOG_FILE" > "$TEMP_LOG" 2>/dev/null || echo '[]' > "$TEMP_LOG"

    jq --arg timestamp "$TIMESTAMP" \
       --arg session "$SESSION_ID" \
       --arg resume "$RESUME_CMD" \
       --arg desc "$DESCRIPTION" \
       --arg project "$PROJECT_DIR" \
       --arg name "$SESSION_NAME" \
       '. += [{timestamp: $timestamp, session: $session, session_name: $name, resume_cmd: $resume, description: $desc, project: $project}]' \
       "$TEMP_LOG" > "$LOG_FILE"

    rm -f "$TEMP_LOG" "$LOCK_FILE"
    trap - EXIT

    echo "✅ Session logged to $LOG_FILE"
fi

exit $EXIT_CODE
