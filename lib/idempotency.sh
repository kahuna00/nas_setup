#!/usr/bin/env bash
# lib/idempotency.sh — State sentinel management for idempotent operations
# State files stored in /var/lib/nas-setup/state/
# Depends on: lib/logging.sh

STATE_DIR="${STATE_DIR:-/var/lib/nas-setup/state}"

_ensure_state_dir() {
    mkdir -p "$STATE_DIR"
}

# Mark an operation as completed
state_mark() {
    local name="$1"
    _ensure_state_dir
    touch "${STATE_DIR}/${name}"
    log_debug "Estado marcado: ${name}"
}

# Check if an operation was already completed
# Returns 0 if done, 1 if not
state_check() {
    local name="$1"
    [[ -f "${STATE_DIR}/${name}" ]]
}

# Clear a specific state sentinel
state_clear() {
    local name="$1"
    rm -f "${STATE_DIR}/${name}"
    log_debug "Estado limpiado: ${name}"
}

# Clear ALL state (full re-run)
state_reset_all() {
    if [[ -d "$STATE_DIR" ]]; then
        rm -f "${STATE_DIR}"/*
        log_warn "Todos los estados limpiados. La próxima ejecución re-configurará todo."
    fi
}

# Guard helper: skip if already done (unless FORCE_RERUN=1)
# Usage: skip_if_done "operation_name" || return 0
skip_if_done() {
    local name="$1"
    local description="${2:-$name}"
    if state_check "$name" && [[ "${FORCE_RERUN:-0}" != "1" ]]; then
        log_info "Saltando '${description}' (ya configurado). Usa FORCE_RERUN=1 para forzar."
        return 0
    fi
    return 1
}
