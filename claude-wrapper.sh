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
        echo "Usage: cs -desc <session_id> [description]"
        exit 1
    fi
    update_session_description "$2"
    exit $?
fi

# Re-entry guard: if we're already inside the wrapper (set below before exec),
# exec the binary directly using argv[0] bypass logic won't loop back here.
if [[ -n "$_CLAUDE_WRAPPER_ACTIVE" ]]; then
    # We are being re-entered. Find a real binary via the hardcoded fallback list
    # and exec it without any further wrapping.
    for _loc in /opt/homebrew/bin/claude /usr/local/bin/claude "$HOME/.local/bin/claude" \
                "$HOME/.claude/bin/claude"; do
        if [[ -x "$_loc" ]]; then
            exec "$_loc" "$@"
        fi
    done
    echo "claude-wrapper: re-entry detected but no fallback binary found" >&2
    exit 1
fi

# Resolve the canonical path of this wrapper so we can exclude it from `which -a`.
_WRAPPER_REAL=$(realpath "$0" 2>/dev/null || readlink -f "$0" 2>/dev/null || echo "$0")

# Find the real claude binary — exclude:
#   1. This wrapper itself (by canonical path match)
#   2. Any cmux shim              (*/cmux-cli-shims/*)
#   3. cmux bundled claude paths  (*/cmux*/*/bin/claude, *cmux-claude-wrapper*, */cmux.app/*, */Contents/Resources/bin/claude)
#   4. Any path containing "claude-wrapper" (legacy guard)
REAL_CLAUDE=""
while IFS= read -r candidate; do
    [[ -z "$candidate" ]] && continue
    _cand_real=$(realpath "$candidate" 2>/dev/null || readlink -f "$candidate" 2>/dev/null || echo "$candidate")
    # Skip if same file as this wrapper
    [[ "$_cand_real" == "$_WRAPPER_REAL" ]] && continue
    # Skip cmux shims and bundled wrappers
    [[ "$candidate" == */cmux-cli-shims/* ]] && continue
    [[ "$candidate" == */cmux*/*/bin/claude ]] && continue
    [[ "$candidate" == *cmux-claude-wrapper* ]] && continue
    [[ "$candidate" == */cmux.app/* ]] && continue
    [[ "$candidate" == */Contents/Resources/bin/claude ]] && continue
    # Legacy guard
    [[ "$candidate" == *claude-wrapper* ]] && continue
    REAL_CLAUDE="$candidate"
    break
done < <(which -a claude 2>/dev/null)

if [[ -z "$REAL_CLAUDE" ]]; then
    for loc in /opt/homebrew/bin/claude /usr/local/bin/claude \
               "$HOME/.local/bin/claude" "$HOME/.claude/bin/claude"; do
        if [[ -x "$loc" ]]; then
            REAL_CLAUDE="$loc"
            break
        fi
    done
fi

if [[ -z "$REAL_CLAUDE" ]]; then
    echo "Error: Could not find claude binary" >&2
    exit 1
fi

# Safety: refuse to exec if the resolved binary is the same file as this wrapper.
_real_claude_real=$(realpath "$REAL_CLAUDE" 2>/dev/null || readlink -f "$REAL_CLAUDE" 2>/dev/null || echo "$REAL_CLAUDE")
if [[ "$_real_claude_real" == "$_WRAPPER_REAL" ]]; then
    echo "claude-wrapper: REAL_CLAUDE resolved to self ($REAL_CLAUDE) — aborting to prevent recursion" >&2
    exit 1
fi

export _CLAUDE_WRAPPER_ACTIVE=1

# Ensure log file exists
touch "$LOG_FILE"

# When resuming an existing session, skip script() wrapping entirely.
# Claude Code 2.1.120+ crashes inside a script() PTY during --resume because the
# pseudo-TTY's terminal capability profile triggers an internal code path that calls
# onSessionRestored — a hook that was removed/renamed in this version of the bundle.
# For --resume, the session ID is already known as the argument after --resume, so
# we run the binary directly and skip the output-capture step entirely. Post-session
# logging still runs using the known ID extracted from the arguments.
RESUME_VALUE=""
SKIP_SCRIPT=false
args=("$@")
for i in "${!args[@]}"; do
    if [[ "${args[$i]}" == "--resume" ]]; then
        SKIP_SCRIPT=true
        next=$((i + 1))
        RESUME_VALUE="${args[$next]}"
        break
    fi
done

if [[ "$SKIP_SCRIPT" == "true" ]]; then
    "$REAL_CLAUDE" "$@"
    EXIT_CODE=$?
    sleep 0.1
    printf '\033[9999;1H\033[0m\n'
else

TEMP_OUTPUT=$(mktemp)
trap 'rm -f "$TEMP_OUTPUT"' EXIT

# Capture start time for history.jsonl fallback (must be before script invocation)
START_EPOCH=$(date +%s)

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

# Extract the resume value from the exit message (could be a UUID or a /rename name).
# Match --resume directly on the same line to avoid fullscreen TUI escape sequences
# (e.g. \x1b[I focus events) that grep -A1 would grab instead of the UUID line.
# /fork produces multiple --resume occurrences — scan all, prefer first valid UUID,
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
done < <(grep -o -- '--resume [^[:space:]]*' "$TEMP_OUTPUT" \
         | sed 's/--resume //')

# history.jsonl fallback: if output parsing yielded nothing, look for a session
# that started at or after START_EPOCH in the current project directory.
if [[ -z "$RESUME_VALUE" && -f "$CLAUDE_HISTORY" ]]; then
    RESUME_VALUE=$(jq -r --arg proj "$(pwd)" --argjson ts "$((START_EPOCH*1000))" \
      'select(.project == $proj and .timestamp >= $ts) | .sessionId' \
      "$CLAUDE_HISTORY" 2>/dev/null | tail -1)
fi

rm -f "$TEMP_OUTPUT"
trap - EXIT

fi  # end of SKIP_SCRIPT branch

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
        PROJECT_DIR=$(jq -r --arg sid "$SESSION_ID" 'select(.sessionId == $sid) | .project // empty' "$CLAUDE_HISTORY" 2>/dev/null | tail -1)
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
    C_RESET=$'\033[0m'
    C_BOLD_CYAN=$'\033[1;36m'
    C_DIM=$'\033[2m'
    C_GREEN=$'\033[0;32m'
    C_MAGENTA=$'\033[0;35m'
    C_YELLOW=$'\033[0;33m'

    if [[ "$PROMPT_FOR_CONTEXT" == "true" ]]; then
        echo ""
        printf "${C_DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}\n"
        printf "📝 Session id: ${C_BOLD_CYAN}%s${C_RESET}\n" "$SESSION_ID"
        printf "🏷️ Session alias: ${C_MAGENTA}%s${C_RESET}\n" "${SESSION_NAME:-(none)}"
        if [[ -n "$EXISTING_DESC" ]]; then
            printf "💬 Session description: ${C_YELLOW}%s${C_RESET}\n" "$EXISTING_DESC"
        fi
    fi

    if [[ -n "$EXISTING_DESC" ]]; then
        add_session_to_log "$SESSION_ID" "$SESSION_NAME" "$PROJECT_DIR" "$EXISTING_DESC"
        if [[ "$PROMPT_FOR_CONTEXT" == "true" ]]; then
            printf "${C_DIM}⚙️ cs -desc %s${C_RESET}\n" "$SESSION_ID"
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
