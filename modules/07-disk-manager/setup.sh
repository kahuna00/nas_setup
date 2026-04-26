#!/usr/bin/env bash
# modules/07-disk-manager/setup.sh — Módulo 7: Gestión de discos
# Opciones: formatear, copiar desde NFS remoto, gestionar montaje y symlinks

NAS_SETUP_DIR="$(dirname "$(dirname "$(dirname "${BASH_SOURCE[0]}")")")"

source "${NAS_SETUP_DIR}/modules/07-disk-manager/disk-ops.sh"
source "${NAS_SETUP_DIR}/modules/07-disk-manager/nfs-copy.sh"

setup_disk_manager() {
    print_header "GESTIÓN DE DISCOS"

    while true; do
        echo -e "  ${BOLD}¿Qué deseas hacer?${RESET}"
        echo ""
        echo -e "  ${CYAN}[1]${RESET} ${BOLD}Formatear disco${RESET}"
        echo -e "      Formatea un disco, elige punto de montaje y lo registra en fstab"
        echo ""
        echo -e "  ${CYAN}[2]${RESET} ${BOLD}Copiar desde NFS remoto${RESET}"
        echo -e "      Selecciona carpetas del NFS remoto (${NFS_SYNC_REMOTE_HOST:-remoto}) y cópialas aquí"
        echo ""
        echo -e "  ${CYAN}[3]${RESET} ${BOLD}Gestionar montaje y acceso${RESET}"
        echo -e "      Montar · Desmontar · Crear symlink para compartir vía NFS / Samba"
        echo ""
        echo -e "  ${DIM}[0]${RESET} Volver"
        echo ""

        local choice
        read -rp "$(echo -e "  ${BOLD}Opción: ${RESET}")" choice

        case "$choice" in
            1) dm_format_disk ;;
            2) dm_copy_from_nfs ;;
            3) dm_manage_mounts ;;
            0) return 0 ;;
            *) log_warn "Opción inválida" ;;
        esac
        echo ""
    done
}
