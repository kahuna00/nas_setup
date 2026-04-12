#!/usr/bin/env bash
# modules/01-nfs-samba/samba.sh — Samba installation and configuration
# Depends on: lib/{colors,logging,os,env,idempotency}.sh

NAS_SETUP_DIR="$(dirname "$(dirname "$(dirname "${BASH_SOURCE[0]}")")")"
SMB_CONF="/etc/samba/smb.conf"
TEMPLATE_DIR="${NAS_SETUP_DIR}/templates"

install_samba() {
    skip_if_done "samba_installed" "instalación de Samba" && return 0
    apt_update_once
    pkg_install samba samba-common-bin || return 1
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
    chown -R "${SAMBA_USER}:${SAMBA_USER}" "$NFS_SHARE_DIR" 2>/dev/null || true
    chmod 775 "$NFS_SHARE_DIR" 2>/dev/null || true

    log_success "Usuario Samba configurado: $SAMBA_USER"
}

configure_samba() {
    log_info "Instalando Samba..."
    install_samba || return 1

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
