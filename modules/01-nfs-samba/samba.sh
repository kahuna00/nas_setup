#!/usr/bin/env bash
# modules/01-nfs-samba/samba.sh — Samba installation and configuration
# Depends on: lib/{colors,logging,os,env,idempotency}.sh

NAS_SETUP_DIR="$(dirname "$(dirname "$(dirname "${BASH_SOURCE[0]}")")")"
SMB_CONF="/etc/samba/smb.conf"
TEMPLATE_DIR="${NAS_SETUP_DIR}/templates"

install_samba() {
    skip_if_done "samba_installed" "instalación de Samba" && return 0
    apt_update_once
    pkg_install samba samba-common-bin smbclient || return 1
    state_mark "samba_installed"
}

backup_smb_conf() {
    if [[ -f "$SMB_CONF" ]]; then
        cp "$SMB_CONF" "${SMB_CONF}.bak.$(date +%s)"
        log_debug "Backup de smb.conf creado"
    fi
}

render_smb_conf() {
    local tmp_conf="/tmp/smb.conf.nas-setup"

    export TIMESTAMP
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

    envsubst < "${TEMPLATE_DIR}/smb.conf.j2" > "$tmp_conf"

    # Append extra shares if configured
    if [[ -n "${NFS_EXTRA_DIRS:-}" ]]; then
        local extras=()
        split_colon_var NFS_EXTRA_DIRS extras
        local idx=2
        for extra_dir in "${extras[@]}"; do
            [[ -z "$extra_dir" ]] && continue
            local share_name
            share_name=$(basename "$extra_dir" | tr '[:lower:]' '[:upper:]')
            cat >> "$tmp_conf" << EOF

[${share_name}]
   comment = Share adicional
   path = ${extra_dir}
   browseable = yes
   writable = yes
   valid users = ${SAMBA_USER}
   create mask = 0664
   directory mask = 0775
EOF
            log_debug "Share Samba extra añadida: [$share_name] → $extra_dir"
            ((idx++))
        done
    fi

    # Add dedicated pool share if SMB_POOL_LINK is configured
    if [[ -n "${SMB_POOL_LINK:-}" ]] && [[ -n "${MERGERFS_POOL_PATH:-}" ]]; then
        local pool_share_name
        pool_share_name=$(basename "$SMB_POOL_LINK" | tr '[:lower:]' '[:upper:]')
        cat >> "$tmp_conf" << EOF

[${pool_share_name}]
   comment = MergerFS Pool
   path = ${SMB_POOL_LINK}
   browseable = yes
   writable = yes
   valid users = ${SAMBA_USER}
   create mask = 0664
   directory mask = 0775
   force group = ${SAMBA_USER}
   follow symlinks = yes
   wide links = yes
EOF
        log_debug "Share Samba del pool añadida: [${pool_share_name}] → $SMB_POOL_LINK"
    fi

    # Validate config before applying
    if ! testparm -s "$tmp_conf" &>/dev/null; then
        log_error "smb.conf generado tiene errores — no se aplicará"
        log_info "Revisa: testparm -s $tmp_conf"
        rm -f "$tmp_conf"
        return 1
    fi

    backup_smb_conf
    mv "$tmp_conf" "$SMB_CONF"
    log_success "smb.conf aplicado y validado"
}

_create_pool_smb_link() {
    [[ -z "${SMB_POOL_LINK:-}" ]] && return 0
    [[ -z "${MERGERFS_POOL_PATH:-}" ]] && return 0

    local target="${MERGERFS_POOL_PATH}/smb"
    mkdir -p "$target"
    chown "${SAMBA_USER:-nasuser}:${SAMBA_USER:-nasuser}" "$target"
    chmod 775 "$target"

    if [[ -L "$SMB_POOL_LINK" ]]; then
        local current_target
        current_target=$(readlink "$SMB_POOL_LINK")
        if [[ "$current_target" == "$target" ]]; then
            log_info "Symlink Samba ya existe: $SMB_POOL_LINK → $target"
            return 0
        fi
        log_warn "Actualizando symlink Samba: $SMB_POOL_LINK (era → $current_target)"
        rm "$SMB_POOL_LINK"
    elif [[ -e "$SMB_POOL_LINK" ]]; then
        log_error "$SMB_POOL_LINK ya existe y no es un symlink — no se sobreescribirá"
        return 1
    fi

    mkdir -p "$(dirname "$SMB_POOL_LINK")"
    ln -s "$target" "$SMB_POOL_LINK"
    log_success "Symlink Samba creado: $SMB_POOL_LINK → $target"
}

configure_samba_user() {
    # Create system user if it doesn't exist (no home, no login shell)
    if ! id "$SAMBA_USER" &>/dev/null; then
        log_info "Creando usuario del sistema: $SAMBA_USER"
        useradd -M -s /sbin/nologin "$SAMBA_USER" || {
            log_error "No se pudo crear usuario: $SAMBA_USER"
            return 1
        }
    else
        log_debug "Usuario del sistema ya existe: $SAMBA_USER"
    fi

    # Set/update Samba password
    log_info "Configurando contraseña Samba para: $SAMBA_USER"
    echo -e "${SAMBA_PASSWORD}\n${SAMBA_PASSWORD}" | smbpasswd -a -s "$SAMBA_USER" >> "$LOG_FILE" 2>&1
    smbpasswd -e "$SAMBA_USER" >> "$LOG_FILE" 2>&1  # ensure enabled

    # Ensure the share directory is accessible by the Samba user
    local smb_dir="${SAMBA_SHARE_DIR:-${NFS_SHARE_DIR}}"
    mkdir -p "$smb_dir"
    chown -R "${SAMBA_USER}:${SAMBA_USER}" "$smb_dir" 2>/dev/null || true
    chmod 775 "$smb_dir" 2>/dev/null || true

    log_success "Usuario Samba configurado: $SAMBA_USER"
}

configure_samba() {
    log_info "Instalando Samba..."
    install_samba || return 1

    if ! command -v smbclient &>/dev/null; then
        log_info "Instalando smbclient..."
        pkg_install smbclient || log_warn "No se pudo instalar smbclient — validación usará testparm"
    fi

    log_info "Creando symlink del pool MergerFS para Samba..."
    _create_pool_smb_link || return 1

    log_info "Renderizando smb.conf..."
    render_smb_conf || return 1

    log_info "Configurando usuario Samba..."
    configure_samba_user || return 1

    log_info "Habilitando y arrancando Samba..."
    log_cmd "systemctl enable smbd nmbd" systemctl enable smbd nmbd
    log_cmd "systemctl restart smbd nmbd" systemctl restart smbd nmbd

    state_mark "samba_configured"
    log_success "Samba configurado correctamente"
}

disable_samba() {
    confirm "¿Detener Samba y eliminar smb.conf?" "N" || return 0

    log_info "Deteniendo y deshabilitando smbd/nmbd..."
    systemctl stop smbd nmbd 2>/dev/null || true
    systemctl disable smbd nmbd 2>/dev/null || true

    if [[ -f "$SMB_CONF" ]]; then
        cp "$SMB_CONF" "${SMB_CONF}.bak.$(date +%s)"
        printf '[global]\n   workgroup = WORKGROUP\n   server string = Samba Server\n' > "$SMB_CONF"
        log_success "smb.conf reseteado al mínimo"
    fi

    state_clear "samba_configured"
    state_clear "samba_installed"
    log_success "Samba desactivado"
}
