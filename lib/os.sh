#!/usr/bin/env bash
# lib/os.sh — OS detection, package management, and system utilities
# Depends on: lib/logging.sh

OS_ID=""
OS_VERSION=""
PKG_MGR=""

detect_os() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        OS_ID="${ID,,}"         # lowercase: ubuntu, debian, etc.
        OS_VERSION="${VERSION_ID:-unknown}"
        log_debug "OS detectado: ${OS_ID} ${OS_VERSION}"
    else
        log_error "No se puede detectar el sistema operativo (/etc/os-release no existe)"
        exit 1
    fi
}

detect_pkg_manager() {
    if command -v apt-get &>/dev/null; then
        PKG_MGR="apt-get"
    elif command -v apt &>/dev/null; then
        PKG_MGR="apt"
    else
        log_error "Gestor de paquetes no soportado. Se requiere apt/apt-get (Debian/Ubuntu)."
        exit 1
    fi
    log_debug "Gestor de paquetes: ${PKG_MGR}"
}

require_root() {
    if [[ "$EUID" -ne 0 ]]; then
        log_error "Este script debe ejecutarse como root. Usa: sudo bash $0"
        exit 1
    fi
}

# Idempotent package install — skips if already installed
pkg_install() {
    local packages=("$@")
    local to_install=()

    for pkg in "${packages[@]}"; do
        if dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
            log_debug "Paquete ya instalado: $pkg"
        else
            to_install+=("$pkg")
        fi
    done

    if [[ ${#to_install[@]} -eq 0 ]]; then
        log_success "Todos los paquetes ya están instalados: ${packages[*]}"
        return 0
    fi

    log_info "Instalando: ${to_install[*]}"
    $PKG_MGR install -y "${to_install[@]}" >> "$LOG_FILE" 2>&1 || {
        log_error "Error instalando paquetes: ${to_install[*]}"
        return 1
    }
    log_success "Instalados: ${to_install[*]}"
}

get_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        aarch64|arm64) echo "arm64" ;;
        x86_64)        echo "amd64" ;;
        *)             echo "$arch" ;;
    esac
}

# Check if a command exists
require_cmd() {
    local cmd="$1"
    local install_hint="${2:-}"
    if ! command -v "$cmd" &>/dev/null; then
        log_error "Comando no encontrado: $cmd"
        [[ -n "$install_hint" ]] && log_info "Instalar con: $install_hint"
        return 1
    fi
}

# Update apt cache (at most once per session)
_APT_UPDATED=0
apt_update_once() {
    if [[ "$_APT_UPDATED" -eq 0 ]]; then
        log_info "Actualizando lista de paquetes..."
        $PKG_MGR update -qq >> "$LOG_FILE" 2>&1
        _APT_UPDATED=1
    fi
}
