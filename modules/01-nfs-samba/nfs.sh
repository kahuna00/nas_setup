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
        local fsid_idx=10  # start at 10 to avoid collision with any implicit fsid=0 on main share
        for extra_dir in "${extras[@]}"; do
            [[ -z "$extra_dir" ]] && continue
            if [[ ! -d "$extra_dir" ]]; then
                log_warn "Directorio extra no existe, creando: $extra_dir"
                mkdir -p "$extra_dir"
            fi
            # FUSE filesystems (e.g. MergerFS) require fsid= for NFS export
            local fstype
            fstype=$(findmnt -n -o FSTYPE --target "$extra_dir" 2>/dev/null || true)
            local opts="${NFS_EXPORT_OPTIONS}"
            if [[ "$fstype" == *fuse* ]]; then
                opts="${opts},fsid=${fsid_idx}"
                log_debug "FUSE detectado en $extra_dir — añadiendo fsid=${fsid_idx}"
                ((fsid_idx++))
            fi
            echo "${extra_dir}   ${NFS_ALLOWED_NETWORK}(${opts})" >> "$EXPORTS_FILE"
            log_debug "Share NFS extra añadida: $extra_dir"
        done
    fi

    # Add dedicated pool export if NFS_POOL_LINK is configured
    if [[ -n "${NFS_POOL_LINK:-}" ]] && [[ -n "${MERGERFS_POOL_PATH:-}" ]]; then
        # Skip if already exported via NFS_EXTRA_DIRS to avoid duplicates
        local already_exported=0
        if [[ -n "${NFS_EXTRA_DIRS:-}" ]]; then
            local check_extras=()
            split_colon_var NFS_EXTRA_DIRS check_extras
            for check_dir in "${check_extras[@]}"; do
                [[ "$check_dir" == "$NFS_POOL_LINK" ]] && already_exported=1 && break
            done
        fi
        if [[ "$already_exported" -eq 0 ]]; then
            local pool_fstype
            pool_fstype=$(findmnt -n -o FSTYPE --target "${NFS_POOL_LINK}" 2>/dev/null || true)
            local pool_opts="${NFS_EXPORT_OPTIONS}"
            if [[ "$pool_fstype" == *fuse* ]]; then
                pool_opts="${pool_opts},fsid=20"
                log_debug "FUSE detectado en $NFS_POOL_LINK — añadiendo fsid=20"
            fi
            echo "${NFS_POOL_LINK}   ${NFS_ALLOWED_NETWORK}(${pool_opts})" >> "$EXPORTS_FILE"
            log_debug "Share NFS del pool añadida: $NFS_POOL_LINK"
        else
            log_debug "NFS_POOL_LINK ($NFS_POOL_LINK) ya incluida vía NFS_EXTRA_DIRS — omitiendo duplicado"
        fi
    fi

    log_success "Exports renderizados en: $EXPORTS_FILE"
}

_create_pool_nfs_link() {
    [[ -z "${NFS_POOL_LINK:-}" ]] && return 0
    [[ -z "${MERGERFS_POOL_PATH:-}" ]] && return 0

    local target="${MERGERFS_POOL_PATH}/nfs"
    mkdir -p "$target"
    chown "${SAMBA_USER:-nasuser}:${SAMBA_USER:-nasuser}" "$target"
    chmod 775 "$target"

    if [[ -L "$NFS_POOL_LINK" ]]; then
        local current_target
        current_target=$(readlink "$NFS_POOL_LINK")
        if [[ "$current_target" == "$target" ]]; then
            log_info "Symlink NFS ya existe: $NFS_POOL_LINK → $target"
            return 0
        fi
        log_warn "Actualizando symlink NFS: $NFS_POOL_LINK (era → $current_target)"
        rm "$NFS_POOL_LINK"
    elif [[ -e "$NFS_POOL_LINK" ]]; then
        log_error "$NFS_POOL_LINK ya existe y no es un symlink — no se sobreescribirá"
        return 1
    fi

    mkdir -p "$(dirname "$NFS_POOL_LINK")"
    ln -s "$target" "$NFS_POOL_LINK"
    log_success "Symlink NFS creado: $NFS_POOL_LINK → $target"
}

configure_nfs() {
    log_info "Instalando NFS server..."
    install_nfs_server || return 1

    log_info "Creando directorio de share principal..."
    mkdir -p "$NFS_SHARE_DIR"

    log_info "Creando symlink del pool MergerFS para NFS..."
    _create_pool_nfs_link || return 1

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
