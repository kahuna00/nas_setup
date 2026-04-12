#!/usr/bin/env bash
# lib/logging.sh — Structured logging with file output
# Depends on: lib/colors.sh (must be sourced before this)

# Log file path (set before sourcing if you want a custom path)
LOG_DIR="${LOG_DIR:-$(dirname "$(dirname "${BASH_SOURCE[0]}")")/logs}"
LOG_FILE="${LOG_FILE:-${LOG_DIR}/nas-setup-$(date +%Y%m%d-%H%M%S).log}"
LOG_LEVEL="${LOG_LEVEL:-INFO}"

# Ensure log directory exists
mkdir -p "$LOG_DIR"

# Internal: write timestamped entry to log file
_log_to_file() {
    local level="$1"
    local msg="$2"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [${level}] ${msg}" >> "$LOG_FILE"
}

log_info() {
    local msg="$1"
    echo -e "${CYAN}  ●  ${msg}${RESET}"
    _log_to_file "INFO" "$msg"
}

log_success() {
    local msg="$1"
    echo -e "${GREEN}${BOLD}  ✔  ${msg}${RESET}"
    _log_to_file "OK  " "$msg"
}

log_warn() {
    local msg="$1"
    echo -e "${YELLOW}  ⚠  ${msg}${RESET}"
    _log_to_file "WARN" "$msg"
}

log_error() {
    local msg="$1"
    echo -e "${RED}${BOLD}  ✖  ${msg}${RESET}" >&2
    _log_to_file "ERR " "$msg"
}

log_debug() {
    local msg="$1"
    [[ "$LOG_LEVEL" == "DEBUG" ]] && echo -e "${DIM}  ·  ${msg}${RESET}"
    _log_to_file "DEBUG" "$msg"
}

# Run a command, log its output, and return its exit code
log_cmd() {
    local description="$1"
    shift
    log_debug "Ejecutando: $*"
    local output
    if output=$("$@" 2>&1); then
        log_debug "$output"
        log_success "$description"
        return 0
    else
        local code=$?
        log_error "$description — falló con código $code"
        log_error "Salida: $output"
        return $code
    fi
}

# Prompt user for confirmation (y/N)
confirm() {
    local prompt="${1:-¿Continuar?}"
    local default="${2:-N}"
    local yn
    if [[ "$default" == "Y" ]]; then
        read -rp "$(echo -e "${BOLD}  ${prompt} [Y/n]: ${RESET}")" yn
        yn="${yn:-Y}"
    else
        read -rp "$(echo -e "${BOLD}  ${prompt} [y/N]: ${RESET}")" yn
        yn="${yn:-N}"
    fi
    [[ "$yn" =~ ^[Yy]$ ]]
}
