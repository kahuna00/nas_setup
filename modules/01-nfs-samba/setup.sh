#!/usr/bin/env bash
# modules/01-nfs-samba/setup.sh — Módulo 1: NFS + Samba setup orchestrator
# Uso: sourced desde install.sh, llamar setup_nfs_samba()

NAS_SETUP_DIR="$(dirname "$(dirname "$(dirname "${BASH_SOURCE[0]}")")")"

# Source module files
source "${NAS_SETUP_DIR}/modules/01-nfs-samba/nfs.sh"
source "${NAS_SETUP_DIR}/modules/01-nfs-samba/samba.sh"
source "${NAS_SETUP_DIR}/modules/01-nfs-samba/validate.sh"

setup_nfs_samba() {
    print_header "MÓDULO 1: NFS + SAMBA"

    # ── Validar variables requeridas ───────────────────────────────────────────
    validate_env \
        NFS_SHARE_DIR \
        NFS_ALLOWED_NETWORK \
        NFS_EXPORT_OPTIONS \
        SAMBA_USER \
        SAMBA_PASSWORD \
        SAMBA_WORKGROUP \
        SAMBA_SHARE_NAME || return 1

    # ── Pre-flight: estado actual de PVs Kubernetes ────────────────────────────
    print_step "PRE" "Verificación pre-configuración"
    log_info "Registrando estado actual de PVs NFS (si kubectl disponible)..."
    validate_k8s_nfs_mounts
    echo ""

    # ── Confirmar antes de proceder ────────────────────────────────────────────
    echo -e "  ${BOLD}Configuración que se aplicará:${RESET}"
    echo -e "  NFS share principal : ${CYAN}${NFS_SHARE_DIR}${RESET}"
    echo -e "  Red permitida NFS   : ${CYAN}${NFS_ALLOWED_NETWORK}${RESET}"
    echo -e "  Usuario Samba       : ${CYAN}${SAMBA_USER}${RESET}"
    echo -e "  Share Samba         : ${CYAN}${SAMBA_SHARE_NAME}${RESET}"
    [[ -n "${NFS_EXTRA_DIRS:-}" ]] && \
        echo -e "  Shares extras       : ${CYAN}${NFS_EXTRA_DIRS}${RESET}"
    [[ -n "${NFS_POOL_LINK:-}" ]] && \
        echo -e "  Symlink NFS pool    : ${CYAN}${NFS_POOL_LINK}${RESET} → ${MERGERFS_POOL_PATH:-/mergerfs/pool}"
    [[ -n "${SMB_POOL_LINK:-}" ]] && \
        echo -e "  Symlink SMB pool    : ${CYAN}${SMB_POOL_LINK}${RESET} → ${MERGERFS_POOL_PATH:-/mergerfs/pool}"
    echo ""

    confirm "¿Aplicar configuración NFS + Samba?" "Y" || {
        log_warn "Configuración cancelada por el usuario"
        return 0
    }

    # ── Módulo NFS ─────────────────────────────────────────────────────────────
    print_step "1" "Configurando NFS Server"
    configure_nfs || {
        log_error "Falló la configuración de NFS"
        return 1
    }

    # ── Módulo Samba ───────────────────────────────────────────────────────────
    print_step "2" "Configurando Samba"
    configure_samba || {
        log_error "Falló la configuración de Samba"
        return 1
    }

    # ── Post-flight: verificación ──────────────────────────────────────────────
    print_step "3" "Validación post-configuración"
    validate_nfs
    validate_smb_share
    validate_k8s_nfs_mounts

    echo ""
    log_success "═══════════════════════════════════════════════"
    log_success "Módulo 1 completado exitosamente"
    log_success "═══════════════════════════════════════════════"
    echo ""

    local server_ip
    server_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
    server_ip="${server_ip:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
    server_ip="${server_ip:-${HOSTNAME}}"

    echo -e "  ${BOLD}Accesos NFS:${RESET}"
    echo -e "  ${DIM}mount -t nfs ${server_ip}:${NFS_SHARE_DIR} /mnt/nas${RESET}"
    [[ -n "${NFS_POOL_LINK:-}" ]] && \
        echo -e "  ${DIM}mount -t nfs ${server_ip}:${NFS_POOL_LINK} /mnt/pool${RESET}"
    echo ""
    echo -e "  ${BOLD}Accesos Samba:${RESET}"
    echo -e "  ${DIM}smb://${server_ip}/${SAMBA_SHARE_NAME}${RESET}"
    [[ -n "${SMB_POOL_LINK:-}" ]] && \
        echo -e "  ${DIM}smb://${server_ip}/$(basename "$SMB_POOL_LINK" | tr '[:lower:]' '[:upper:]')${RESET}"
    echo ""
    echo -e "  ${DIM}Log : ${LOG_FILE}${RESET}"
    echo ""
}
