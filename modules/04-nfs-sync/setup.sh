#!/usr/bin/env bash
# modules/04-nfs-sync/setup.sh — Módulo 4: NFS Sync orchestrator
# Uso: sourced desde install.sh, llamar setup_nfs_sync()

NAS_SETUP_DIR="$(dirname "$(dirname "$(dirname "${BASH_SOURCE[0]}")")")"

source "${NAS_SETUP_DIR}/modules/04-nfs-sync/mount.sh"
source "${NAS_SETUP_DIR}/modules/04-nfs-sync/sync.sh"
source "${NAS_SETUP_DIR}/modules/04-nfs-sync/schedule.sh"
source "${NAS_SETUP_DIR}/modules/04-nfs-sync/validate.sh"

setup_nfs_sync() {
    print_header "MÓDULO 4: NFS SYNC (REMOTO → LOCAL)"

    # ── Validar variables requeridas ───────────────────────────────────────────
    validate_env \
        NFS_SYNC_REMOTE_HOST \
        NFS_SYNC_REMOTE_PATH \
        NFS_SYNC_MOUNT_POINT \
        NFS_SYNC_DEST_DIR \
        NFS_SYNC_HOUR || return 1

    # ── Mostrar configuración antes de confirmar ───────────────────────────────
    echo -e "  ${BOLD}Configuración que se aplicará:${RESET}"
    echo -e "  Fuente remota    : ${CYAN}${NFS_SYNC_REMOTE_HOST}:${NFS_SYNC_REMOTE_PATH}${RESET}"
    echo -e "  Montaje local    : ${CYAN}${NFS_SYNC_MOUNT_POINT}${RESET}"
    echo -e "  Destino local    : ${CYAN}${NFS_SYNC_DEST_DIR}${RESET}"
    echo -e "  Opciones rsync   : ${CYAN}${NFS_SYNC_RSYNC_OPTS}${RESET}"
    echo -e "  Schedule         : ${CYAN}${NFS_SYNC_HOUR}:00 diario (${SCHEDULE_TYPE:-systemd})${RESET}"
    [[ "${NFS_SYNC_BW_LIMIT:-0}" -gt 0 ]] && \
        echo -e "  Límite ancho banda: ${CYAN}${NFS_SYNC_BW_LIMIT} KB/s${RESET}"
    [[ -n "${NFS_SYNC_EXCLUDES:-}" ]] && \
        echo -e "  Exclusiones      : ${CYAN}${NFS_SYNC_EXCLUDES}${RESET}"
    echo ""

    confirm "¿Aplicar configuración de NFS Sync?" "Y" || {
        log_warn "Configuración cancelada por el usuario"
        return 0
    }

    # ── Paso 1: Montar NFS remoto ──────────────────────────────────────────────
    print_step "1" "Configurando montaje del NFS remoto"
    configure_remote_mount || {
        log_error "Falló la configuración del montaje remoto"
        return 1
    }

    # ── Paso 2: Generar script de sync ─────────────────────────────────────────
    print_step "2" "Generando script de sync"
    configure_sync || {
        log_error "Falló la generación del script de sync"
        return 1
    }

    # ── Paso 3: Configurar schedule ────────────────────────────────────────────
    print_step "3" "Configurando schedule automático"
    configure_sync_schedule || {
        log_error "Falló la configuración del schedule"
        return 1
    }

    # ── Paso 4: Validación post-configuración ──────────────────────────────────
    print_step "4" "Validación post-configuración"
    validate_nfs_sync

    echo ""
    log_success "═══════════════════════════════════════════════"
    log_success "Módulo 4 completado exitosamente"
    log_success "═══════════════════════════════════════════════"
    echo ""
    echo -e "  ${BOLD}Para ejecutar el sync manualmente:${RESET}"
    echo -e "  ${DIM}sudo bash /var/lib/nas-setup/scripts/nfs-sync.sh${RESET}"
    echo ""
    echo -e "  ${BOLD}Para ver logs del sync:${RESET}"
    echo -e "  ${DIM}journalctl -t nfs-sync -f${RESET}"
    echo ""
    echo -e "  ${DIM}Log : ${LOG_FILE}${RESET}"
    echo ""
}
