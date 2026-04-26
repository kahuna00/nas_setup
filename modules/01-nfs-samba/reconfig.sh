#!/usr/bin/env bash
# modules/01-nfs-samba/reconfig.sh — Reconfiguración rápida de parámetros NFS y Samba
# Cambia variables en .env y re-aplica la configuración sin pasar por el setup completo.
# Depends on: lib/{colors,logging,env,idempotency}.sh + nfs.sh + samba.sh

NAS_SETUP_DIR="$(dirname "$(dirname "$(dirname "${BASH_SOURCE[0]}")")")"

# ── Mostrar parámetros actuales ────────────────────────────────────────────────

_show_nfs_params() {
    echo ""
    echo -e "  ${CYAN}NFS — parámetros actuales:${RESET}"
    echo -e "    Share principal   : ${BOLD}${NFS_SHARE_DIR:-/nfs/kahunaz}${RESET}"
    echo -e "    Shares extra      : ${BOLD}${NFS_EXTRA_DIRS:-(ninguna)}${RESET}"
    echo -e "    Symlink NFS pool  : ${BOLD}${NFS_POOL_LINK:-(no configurado)}${RESET} → ${BOLD}${NFS_POOL_LINK_TARGET:-(MergerFS pool)}${RESET}"
    echo -e "    Red permitida     : ${BOLD}${NFS_ALLOWED_NETWORK:-192.168.0.0/24}${RESET}"
    echo -e "    Opciones export   : ${BOLD}${NFS_EXPORT_OPTIONS:-rw,sync,no_subtree_check,no_root_squash}${RESET}"
    echo ""
}

_show_samba_params() {
    echo ""
    echo -e "  ${CYAN}Samba — parámetros actuales:${RESET}"
    echo -e "    Usuario           : ${BOLD}${SAMBA_USER:-nasuser}${RESET}"
    echo -e "    Contraseña        : ${BOLD}********${RESET}"
    echo -e "    Nombre share      : ${BOLD}${SAMBA_SHARE_NAME:-NAS}${RESET}"
    echo -e "    Workgroup         : ${BOLD}${SAMBA_WORKGROUP:-WORKGROUP}${RESET}"
    echo -e "    Log level         : ${BOLD}${SAMBA_LOG_LEVEL:-1}${RESET}"
    echo -e "    Symlink SMB pool  : ${BOLD}${SMB_POOL_LINK:-(no configurado)}${RESET} → ${BOLD}${SMB_POOL_LINK_TARGET:-(MergerFS pool)}${RESET}"
    echo ""
}

# ── Re-aplicar NFS ─────────────────────────────────────────────────────────────

_reapply_nfs() {
    log_info "Re-renderizando /etc/exports.d/nas-setup.exports..."
    render_exports || return 1

    log_info "Recargando tabla de exports NFS..."
    log_cmd "exportfs -ra" exportfs -ra || return 1

    if ! systemctl is-active --quiet nfs-server; then
        log_cmd "systemctl start nfs-server" systemctl start nfs-server
    fi

    log_success "NFS re-aplicado correctamente"
    log_info "Exports activos:"
    exportfs -v 2>/dev/null | while read -r line; do
        echo -e "  ${DIM}${line}${RESET}"
    done
}

# ── Re-aplicar Samba ───────────────────────────────────────────────────────────

_reapply_samba() {
    log_info "Re-renderizando smb.conf..."
    render_smb_conf || return 1

    local password_changed="${1:-0}"
    if [[ "$password_changed" -eq 1 ]]; then
        log_info "Actualizando contraseña Samba para: $SAMBA_USER"
        echo -e "${SAMBA_PASSWORD}\n${SAMBA_PASSWORD}" | smbpasswd -a -s "$SAMBA_USER" >> "$LOG_FILE" 2>&1
        smbpasswd -e "$SAMBA_USER" >> "$LOG_FILE" 2>&1
    fi

    log_cmd "systemctl reload smbd" systemctl reload smbd || \
        log_cmd "systemctl restart smbd" systemctl restart smbd

    log_success "Samba re-aplicado correctamente"
}

# ── Submenús de edición ────────────────────────────────────────────────────────

