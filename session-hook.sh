#!/bin/bash

# Claude Code SessionEnd hook — headless session logging
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
REASON=$(printf '%s' "$HOOK_INPUT" | jq -r '.reason // empty' 2>/dev/null)

_debug "session_id=$SESSION_ID reason=$REASON transcript_path=$TRANSCRIPT_PATH"

# Bail out if no session_id — nothing to log
if [[ -z "$SESSION_ID" ]]; then
    _debug "no session_id in payload, exiting"
    exit 0
fi

# Locate the MAIN session transcript (session_id.jsonl) for description extraction.
# SessionEnd always provides transcript_path pointing to the main transcript;
# scan all project dirs first as a belt-and-suspenders check (handles flush lag).
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

# Derive project_dir: SessionEnd payload has cwd directly — use that first.
# Fall back to history.jsonl lookup only when cwd is absent.
PROJECT_DIR=$(printf '%s' "$HOOK_INPUT" | jq -r '.cwd // empty' 2>/dev/null)
if [[ -z "$PROJECT_DIR" && -f "$CLAUDE_HISTORY" ]]; then
    PROJECT_DIR=$(jq -r --arg sid "$SESSION_ID" \
        'select(.sessionId == $sid) | .project // empty' \
        "$CLAUDE_HISTORY" 2>/dev/null | tail -1)
fi

_debug "project_dir=$PROJECT_DIR"

# Write to log
add_session_to_log "$SESSION_ID" "$SESSION_NAME" "$PROJECT_DIR" "$DESCRIPTION" 2>/dev/null || {
    _debug "add_session_to_log failed"
}

# Info-only exit banner — mirrors the wrapper's banner, printed to the controlling
# terminal so it remains visible under cmux where stdout is captured/discarded.
# Gated to prompt_input_exit (real /exit) only; skips on "other" (window-close) to
# avoid double-fire on the close+reopen+exit sequence observed under cmux.
# CLAUDE_HOOK_TTY overrides /dev/tty for test capture; set externally by tests only.
# For /dev/tty (production path) we guard with -w; for the test-seam override we
# always attempt the write (the file may not exist yet when the check runs).
_HOOK_TTY="${CLAUDE_HOOK_TTY:-/dev/tty}"
_tty_ok=false
if [[ -n "${CLAUDE_HOOK_TTY:-}" ]]; then
    _tty_ok=true  # test seam: always attempt, let the redirect swallow errors
elif ( exec >>"$_HOOK_TTY" ) 2>/dev/null; then
    _tty_ok=true
fi
if [[ "$REASON" == "prompt_input_exit" ]] && [[ "$_tty_ok" == "true" ]]; then
    C_RESET=$'\033[0m'
    C_BOLD_CYAN=$'\033[1;36m'
    C_DIM=$'\033[2m'
    C_MAGENTA=$'\033[0;35m'
    C_YELLOW=$'\033[0;33m'
    {
        printf '\n'
        printf "${C_DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}\n"
        printf "📝 Session id: ${C_BOLD_CYAN}%s${C_RESET}\n" "$SESSION_ID"
        printf "🏷️ Session alias: ${C_MAGENTA}%s${C_RESET}\n" "${SESSION_NAME:-(none)}"
        if [[ -n "$DESCRIPTION" && "$DESCRIPTION" != "$SESSION_ID" ]]; then
            printf "💬 Session description: ${C_YELLOW}%s${C_RESET}\n" "$DESCRIPTION"
        fi
        printf "${C_DIM}⚙️ cs -desc %s${C_RESET}\n" "$SESSION_ID"
    } > "$_HOOK_TTY" 2>/dev/null || true
    _debug "banner printed to $_HOOK_TTY"
else
    _debug "banner skipped (reason=$REASON tty_ok=$_tty_ok)"
fi

_debug "done"
exit 0
