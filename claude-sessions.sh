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
    
    jq -r '.[] | "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\nTimestamp: \(.timestamp)\nSession: \(.session)\nResume cmd: \(.resume_cmd)" + (if .description != "" then "\nDescription: \(.description)" else "" end) + "\n"' "$LOG_FILE"
}

last_sessions() {
    local count=${1:-5}
    if [[ ! -f "$LOG_FILE" ]] || [[ ! -s "$LOG_FILE" ]]; then
        echo "No sessions logged yet."
        return
    fi
    
    jq -r --argjson count "$count" '(.[-$count:] | to_entries | .[] | "[\(.key + 1)] ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\nTimestamp: \(.value.timestamp)\nSession: \(.value.session)\nResume cmd: \(.value.resume_cmd)" + (if .value.description != "" then "\nDescription: \(.value.description)" else "" end) + "\n")' "$LOG_FILE"
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
    results=$(jq -r --arg q "$query" '.[] | select(.session + .description + .resume_cmd | ascii_downcase | contains($q | ascii_downcase)) | "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\nTimestamp: \(.timestamp)\nSession: \(.session)\nResume cmd: \(.resume_cmd)" + (if .description != "" then "\nDescription: \(.description)" else "" end) + "\n"' "$LOG_FILE")
    
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
    
    echo "Resuming session: $session_name"
    
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