reconfig_nfs() {
    _show_nfs_params
    echo -e "  ${DIM}Presiona Enter para mantener el valor actual.${RESET}"
    echo ""

    local changed=0
    local v

    v=$(prompt_env_value "Share principal (NFS_SHARE_DIR)" "${NFS_SHARE_DIR:-/nfs/kahunaz}")
    [[ "$v" != "${NFS_SHARE_DIR:-/nfs/kahunaz}" ]] && { set_env_var NFS_SHARE_DIR "$v"; changed=1; }

    v=$(prompt_env_value "Shares extra, separadas por ':' (vacío=ninguna)" "${NFS_EXTRA_DIRS:-}")
    [[ "$v" != "${NFS_EXTRA_DIRS:-}" ]] && { set_env_var NFS_EXTRA_DIRS "$v"; changed=1; }

    v=$(prompt_env_value "Symlink NFS pool — ruta del enlace (vacío=deshabilitar)" "${NFS_POOL_LINK:-}")
    [[ "$v" != "${NFS_POOL_LINK:-}" ]] && { set_env_var NFS_POOL_LINK "$v"; changed=1; }

    v=$(prompt_env_value "Destino del symlink NFS (NFS_POOL_LINK_TARGET, vacío=usar MergerFS pool)" "${NFS_POOL_LINK_TARGET:-}")
    [[ "$v" != "${NFS_POOL_LINK_TARGET:-}" ]] && { set_env_var NFS_POOL_LINK_TARGET "$v"; changed=1; }

    v=$(prompt_env_value "Red permitida (NFS_ALLOWED_NETWORK)" "${NFS_ALLOWED_NETWORK:-192.168.0.0/24}")
    [[ "$v" != "${NFS_ALLOWED_NETWORK:-192.168.0.0/24}" ]] && { set_env_var NFS_ALLOWED_NETWORK "$v"; changed=1; }

    v=$(prompt_env_value "Opciones export (NFS_EXPORT_OPTIONS)" "${NFS_EXPORT_OPTIONS:-rw,sync,no_subtree_check,no_root_squash}")
    [[ "$v" != "${NFS_EXPORT_OPTIONS:-rw,sync,no_subtree_check,no_root_squash}" ]] && { set_env_var NFS_EXPORT_OPTIONS "$v"; changed=1; }

    if [[ "$changed" -eq 0 ]]; then
        log_info "Sin cambios en NFS."
        return 0
    fi

    echo ""
    # Limpiar estado para que render_exports no sea bloqueado por skip_if_done
    state_clear "nfs_configured"
    _reapply_nfs
}

reconfig_samba() {
    _show_samba_params
    echo -e "  ${DIM}Presiona Enter para mantener el valor actual.${RESET}"
    echo ""

    local changed=0 password_changed=0
    local v

    v=$(prompt_env_value "Ruta del directorio Samba (SAMBA_SHARE_DIR)" "${SAMBA_SHARE_DIR:-${NFS_SHARE_DIR:-/nfs/kahunaz}}")
    [[ "$v" != "${SAMBA_SHARE_DIR:-${NFS_SHARE_DIR:-/nfs/kahunaz}}" ]] && { set_env_var SAMBA_SHARE_DIR "$v"; changed=1; }

    v=$(prompt_env_value "Nombre de la share (SAMBA_SHARE_NAME)" "${SAMBA_SHARE_NAME:-NAS}")
    [[ "$v" != "${SAMBA_SHARE_NAME:-NAS}" ]] && { set_env_var SAMBA_SHARE_NAME "$v"; changed=1; }

    v=$(prompt_env_value "Workgroup (SAMBA_WORKGROUP)" "${SAMBA_WORKGROUP:-WORKGROUP}")
    [[ "$v" != "${SAMBA_WORKGROUP:-WORKGROUP}" ]] && { set_env_var SAMBA_WORKGROUP "$v"; changed=1; }

    v=$(prompt_env_value "Log level, 0-3 (SAMBA_LOG_LEVEL)" "${SAMBA_LOG_LEVEL:-1}")
    [[ "$v" != "${SAMBA_LOG_LEVEL:-1}" ]] && { set_env_var SAMBA_LOG_LEVEL "$v"; changed=1; }

    v=$(prompt_env_value "Symlink SMB pool — ruta del enlace (vacío=deshabilitar)" "${SMB_POOL_LINK:-}")
    [[ "$v" != "${SMB_POOL_LINK:-}" ]] && { set_env_var SMB_POOL_LINK "$v"; changed=1; }

    v=$(prompt_env_value "Destino del symlink SMB (SMB_POOL_LINK_TARGET, vacío=usar MergerFS pool)" "${SMB_POOL_LINK_TARGET:-}")
    [[ "$v" != "${SMB_POOL_LINK_TARGET:-}" ]] && { set_env_var SMB_POOL_LINK_TARGET "$v"; changed=1; }

    # Contraseña — siempre preguntar explícitamente ya que no mostramos el valor actual
    local new_pass
    read -rsp "$(echo -e "  ${BOLD}Nueva contraseña Samba${RESET} ${DIM}(Enter=no cambiar)${RESET}: ")" new_pass
    echo ""
    if [[ -n "$new_pass" ]]; then
        set_env_var SAMBA_PASSWORD "$new_pass"
        changed=1
        password_changed=1
    fi

    if [[ "$changed" -eq 0 ]]; then
        log_info "Sin cambios en Samba."
        return 0
    fi

    echo ""
    state_clear "samba_configured"
    _reapply_samba "$password_changed"
}

# ── Punto de entrada del submenú ───────────────────────────────────────────────

reconfig_nfs_samba() {
    print_header "RECONFIGURAR NFS + SAMBA"

    _show_nfs_params
    _show_samba_params

    echo -e "  ${BOLD}¿Qué deseas reconfigurar?${RESET}"
    echo ""
    echo -e "  ${CYAN}[1]${RESET} Parámetros NFS   ${DIM}(share principal · shares extra · red permitida · opciones export)${RESET}"
    echo -e "  ${CYAN}[2]${RESET} Parámetros Samba  ${DIM}(share name · workgroup · contraseña · log level)${RESET}"
    echo -e "  ${CYAN}[3]${RESET} Ambos"
    echo -e "  ${CYAN}[0]${RESET} Volver"
    echo ""

    local choice
    read -rp "$(echo -e "  ${BOLD}Opción: ${RESET}")" choice

    case "$choice" in
        1) reconfig_nfs ;;
        2) reconfig_samba ;;
        3) reconfig_nfs && reconfig_samba ;;
        0) return 0 ;;
        *) log_warn "Opción inválida" ;;
    esac
}
