#!/bin/bash

# Claude Code Stop hook — headless session logging
# Receives JSON on stdin; derives description without any interactive prompts.
# Exit 0 always to avoid disrupting Claude.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${CLAUDE_SESSION_LOG:-$HOME/.claude-sessions.log}"
CLAUDE_HISTORY="$HOME/.claude/history.jsonl"
CLAUDE_PROJECTS_DIR="$HOME/.claude/projects"

# Debug log (only when DEBUG=1)
_debug() {
    [[ "${DEBUG:-0}" == "1" ]] && printf '[session-hook] %s\n' "$*" >> "${SCRIPT_DIR}/session-hook-debug.log"
}

# Source shared functions (add_session_to_log, get_custom_title, UUID_REGEX, etc.)
# Exclude the main command dispatcher so sourcing is side-effect free.
eval "$(sed '/^# Main command dispatcher$/,$d' "${SCRIPT_DIR}/claude-sessions.sh")" 2>/dev/null || {
    _debug "failed to source claude-sessions.sh"
    exit 0
}

# Read stdin
HOOK_INPUT=$(cat)

# Extract fields from hook payload
SESSION_ID=$(printf '%s' "$HOOK_INPUT" | jq -r '.session_id // empty' 2>/dev/null)
TRANSCRIPT_PATH=$(printf '%s' "$HOOK_INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)

_debug "session_id=$SESSION_ID transcript_path=$TRANSCRIPT_PATH"

# Bail out if no session_id — nothing to log
if [[ -z "$SESSION_ID" ]]; then
    _debug "no session_id in payload, exiting"
    exit 0
fi

# Always locate the MAIN session transcript (session_id.jsonl) for description extraction.
# transcript_path from the payload may point to a subagent transcript
# (e.g. .../subagents/agent-xyz.jsonl) which never contains a customTitle.
# Using the main transcript ensures /rename aliases are always found.
MAIN_TRANSCRIPT=""
for dir in "${CLAUDE_PROJECTS_DIR}"/*/; do
    if [[ -f "${dir}${SESSION_ID}.jsonl" ]]; then
        MAIN_TRANSCRIPT="${dir}${SESSION_ID}.jsonl"
        break
    fi
done

# Fall back to the payload path only when no main transcript is found yet
# (e.g. transcript not yet flushed to disk — rare but possible).
[[ -z "$MAIN_TRANSCRIPT" && -f "$TRANSCRIPT_PATH" ]] && MAIN_TRANSCRIPT="$TRANSCRIPT_PATH"

_debug "resolved main_transcript=$MAIN_TRANSCRIPT"

# Extract customTitle from main transcript now — needed for the idempotency check.
SESSION_NAME=""
if [[ -f "$MAIN_TRANSCRIPT" ]]; then
    SESSION_NAME=$(jq -r 'select(has("customTitle")) | .customTitle' \
        "$MAIN_TRANSCRIPT" 2>/dev/null | tail -1)
    _debug "customTitle from transcript: $SESSION_NAME"
fi

# Idempotency: skip only when the session is already logged AND the stored description
# already reflects the current alias (customTitle). If an alias is now available but the
# stored description predates the rename, fall through so we write the correct alias.
if [[ -s "$LOG_FILE" ]]; then
    EXISTING_DESC=$(jq -r --arg s "$SESSION_ID" \
        '.[] | select(.session == $s) | .description // empty' \
        "$LOG_FILE" 2>/dev/null | head -1)
    if [[ -n "$EXISTING_DESC" ]]; then
        # If no alias is known, any existing description is good enough — skip.
        # If an alias is known, skip only when the stored description already matches it.
        if [[ -z "$SESSION_NAME" || "$EXISTING_DESC" == "$SESSION_NAME" ]]; then
            _debug "session already logged correctly, skipping"
            exit 0
        fi
        _debug "alias changed since last log (stored='$EXISTING_DESC' alias='$SESSION_NAME'), re-logging"
    fi
fi

# Derive description (priority: customTitle > first user message > session_id)
DESCRIPTION=""

if [[ -n "$SESSION_NAME" ]]; then
    DESCRIPTION="$SESSION_NAME"
    _debug "description from customTitle: $DESCRIPTION"
elif [[ -f "$MAIN_TRANSCRIPT" ]]; then
    # Priority 2: first user message text (strip newlines, truncate)
    FIRST_MSG=$(jq -r '
        select(.type == "user" and .message != null) |
        if (.message | type) == "string" then .message
        elif (.message.content | type) == "string" then .message.content
        elif (.message.content | type) == "array" then
            (first(.message.content[] |
             select(type == "string" or .type == "text") |
             if type == "string" then . else .text end)) // empty
        else empty end
    ' "$MAIN_TRANSCRIPT" 2>/dev/null | head -1)

    if [[ -n "$FIRST_MSG" ]]; then
        # Collapse whitespace and newlines, truncate to 80 chars
        DESCRIPTION=$(printf '%s' "$FIRST_MSG" | tr '\n\r\t' ' ' | sed 's/  */ /g')
        DESCRIPTION="${DESCRIPTION:0:80}"
        _debug "description from first user message: $DESCRIPTION"
    fi
fi

# Priority 3: fall back to session_id itself
if [[ -z "$DESCRIPTION" ]]; then
    DESCRIPTION="$SESSION_ID"
    _debug "description fallback to session_id"
fi

# Look up project_dir from history.jsonl
PROJECT_DIR=""
if [[ -f "$CLAUDE_HISTORY" ]]; then
    PROJECT_DIR=$(jq -r --arg sid "$SESSION_ID" \
        'select(.sessionId == $sid) | .project // empty' \
        "$CLAUDE_HISTORY" 2>/dev/null | tail -1)
fi

_debug "project_dir=$PROJECT_DIR"

# Write to log
add_session_to_log "$SESSION_ID" "$SESSION_NAME" "$PROJECT_DIR" "$DESCRIPTION" 2>/dev/null || {
    _debug "add_session_to_log failed"
}

_debug "done"
exit 0
