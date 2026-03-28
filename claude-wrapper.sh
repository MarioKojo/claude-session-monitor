#!/bin/bash

# Claude Session Monitor Wrapper
# Logs all resume messages and session descriptions

LOG_FILE="${CLAUDE_SESSION_LOG:-$HOME/.claude-sessions.log}"
PROMPT_FOR_CONTEXT="${CLAUDE_PROMPT_CONTEXT:-true}"

# Find the real claude binary (not this wrapper)
REAL_CLAUDE=$(which -a claude | grep -v claude-wrapper | head -1)
if [[ -z "$REAL_CLAUDE" ]]; then
    # Fallback: try common locations
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
trap "rm -f $TEMP_OUTPUT" EXIT

# Run claude with script to capture output while preserving TTY
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS version of script
    script -q "$TEMP_OUTPUT" "$REAL_CLAUDE" "$@"
    EXIT_CODE=$?
else
    # Linux version
    script -q -c "$REAL_CLAUDE $*" "$TEMP_OUTPUT"
    EXIT_CODE=$?
fi

# Look for resume message in output
RESUME_LINE=$(grep -A1 "Resume this session with:" "$TEMP_OUTPUT" | tail -1)

if [[ -n "$RESUME_LINE" ]]; then
    # Extract the session name from the resume command (macOS compatible)
    SESSION_NAME=$(echo "$RESUME_LINE" | sed -n 's/.*--resume "\([^"]*\)".*/\1/p')
    
    if [[ -z "$SESSION_NAME" ]]; then
        # Try without quotes
        SESSION_NAME=$(echo "$RESUME_LINE" | sed -n 's/.*--resume \([^ ]*\).*/\1/p')
    fi
    
    # Strip ANSI escape codes and carriage returns from session name
    SESSION_NAME=$(echo "$SESSION_NAME" | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g' | tr -d '\r')
    RESUME_LINE=$(echo "$RESUME_LINE" | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g' | tr -d '\r')
    
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Try to get description
    DESCRIPTION=""
    
    if [[ "$PROMPT_FOR_CONTEXT" == "true" ]]; then
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "📝 Session ended: $SESSION_NAME"
        
        # Check if session already exists and has a description
        if [[ -s "$LOG_FILE" ]]; then
            EXISTING_DESC=$(jq -r --arg session "$SESSION_NAME" '.[] | select(.session == $session) | .description' "$LOG_FILE" 2>/dev/null | head -1)
            if [[ -n "$EXISTING_DESC" ]] && [[ "$EXISTING_DESC" != "null" ]] && [[ "$EXISTING_DESC" != "" ]]; then
                echo "📋 Descripción existente: $EXISTING_DESC"
            fi
        fi
        
        read -p "Enter session description (or press Enter to skip): " DESCRIPTION
    fi
    
    # Initialize log file as empty JSON array if it doesn't exist or is empty
    if [[ ! -s "$LOG_FILE" ]]; then
        echo '[]' > "$LOG_FILE"
    fi
    
    # Get old description if updating and no new description provided
    if [[ -z "$DESCRIPTION" ]]; then
        OLD_DESCRIPTION=$(jq -r --arg session "$SESSION_NAME" '.[] | select(.session == $session) | .description' "$LOG_FILE" 2>/dev/null | head -1)
        if [[ -n "$OLD_DESCRIPTION" ]] && [[ "$OLD_DESCRIPTION" != "null" ]]; then
            DESCRIPTION="$OLD_DESCRIPTION"
        fi
    fi
    
    # Read existing sessions, remove old entry for this session if exists
    TEMP_LOG=$(mktemp)
    jq --arg session "$SESSION_NAME" 'map(select(.session != $session))' "$LOG_FILE" > "$TEMP_LOG" 2>/dev/null || echo '[]' > "$TEMP_LOG"
    
    # Add new session entry
    jq --arg timestamp "$TIMESTAMP" \
       --arg session "$SESSION_NAME" \
       --arg resume "$RESUME_LINE" \
       --arg desc "$DESCRIPTION" \
       '. += [{timestamp: $timestamp, session: $session, resume_cmd: $resume, description: $desc}]' \
       "$TEMP_LOG" > "$LOG_FILE"
    
    rm -f "$TEMP_LOG"
    
    echo "✅ Session logged to $LOG_FILE"
fi

exit $EXIT_CODE
