#!/usr/bin/env bash
# modules/01-nfs-samba/setup.sh — Módulo 1: NFS + Samba setup orchestrator
# Uso: sourced desde install.sh, llamar setup_nfs() / setup_samba()

NAS_SETUP_DIR="$(dirname "$(dirname "$(dirname "${BASH_SOURCE[0]}")")")"

# Source module files
source "${NAS_SETUP_DIR}/modules/01-nfs-samba/nfs.sh"
source "${NAS_SETUP_DIR}/modules/01-nfs-samba/samba.sh"
source "${NAS_SETUP_DIR}/modules/01-nfs-samba/validate.sh"
source "${NAS_SETUP_DIR}/modules/01-nfs-samba/reconfig.sh"

# ── NFS ────────────────────────────────────────────────────────────────────────

setup_nfs() {
    print_header "NFS SERVER"

    echo -e "  ${BOLD}¿Qué deseas hacer?${RESET}"
    echo ""
    echo -e "  ${CYAN}[1]${RESET} Instalar / configurar  ${DIM}(primera vez o re-instalar)${RESET}"
    echo -e "  ${CYAN}[2]${RESET} Reconfigurar parámetros  ${DIM}(share, red permitida, opciones…)${RESET}"
    echo -e "  ${CYAN}[3]${RESET} ${RED}Desactivar NFS${RESET}  ${DIM}(detiene servicio y elimina exports)${RESET}"
    echo -e "  ${CYAN}[0]${RESET} Volver"
    echo ""

    local choice
    read -rp "$(echo -e "  ${BOLD}Opción: ${RESET}")" choice

    case "$choice" in
        1) _install_nfs || true ;;
        2) reconfig_nfs || true ;;
        3) disable_nfs || true ;;
        0) return 0 ;;
        *) log_warn "Opción inválida" ;;
    esac
}

_install_nfs() {
    validate_env \
        NFS_SHARE_DIR \
        NFS_ALLOWED_NETWORK \
        NFS_EXPORT_OPTIONS || return 1

    print_step "PRE" "Verificación pre-configuración"
    validate_k8s_nfs_mounts
    echo ""

    echo -e "  ${BOLD}Configuración NFS:${RESET}"
    echo -e "  Share principal : ${CYAN}${NFS_SHARE_DIR}${RESET}"
    echo -e "  Red permitida   : ${CYAN}${NFS_ALLOWED_NETWORK}${RESET}"
    [[ -n "${NFS_EXTRA_DIRS:-}" ]] && \
        echo -e "  Shares extra    : ${CYAN}${NFS_EXTRA_DIRS}${RESET}"
    [[ -n "${NFS_POOL_LINK:-}" ]] && \
        echo -e "  Symlink pool    : ${CYAN}${NFS_POOL_LINK}${RESET} → ${NFS_POOL_LINK_TARGET:-${MERGERFS_POOL_PATH:-/mergerfs/pool}/nfs}"
    echo ""

    confirm "¿Aplicar configuración NFS?" "Y" || { log_warn "Cancelado"; return 0; }

    configure_nfs || { log_error "Falló la configuración de NFS"; return 1; }

    print_step "POST" "Validación"
    validate_nfs
    validate_k8s_nfs_mounts

    echo ""
    log_success "NFS configurado"
    local server_ip
    server_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
    server_ip="${server_ip:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
    echo -e "  ${DIM}mount -t nfs ${server_ip}:${NFS_SHARE_DIR} /mnt/nas${RESET}"
    [[ -n "${NFS_POOL_LINK:-}" ]] && \
        echo -e "  ${DIM}mount -t nfs ${server_ip}:${NFS_POOL_LINK} /mnt/pool${RESET}"
    echo ""
}

# ── Samba ──────────────────────────────────────────────────────────────────────

setup_samba() {
    print_header "SAMBA"

    echo -e "  ${BOLD}¿Qué deseas hacer?${RESET}"
    echo ""
    echo -e "  ${CYAN}[1]${RESET} Instalar / configurar  ${DIM}(primera vez o re-instalar)${RESET}"
    echo -e "  ${CYAN}[2]${RESET} Reconfigurar parámetros  ${DIM}(ruta, share name, contraseña…)${RESET}"
    echo -e "  ${CYAN}[3]${RESET} ${RED}Desactivar Samba${RESET}  ${DIM}(detiene smbd/nmbd y resetea smb.conf)${RESET}"
    echo -e "  ${CYAN}[0]${RESET} Volver"
    echo ""

    local choice
    read -rp "$(echo -e "  ${BOLD}Opción: ${RESET}")" choice

    case "$choice" in
        1) _install_samba || true ;;
        2) reconfig_samba || true ;;
        3) disable_samba || true ;;
        0) return 0 ;;
        *) log_warn "Opción inválida" ;;
    esac
}

_install_samba() {
    validate_env \
        SAMBA_USER \
        SAMBA_PASSWORD \
        SAMBA_WORKGROUP \
        SAMBA_SHARE_NAME || return 1

    # Default SAMBA_SHARE_DIR to NFS_SHARE_DIR if not set
    if [[ -z "${SAMBA_SHARE_DIR:-}" ]]; then
        SAMBA_SHARE_DIR="${NFS_SHARE_DIR:-/nfs/kahunaz}"
        set_env_var SAMBA_SHARE_DIR "$SAMBA_SHARE_DIR"
        log_info "SAMBA_SHARE_DIR no definido — usando: $SAMBA_SHARE_DIR"
    fi

    echo -e "  ${BOLD}Configuración Samba:${RESET}"
    echo -e "  Directorio share : ${CYAN}${SAMBA_SHARE_DIR}${RESET}"
    echo -e "  Nombre share     : ${CYAN}${SAMBA_SHARE_NAME}${RESET}"
    echo -e "  Usuario          : ${CYAN}${SAMBA_USER}${RESET}"
    [[ -n "${SMB_POOL_LINK:-}" ]] && \
        echo -e "  Symlink pool     : ${CYAN}${SMB_POOL_LINK}${RESET} → ${SMB_POOL_LINK_TARGET:-${MERGERFS_POOL_PATH:-/mergerfs/pool}/smb}"
    echo ""

    confirm "¿Aplicar configuración Samba?" "Y" || { log_warn "Cancelado"; return 0; }

    configure_samba || { log_error "Falló la configuración de Samba"; return 1; }

    print_step "POST" "Validación"
    validate_smb_share

    echo ""
    log_success "Samba configurado"
    local server_ip
    server_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
    server_ip="${server_ip:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
    echo -e "  ${DIM}smb://${server_ip}/${SAMBA_SHARE_NAME}${RESET}"
    [[ -n "${SMB_POOL_LINK:-}" ]] && \
        echo -e "  ${DIM}smb://${server_ip}/$(basename "$SMB_POOL_LINK" | tr '[:lower:]' '[:upper:]')${RESET}"
    echo ""
}
