#!/bin/bash

# Claude Sessions Manager
# View and manage logged Claude sessions

LOG_FILE="${CLAUDE_SESSION_LOG:-$HOME/.claude-sessions.log}"
CLAUDE_PROJECTS_DIR="$HOME/.claude/projects"
CLAUDE_HISTORY="$HOME/.claude/history.jsonl"

# Shared jq format for displaying a session entry
SESSION_FMT='"━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\nTimestamp: \(.timestamp)" + (if (.session_name // "") != "" then "\nName: \(.session_name)" else "" end) + "\nSession: \(.session)\nResume cmd: \(.resume_cmd)" + (if (.project // "") != "" then "\nProject: \(.project)" else "" end) + (if (.description // "") != "" then "\nDescription: \(.description)" else "" end) + "\n"'

UUID_REGEX='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

get_custom_title() {
    jq -r 'select(has("customTitle")) | .customTitle' "$1" 2>/dev/null | tail -1
}

show_help() {
    cat << EOF
Claude Sessions Manager

Usage: claude-sessions [command]

Commands:
    list, ls, -ls    List all logged sessions
    last, -l [n]     Show last n sessions (default: 5)
    search, -s <q>   Search sessions by keyword
    resume, -r <n|uuid>  Resume by position (1 = most recent) or session UUID
    add, -a [id]     Add session manually (browse unlogged or by UUID)
    add --scan       Browse unlogged sessions across all projects
    desc <session_id>  Update description for a session (also: claude -desc <id>)
    backup, -b       Backup sessions to timestamped file
    clear            Clear all logged sessions (prompts for backup)
    help, -h         Show this help message

Environment:
    CLAUDE_SESSION_LOG   Path to log file (default: ~/.claude-sessions.log)
EOF
}

no_sessions() {
    [[ ! -f "$LOG_FILE" ]] || [[ ! -s "$LOG_FILE" ]]
}

list_sessions() {
    if no_sessions; then
        echo "No sessions logged yet."
        return
    fi
    jq -r ".[] | $SESSION_FMT" "$LOG_FILE"
}

last_sessions() {
    local count=${1:-5}
    if no_sessions; then
        echo "No sessions logged yet."
        return
    fi
    jq -r --argjson count "$count" ".[-\$count:] | to_entries | .[] | \"[\(.key + 1)] \" + (.value | $SESSION_FMT)" "$LOG_FILE"
}

search_sessions() {
    local query="$1"
    if [[ -z "$query" ]]; then
        echo "Usage: claude-sessions search <keyword>"
        return 1
    fi
    if no_sessions; then
        echo "No sessions logged yet."
        return
    fi
    local results
    results=$(jq -r --arg q "$query" ".[] | select((.session + (.session_name // \"\") + (.description // \"\") + .resume_cmd) | ascii_downcase | contains(\$q | ascii_downcase)) | $SESSION_FMT" "$LOG_FILE")
    if [[ -z "$results" ]]; then
        echo "No matches found."
    else
        echo "$results"
    fi
}

resume_session() {
    local arg="${1:-1}"
    if no_sessions; then
        echo "No sessions logged yet."
        return 1
    fi

    local session_data
    if [[ "$arg" =~ $UUID_REGEX ]]; then
        # Resume by UUID
        session_data=$(jq -r --arg sid "$arg" '.[] | select(.session == $sid) | [.session, .session_name // "", .project // ""] | @tsv' "$LOG_FILE" | tail -1)
    else
        # Resume by position (1 = most recent)
        session_data=$(jq -r --argjson n "$arg" '.[-$n] | [.session, .session_name // "", .project // ""] | @tsv' "$LOG_FILE")
    fi

    local session_id display_name project_dir
    session_id=$(echo "$session_data" | cut -f1)
    display_name=$(echo "$session_data" | cut -f2)
    project_dir=$(echo "$session_data" | cut -f3)

    if [[ -z "$session_id" ]] || [[ "$session_id" == "null" ]]; then
        if [[ "$arg" =~ $UUID_REGEX ]]; then
            echo "Session $arg not found in log."
        else
            echo "No session at position $arg. Use 'cs last' to see available sessions."
        fi
        return 1
    fi

    local label="${display_name:-$session_id}"

    if [[ -n "$project_dir" ]] && [[ -d "$project_dir" ]]; then
        echo "Resuming session: $label (in $project_dir)"
        cd "$project_dir" || { echo "Failed to cd to $project_dir"; return 1; }
    else
        echo "Resuming session: $label"
    fi

    # Use wrapper if available, otherwise fall back to claude
    if command -v claude-wrapper.sh &> /dev/null; then
        claude-wrapper.sh --resume "$session_id"
    else
        claude --resume "$session_id"
    fi
}

