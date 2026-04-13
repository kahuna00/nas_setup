#!/usr/bin/env bash
# lib/env.sh — .env loading and variable validation
# Depends on: lib/logging.sh

NAS_SETUP_DIR="$(dirname "$(dirname "${BASH_SOURCE[0]}")")"

load_env() {
    local env_file="${NAS_SETUP_DIR}/.env"
    local example_file="${NAS_SETUP_DIR}/.env.example"

    # Load defaults from .env.example first
    if [[ -f "$example_file" ]]; then
        # Only set vars not already exported
        while IFS= read -r line; do
            [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
            local key="${line%%=*}"
            # Only set if not already in environment
            if [[ -z "${!key+x}" ]]; then
                export "$line" 2>/dev/null || true
            fi
        done < <(grep -v '^#' "$example_file" | grep '=')
        log_debug "Defaults cargados desde .env.example"
    fi

    # Override with actual .env
    if [[ -f "$env_file" ]]; then
        set -a
        # shellcheck disable=SC1090
        source "$env_file"
        set +a
        log_success "Configuración cargada desde .env"
    else
        log_warn ".env no encontrado. Usando valores de .env.example"
        log_info "Copia .env.example a .env y configura tus valores:"
        log_info "  cp ${env_file}.example ${env_file}"
    fi
}

# Validate that required variables are set and non-empty
validate_env() {
    local required=("$@")
    local missing=()

    for var in "${required[@]}"; do
        if [[ -z "${!var}" ]]; then
            missing+=("$var")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Variables requeridas no configuradas en .env:"
        for var in "${missing[@]}"; do
            echo -e "  ${RED}  • ${var}${RESET}" >&2
        done
        log_info "Edita tu archivo .env y configura los valores faltantes."
        return 1
    fi
}

# Get variable value or a default
env_var_or_default() {
    local var="$1"
    local default="$2"
    echo "${!var:-$default}"
}

# Split a colon-separated env var into an array
split_colon_var() {
    local var="$1"
    local -n result_ref="$2"
    IFS=':' read -ra result_ref <<< "${!var}"
}

# Update or add a variable in .env and export it into the current process
# Usage: set_env_var KEY VALUE
set_env_var() {
    local key="$1"
    local value="$2"
    local env_file="${NAS_SETUP_DIR}/.env"

    if grep -q "^${key}=" "$env_file" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$env_file"
    else
        echo "${key}=${value}" >> "$env_file"
    fi
    export "${key}=${value}"
}

# Prompt user for a value, showing the current one; Enter keeps current
# Usage: prompt_env_value "Label text" "current_value"  → echoes chosen value
prompt_env_value() {
    local label="$1"
    local current="$2"
    local result
    read -rp "$(echo -e "  ${BOLD}${label}${RESET} ${DIM}[actual: ${current}]${RESET}: ")" result
    echo "${result:-$current}"
}
