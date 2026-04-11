#!/bin/bash

# Claude Session Monitor Wrapper
# Captures Claude's exit message via script() to reliably extract the session ID
# Requires Full Disk Access for the terminal app (one-time macOS setup)

PROMPT_FOR_CONTEXT="${CLAUDE_PROMPT_CONTEXT:-true}"

# Source shared functions (add_session_to_log, UUID_REGEX, etc.)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Only source function definitions, skip the case dispatcher
eval "$(sed '/^# Main command dispatcher$/,$d' "$SCRIPT_DIR/claude-sessions.sh")"

# Handle description update command (intercepts before launching claude)
if [[ "$1" == "-desc" || "$1" == "--desc" ]]; then
    if [[ -z "$2" ]]; then
        echo "Usage: claude -desc <session_id>"
        exit 1
    fi
    update_session_description "$2"
    exit $?
fi

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

# Claude's TUI renders a multi-column layout whose teardown continues writing
# to the terminal after script exits. A fixed sleep is not reliable.
# Instead: wait briefly, then jump the cursor to the bottom of the terminal
# (row 9999 clips to the last visible row) and reset attributes. Our output
# then starts below all of Claude's rendering with no interleaving.
sleep 0.1
printf '\033[9999;1H\033[0m\n'

# Extract the resume value from the exit message (could be a UUID or a /rename name)
# /fork produces multiple "Resume this session with:" lines — scan all, prefer first valid UUID,
# and skip strings containing [ ] which are terminal artifact text (not real session IDs).
RESUME_VALUE=""
while IFS= read -r resume_line; do
    CLEAN=$(echo "$resume_line" | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g' | tr -d '\r')
    VAL=$(echo "$CLEAN" | sed -n 's/.*--resume "\([^"]*\)".*/\1/p')
    [[ -z "$VAL" ]] && VAL=$(echo "$CLEAN" | sed -n 's/.*--resume \([^ ]*\).*/\1/p')
    [[ -z "$VAL" ]] && continue
    [[ "$VAL" =~ [\[\]] ]] && continue          # skip terminal artifact strings
    if [[ "$VAL" =~ $UUID_REGEX ]]; then
        RESUME_VALUE="$VAL"
        break                                   # first valid UUID wins
    elif [[ -z "$RESUME_VALUE" && ${#VAL} -lt 100 ]]; then
        RESUME_VALUE="$VAL"                     # plausible /rename name as fallback
    fi
done < <(grep -A1 "Resume this session with:" "$TEMP_OUTPUT" \
         | grep -v "Resume this session with:" | grep -v "^--$")

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

    # If name resolution failed, we have no valid session ID — skip logging
    if [[ -z "$SESSION_ID" ]]; then
        [[ "$PROMPT_FOR_CONTEXT" == "true" ]] && echo "⚠️  Could not resolve session ID for: $RESUME_VALUE — skipping log."
        exit $EXIT_CODE
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

    # Always read the session name from the transcript — it reflects the latest /rename.
    # The exit message name can lag or differ; the transcript customTitle is authoritative.
    TRANSCRIPT="$CLAUDE_PROJECTS_DIR/$PROJECT_KEY/$SESSION_ID.jsonl"
    if [[ -f "$TRANSCRIPT" ]]; then
        TRANSCRIPT_NAME=$(get_custom_title "$TRANSCRIPT")
        [[ -n "$TRANSCRIPT_NAME" ]] && SESSION_NAME="$TRANSCRIPT_NAME"
    fi

    # Look up existing description and stored name (separate jq calls — avoids @tsv word-split)
    EXISTING_DESC=$(jq -r --arg s "$SESSION_ID" '.[] | select(.session == $s) | .description // empty' "$LOG_FILE" 2>/dev/null | head -1)
    STORED_NAME=$(jq -r --arg s "$SESSION_ID" '.[] | select(.session == $s) | .name // empty' "$LOG_FILE" 2>/dev/null | head -1)
    # Fall back to stored log name, then description, if transcript had no custom title
    [[ -z "$SESSION_NAME" && -n "$STORED_NAME" ]] && SESSION_NAME="$STORED_NAME"
    [[ -z "$SESSION_NAME" && -n "$EXISTING_DESC" ]] && SESSION_NAME="$EXISTING_DESC"

    # ANSI color helpers (reset after each use to stay safe in all terminals)
    C_RESET='\033[0m'
    C_BOLD_CYAN='\033[1;36m'
    C_DIM='\033[2m'
    C_GREEN='\033[0;32m'
    C_YELLOW='\033[0;33m'

    if [[ "$PROMPT_FOR_CONTEXT" == "true" ]]; then
        echo ""
        printf "${C_DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}\n"
        printf "🆔 ${C_BOLD_CYAN}%s${C_RESET}\n" "$SESSION_ID"
        printf "🏷️  ${C_DIM}%s${C_RESET}\n" "${SESSION_NAME:-(none)}"
        if [[ -n "$EXISTING_DESC" ]]; then
            printf "💬 ${C_YELLOW}%s${C_RESET}\n" "$EXISTING_DESC"
        fi
    fi

    if [[ -n "$EXISTING_DESC" ]]; then
        add_session_to_log "$SESSION_ID" "$SESSION_NAME" "$PROJECT_DIR" "$EXISTING_DESC"
        if [[ "$PROMPT_FOR_CONTEXT" == "true" ]]; then
            printf "${C_DIM}⚙️ claude -desc %s${C_RESET}\n" "$SESSION_ID"
        fi
    else
        DESCRIPTION=""
        if [[ "$PROMPT_FOR_CONTEXT" == "true" ]]; then
            read -p "Enter session description (or press Enter to skip): " DESCRIPTION
        fi
        if [[ -z "$DESCRIPTION" ]]; then
            [[ "$PROMPT_FOR_CONTEXT" == "true" ]] && printf "${C_DIM}⏭️  Not logged (no description)${C_RESET}\n"
        else
            add_session_to_log "$SESSION_ID" "$SESSION_NAME" "$PROJECT_DIR" "$DESCRIPTION"
            [[ "$PROMPT_FOR_CONTEXT" == "true" ]] && printf "${C_GREEN}✅ Logged${C_RESET}\n"
        fi
    fi
fi

exit $EXIT_CODE
