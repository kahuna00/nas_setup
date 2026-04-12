#!/usr/bin/env bash
# modules/01-nfs-samba/nfs.sh — NFS server installation and configuration
# Depends on: lib/{colors,logging,os,env,idempotency}.sh

NAS_SETUP_DIR="$(dirname "$(dirname "$(dirname "${BASH_SOURCE[0]}")")")"
EXPORTS_FILE="/etc/exports.d/nas-setup.exports"
TEMPLATE_DIR="${NAS_SETUP_DIR}/templates"

install_nfs_server() {
    skip_if_done "nfs_installed" "instalación de NFS" && return 0
    apt_update_once
    pkg_install nfs-kernel-server || return 1
    # Ensure exports.d directory exists (older systems may not have it)
    mkdir -p /etc/exports.d
    state_mark "nfs_installed"
}

backup_exports() {
    if [[ -f "$EXPORTS_FILE" ]]; then
        cp "$EXPORTS_FILE" "${EXPORTS_FILE}.bak.$(date +%s)"
        log_debug "Backup de exports: ${EXPORTS_FILE}.bak.$(date +%s)"
    fi
}

render_exports() {
    backup_exports

    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # Start with the primary share from the template
    export TIMESTAMP="$timestamp"
    envsubst < "${TEMPLATE_DIR}/exports.j2" > "$EXPORTS_FILE"

    # Append extra shares if configured
    if [[ -n "${NFS_EXTRA_DIRS:-}" ]]; then
        local extras=()
        split_colon_var NFS_EXTRA_DIRS extras
        for extra_dir in "${extras[@]}"; do
            [[ -z "$extra_dir" ]] && continue
            if [[ ! -d "$extra_dir" ]]; then
                log_warn "Directorio extra no existe, creando: $extra_dir"
                mkdir -p "$extra_dir"
            fi
            echo "${extra_dir}   ${NFS_ALLOWED_NETWORK}(${NFS_EXPORT_OPTIONS})" >> "$EXPORTS_FILE"
            log_debug "Share NFS extra añadida: $extra_dir"
        done
    fi

    log_success "Exports renderizados en: $EXPORTS_FILE"
}

configure_nfs() {
    log_info "Instalando NFS server..."
    install_nfs_server || return 1

    log_info "Creando directorio de share principal..."
    mkdir -p "$NFS_SHARE_DIR"

    log_info "Renderizando /etc/exports.d/nas-setup.exports..."
    render_exports || return 1

    log_info "Recargando tabla de exports NFS..."
    log_cmd "exportfs -ra" exportfs -ra || return 1

    log_info "Habilitando y arrancando nfs-server..."
    log_cmd "systemctl enable nfs-server" systemctl enable nfs-server
    log_cmd "systemctl start nfs-server" systemctl start nfs-server

    state_mark "nfs_configured"
    log_success "NFS configurado correctamente"
}