get_session_preview() {
    local transcript="$1"
    local project_lookup="$2"  # optional: pre-built "sid<TAB>project" TSV file
    local sid=$(basename "$transcript" .jsonl)

    # Single jq pass: extract customTitle, first non-caveat user message, and timestamp
    # Replaces 3-4 separate jq invocations that each re-parsed the entire transcript
    local extracted
    extracted=$(jq -r --slurp '
        def extract_msg:
            if (.message | type) == "string" then .message[:80]
            elif (.message.content | type) == "string" then .message.content[:80]
            elif (.message.content | type) == "array" then
                (first(.message.content[] | select(type == "string" or .type == "text") |
                if type == "string" then .[:80] else .text[:80] end)) // null
            else null end;
        def strip_tags: gsub("<[^>]*>"; "") | gsub("\\\\n"; " ") | gsub("^ +"; "");
        def is_noise: startswith("Caveat:") or startswith("/") or startswith("[Request interrupted") or (length < 20);
        ((last(.[] | select(has("customTitle"))) | .customTitle) // "") as $title |
        ((first(.[] | select(.type == "user" and .message != null) |
            extract_msg // empty | strip_tags |
            select(is_noise | not) | select(length > 3))) // "") as $msg |
        ((first(.[] | select(.type == "user" and .timestamp != null) | .timestamp) // "")) as $ts |
        [$title, $msg, ($ts | gsub("T"; " ") | gsub("\\.[0-9]+.*"; ""))] | @tsv
    ' "$transcript" 2>/dev/null) || return 1

    local title first_msg date_str
    title=$(printf '%s' "$extracted" | cut -f1)
    first_msg=$(printf '%s' "$extracted" | cut -f2)
    date_str=$(printf '%s' "$extracted" | cut -f3)

    # Look up project_dir from pre-built map (avoids re-scanning history.jsonl per transcript)
    local project_dir=""
    if [[ -n "$project_lookup" && -f "$project_lookup" ]]; then
        project_dir=$(grep "^${sid}	" "$project_lookup" 2>/dev/null | cut -f2 | head -1)
    elif [[ -f "$CLAUDE_HISTORY" ]]; then
        project_dir=$(jq -r --arg sid "$sid" 'select(.sessionId == $sid) | .project // empty' "$CLAUDE_HISTORY" 2>/dev/null | head -1)
    fi

    local label="${title:-$first_msg}"
    [[ -z "$label" ]] && return 1
    echo "${date_str}|${sid}|${title}|${label:0:70}|${project_dir}"
}

add_session_to_log() {
    local session_id="$1" session_name="$2" project_dir="$3" description="$4"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local resume_cmd="claude --resume $session_id"

    if [[ ! -s "$LOG_FILE" ]]; then
        echo '[]' > "$LOG_FILE"
    fi

    local lock_file="${LOG_FILE}.lock"
    local temp_log=$(mktemp)

    # Simple spin lock (wait up to 5 seconds)
    for i in $(seq 1 50); do
        if (set -o noclobber; echo $$ > "$lock_file") 2>/dev/null; then
            break
        fi
        sleep 0.1
    done

    jq --arg session "$session_id" 'map(select(.session != $session))' "$LOG_FILE" > "$temp_log" 2>/dev/null || echo '[]' > "$temp_log"

    jq --arg timestamp "$timestamp" \
       --arg session "$session_id" \
       --arg resume "$resume_cmd" \
       --arg desc "$description" \
       --arg project "$project_dir" \
       --arg name "$session_name" \
       '. += [{timestamp: $timestamp, session: $session, session_name: $name, resume_cmd: $resume, description: $desc, project: $project}]' \
       "$temp_log" > "$LOG_FILE"

    rm -f "$temp_log" "$lock_file"
}

add_session() {
    local arg="$1"

    # Direct mode: cs add <sessionId>
    if [[ -n "$arg" && "$arg" != "--scan" ]]; then
        if [[ ! "$arg" =~ $UUID_REGEX ]]; then
            echo "Invalid session ID: $arg"
            return 1
        fi

        # Find the transcript
        local transcript=""
        for dir in "$CLAUDE_PROJECTS_DIR"/*/; do
            if [[ -f "${dir}${arg}.jsonl" ]]; then
                transcript="${dir}${arg}.jsonl"
                break
            fi
        done

        if [[ -z "$transcript" ]]; then
            echo "No transcript found for session $arg"
            return 1
        fi

        # Reuse get_session_preview for single jq pass (fixes bug: was using $sid instead of $arg)
        local project_dir=""
        if [[ -f "$CLAUDE_HISTORY" ]]; then
            project_dir=$(jq -r --arg sid "$arg" 'select(.sessionId == $sid) | .project // empty' "$CLAUDE_HISTORY" 2>/dev/null | head -1)
        fi
        local preview_data
        preview_data=$(get_session_preview "$transcript") || true
        local session_name=$(printf '%s' "$preview_data" | cut -d'|' -f3)
        local first_msg=$(printf '%s' "$preview_data" | cut -d'|' -f4)

        echo "Session: $arg"
        [[ -n "$session_name" ]] && echo "Name: $session_name"
        echo "Project: $project_dir"
        echo "Preview: ${first_msg:0:80}"
        echo ""
        read -p "Enter description: " description
        if [[ -z "$description" ]]; then
            echo "Skipped (no description)."
            return
        fi

        add_session_to_log "$arg" "$session_name" "$project_dir" "$description"
        echo "✅ Session added."
        return
    fi

    # Scan mode: find unlogged sessions
    local scan_dirs=()
    if [[ "$arg" == "--scan" ]]; then
        # Scan all project directories
        for dir in "$CLAUDE_PROJECTS_DIR"/*/; do
            [[ -d "$dir" ]] && scan_dirs+=("$dir")
        done
    else
        # Default: scan current project directory only
        local project_key=$(pwd | sed 's|/|-|g')
        local dir="$CLAUDE_PROJECTS_DIR/$project_key"
        if [[ ! -d "$dir" ]]; then
            echo "No Claude sessions found for current directory."
            return
        fi
        scan_dirs=("$dir/")
    fi

    # Get logged session IDs
    local logged_ids=""
    if [[ -s "$LOG_FILE" ]]; then
        logged_ids=$(jq -r '.[].session' "$LOG_FILE")
    fi

    # Pre-build session->project lookup from history.jsonl (one jq pass instead of N)
    local project_lookup=""
    if [[ -f "$CLAUDE_HISTORY" ]]; then
        project_lookup=$(mktemp)
        jq -r 'select(.sessionId != null and .project != null) | [.sessionId, .project] | @tsv' "$CLAUDE_HISTORY" > "$project_lookup" 2>/dev/null
    fi

    # Collect unlogged sessions with previews
    local previews=()
    for dir in "${scan_dirs[@]}"; do
        for transcript in $(ls -t "$dir"*.jsonl 2>/dev/null); do
            local sid=$(basename "$transcript" .jsonl)
            # Skip if already logged
            if echo "$logged_ids" | grep -q "^${sid}$"; then
                continue
            fi
            local preview
            preview=$(get_session_preview "$transcript" "$project_lookup") || continue
            previews+=("${preview}")
        done
    done

    [[ -n "$project_lookup" ]] && rm -f "$project_lookup"

    if [[ ${#previews[@]} -eq 0 ]]; then
        echo "No unlogged sessions found."
        return
    fi

    # Display numbered list
    echo "Unlogged sessions:"
    echo ""
    local i=1
    for entry in "${previews[@]}"; do
        local date=$(echo "$entry" | cut -d'|' -f1)
        local sid=$(echo "$entry" | cut -d'|' -f2)
        local title=$(echo "$entry" | cut -d'|' -f3)
        local label=$(echo "$entry" | cut -d'|' -f4)
        local proj=$(echo "$entry" | cut -d'|' -f5)
        local display="${title:-$label}"
        echo "[$i] $date | $display"
        echo "    ID: $sid"
        [[ -n "$proj" ]] && echo "    Project: $proj"
        echo ""
        i=$((i + 1))
    done

    read -p "Enter number to add (or 'q' to quit): " choice
    [[ "$choice" == "q" || -z "$choice" ]] && return

    local idx=$((choice - 1))
    if [[ $idx -lt 0 || $idx -ge ${#previews[@]} ]]; then
        echo "Invalid selection."
        return 1
    fi

    local selected="${previews[$idx]}"
    local sid=$(echo "$selected" | cut -d'|' -f2)
    local title=$(echo "$selected" | cut -d'|' -f3)
    local proj=$(echo "$selected" | cut -d'|' -f5)

    read -p "Enter description: " description
    if [[ -z "$description" ]]; then
        echo "Skipped (no description)."
        return
    fi

    add_session_to_log "$sid" "$title" "$proj" "$description"
    echo "✅ Session added."
}

update_session_description() {
    local session_id="$1"
    if [[ -z "$session_id" ]]; then
        echo "Usage: cs desc <session_id>"
        return 1
    fi
    if no_sessions; then
        echo "No sessions logged yet."
        return 1
    fi

    local session_data
    session_data=$(jq -r --arg s "$session_id" \
        '.[] | select(.session == $s) | [.description // "", .session_name // "", .project // ""] | @tsv' \
        "$LOG_FILE" 2>/dev/null | head -1)

    if [[ -z "$session_data" ]]; then
        echo "Session $session_id not found in log."
        return 1
    fi

    local current_desc session_name
    current_desc=$(echo "$session_data" | cut -f1)
    session_name=$(echo "$session_data" | cut -f2)

    if [[ -n "$session_name" ]]; then
        echo "📝 Session: $session_name ($session_id)"
    else
        echo "📝 Session: $session_id"
    fi
    [[ -n "$current_desc" ]] && echo "📋 Current description: $current_desc"

    read -p "New description: " new_desc
    if [[ -z "$new_desc" ]]; then
        echo "No change."
        return 0
    fi

    local tmp
    tmp=$(mktemp)
    jq --arg s "$session_id" --arg d "$new_desc" \
        'map(if .session == $s then .description = $d else . end)' \
        "$LOG_FILE" > "$tmp" && mv "$tmp" "$LOG_FILE"
    echo "✅ Description updated."
}

backup_sessions() {
    if no_sessions; then
        echo "No sessions to backup."
        return 1
    fi
    local backup_file="${LOG_FILE}.$(date +%Y%m%d-%H%M%S).bak"
    cp "$LOG_FILE" "$backup_file"
    echo "Backup saved to $backup_file"
}

clear_sessions() {
    if no_sessions; then
        echo "No sessions to clear."
        return
    fi
    read -p "Create backup before clearing? [Y/n] " backup_confirm
    if [[ ! "$backup_confirm" =~ ^[Nn]$ ]]; then
        backup_sessions
    fi
    read -p "Are you sure you want to clear all sessions? [y/N] " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        echo '[]' > "$LOG_FILE"
        echo "Sessions cleared."
    else
        echo "Cancelled."
    fi
}

# Main command dispatcher
case "${1:-list}" in
    list|ls|-ls)
        list_sessions
        ;;
    last|-l)
        last_sessions "$2"
        ;;
    search|-s)
        search_sessions "$2"
        ;;
    resume|-r)
        resume_session "$2"
        ;;
    add|-a)
        add_session "$2"
        ;;
    desc)
        update_session_description "$2"
        ;;
    backup|-b)
        backup_sessions
        ;;
    clear)
        clear_sessions
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        echo "Unknown command: $1"
        show_help
        exit 1
        ;;
esac
