#!/bin/bash

# Claude Sessions Manager
# View and manage logged Claude sessions

LOG_FILE="${CLAUDE_SESSION_LOG:-$HOME/.claude-sessions.log}"

show_help() {
    cat << EOF
Claude Sessions Manager

Usage: claude-sessions [command]

Commands:
    list, ls     List all logged sessions
    last [n]     Show last n sessions (default: 5)
    search <q>   Search sessions by keyword
    resume <n>   Resume the nth most recent session
    clear        Clear all logged sessions
    help         Show this help message

Environment:
    CLAUDE_SESSION_LOG   Path to log file (default: ~/.claude-sessions.log)
EOF
}

list_sessions() {
    if [[ ! -f "$LOG_FILE" ]] || [[ ! -s "$LOG_FILE" ]]; then
        echo "No sessions logged yet."
        return
    fi
    
    jq -r '.[] | "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\nTimestamp: \(.timestamp)" + (if .session_name != "" and .session_name != null then "\nName: \(.session_name)" else "" end) + "\nSession: \(.session)\nResume cmd: \(.resume_cmd)" + (if .project != "" and .project != null then "\nProject: \(.project)" else "" end) + (if .description != "" then "\nDescription: \(.description)" else "" end) + "\n"' "$LOG_FILE"
}

last_sessions() {
    local count=${1:-5}
    if [[ ! -f "$LOG_FILE" ]] || [[ ! -s "$LOG_FILE" ]]; then
        echo "No sessions logged yet."
        return
    fi
    
    jq -r --argjson count "$count" '(.[-$count:] | to_entries | .[] | "[\(.key + 1)] ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\nTimestamp: \(.value.timestamp)" + (if .value.session_name != "" and .value.session_name != null then "\nName: \(.value.session_name)" else "" end) + "\nSession: \(.value.session)\nResume cmd: \(.value.resume_cmd)" + (if .value.project != "" and .value.project != null then "\nProject: \(.value.project)" else "" end) + (if .value.description != "" then "\nDescription: \(.value.description)" else "" end) + "\n")' "$LOG_FILE"
}

search_sessions() {
    local query="$1"
    if [[ -z "$query" ]]; then
        echo "Usage: claude-sessions search <keyword>"
        return 1
    fi
    
    if [[ ! -f "$LOG_FILE" ]]; then
        echo "No sessions logged yet."
        return
    fi
    
    local results
    results=$(jq -r --arg q "$query" '.[] | select((.session + (.session_name // "") + .description + .resume_cmd) | ascii_downcase | contains($q | ascii_downcase)) | "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\nTimestamp: \(.timestamp)" + (if .session_name != "" and .session_name != null then "\nName: \(.session_name)" else "" end) + "\nSession: \(.session)\nResume cmd: \(.resume_cmd)" + (if .project != "" and .project != null then "\nProject: \(.project)" else "" end) + (if .description != "" then "\nDescription: \(.description)" else "" end) + "\n"' "$LOG_FILE")
    
    if [[ -z "$results" ]]; then
        echo "No matches found."
    else
        echo "$results"
    fi
}

resume_session() {
    local n="${1:-1}"
    if [[ ! -f "$LOG_FILE" ]]; then
        echo "No sessions logged yet."
        return 1
    fi
    
    # Get nth most recent session name
    local session_name
    session_name=$(jq -r --argjson n "$n" '.[-$n].session' "$LOG_FILE")
    
    if [[ -z "$session_name" ]] || [[ "$session_name" == "null" ]]; then
        echo "Session #$n not found."
        return 1
    fi
    
    # Get the project directory for this session
    local project_dir
    project_dir=$(jq -r --argjson n "$n" '.[-$n].project // empty' "$LOG_FILE")

    # Get the display name if available
    local display_name
    display_name=$(jq -r --argjson n "$n" '.[-$n].session_name // empty' "$LOG_FILE")
    local label="${display_name:-$session_name}"

    if [[ -n "$project_dir" ]] && [[ -d "$project_dir" ]]; then
        echo "Resuming session: $label (in $project_dir)"
        cd "$project_dir" || { echo "Failed to cd to $project_dir"; return 1; }
    else
        echo "Resuming session: $label"
    fi

    # Use wrapper if available, otherwise fall back to claude
    if command -v claude-wrapper.sh &> /dev/null; then
        claude-wrapper.sh --resume "$session_name"
    else
        claude --resume "$session_name"
    fi
}

clear_sessions() {
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
    list|ls)
        list_sessions
        ;;
    last)
        last_sessions "$2"
        ;;
    search)
        search_sessions "$2"
        ;;
    resume)
        resume_session "$2"
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
