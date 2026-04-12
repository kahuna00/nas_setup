#!/usr/bin/env bash
# modules/02-mergerfs-snapraid/setup.sh — Módulo 2: MergerFS + SnapRAID guided setup
# Uso: sourced desde install.sh, llamar setup_mergerfs_snapraid()

NAS_SETUP_DIR="$(dirname "$(dirname "$(dirname "${BASH_SOURCE[0]}")")")"

# Source module files
source "${NAS_SETUP_DIR}/modules/02-mergerfs-snapraid/discover.sh"
source "${NAS_SETUP_DIR}/modules/02-mergerfs-snapraid/assign.sh"
source "${NAS_SETUP_DIR}/modules/02-mergerfs-snapraid/estimate.sh"
source "${NAS_SETUP_DIR}/modules/02-mergerfs-snapraid/format.sh"
source "${NAS_SETUP_DIR}/modules/02-mergerfs-snapraid/mergerfs.sh"
source "${NAS_SETUP_DIR}/modules/02-mergerfs-snapraid/snapraid.sh"
source "${NAS_SETUP_DIR}/modules/02-mergerfs-snapraid/schedule.sh"

setup_mergerfs_snapraid() {
    print_header "MÓDULO 2: MERGERFS + SNAPRAID (CONFIGURACIÓN GUIADA)"

    # ── Validar variables requeridas ───────────────────────────────────────────
    validate_env \
        MERGERFS_POOL_PATH \
        MERGERFS_CREATE_POLICY \
        DISK_MOUNT_PREFIX \
        SNAPRAID_SYNC_HOUR \
        SNAPRAID_SCRUB_DAY \
        SNAPRAID_SCRUB_PERCENT \
        SNAPRAID_DIFF_THRESHOLD || return 1

    # ── Instalar dependencias de detección ─────────────────────────────────────
    apt_update_once
    pkg_install lsblk parted bc 2>/dev/null || true

    # ══════════════════════════════════════════════════════════════════════════
    print_step "1" "Descubrimiento de discos"
    # ══════════════════════════════════════════════════════════════════════════
    discover_disks || return 1
    print_disk_table

    # ══════════════════════════════════════════════════════════════════════════
    print_step "2" "Asignación de roles (DATA / PARITY / SKIP)"
    # ══════════════════════════════════════════════════════════════════════════
    interactive_role_assignment
    confirm_roles || {
        log_warn "Configuración cancelada en asignación de roles"
        return 0
    }

    if [[ ${#DATA_DISKS[@]} -eq 0 ]]; then
        log_error "No se asignó ningún disco DATA — cancelando"
        return 1
    fi

    # ══════════════════════════════════════════════════════════════════════════
    print_step "3" "Estimación de espacio"
    # ══════════════════════════════════════════════════════════════════════════
    print_space_estimate

    # ══════════════════════════════════════════════════════════════════════════
    print_step "4" "Formateo de discos (opcional)"
    # ══════════════════════════════════════════════════════════════════════════
    echo ""
    echo -e "  ${YELLOW}${BOLD}¿Necesitas formatear los discos?${RESET}"
    echo -e "  • Selecciona ${BOLD}SÍ${RESET} si los discos son nuevos o quieres borrar todo"
    echo -e "  • Selecciona ${BOLD}NO${RESET} si ya tienes los discos montados y con datos"
    echo ""

    if confirm "¿Formatear discos DATA?" "N"; then
        format_data_disks || return 1
    else
        log_info "Saltando formateo DATA — registrando discos existentes en fstab..."
        map_existing_mountpoints
        register_existing_disks "data" "${DATA_DISKS[@]}"
    fi

    if [[ ${#PARITY_DISKS[@]} -gt 0 ]]; then
        if confirm "¿Formatear discos PARITY?" "N"; then
            format_parity_disks || return 1
        else
            log_info "Saltando formateo PARITY — registrando discos existentes en fstab..."
            map_existing_mountpoints
            register_existing_disks "parity" "${PARITY_DISKS[@]}"
        fi
    fi
    mount_all_disks || log_warn "Algunos discos no se pudieron montar — verifica /etc/fstab"

    # ══════════════════════════════════════════════════════════════════════════
    print_step "5" "Configurando MergerFS"
    # ══════════════════════════════════════════════════════════════════════════
    configure_mergerfs || return 1

    # ══════════════════════════════════════════════════════════════════════════
    print_step "6" "Configurando SnapRAID"
    # ══════════════════════════════════════════════════════════════════════════
    configure_snapraid || return 1

    # ══════════════════════════════════════════════════════════════════════════
    print_step "7" "Configurando schedule automático"
    # ══════════════════════════════════════════════════════════════════════════
    configure_schedule || return 1

    # ── Resumen final ──────────────────────────────────────────────────────────
    echo ""
    log_success "═══════════════════════════════════════════════"
    log_success "Módulo 2 completado exitosamente"
    log_success "═══════════════════════════════════════════════"
    echo ""
    echo -e "  ${BOLD}Próximos pasos:${RESET}"
    echo -e "  ${CYAN}1.${RESET} Ejecuta ${BOLD}snapraid sync${RESET} para inicializar la paridad (primera vez)"
    echo -e "  ${CYAN}2.${RESET} Verifica con ${BOLD}snapraid status${RESET}"
    echo -e "  ${CYAN}3.${RESET} El pool unificado está en: ${BOLD}${MERGERFS_POOL_PATH}${RESET}"
    echo -e "  ${CYAN}4.${RESET} Para exponer el pool vía NFS/Samba:"
    echo -e "     Añade ${BOLD}${MERGERFS_POOL_PATH}${RESET} a ${BOLD}NFS_EXTRA_DIRS${RESET} en .env"
    echo -e "     y re-ejecuta el Módulo 1"
    echo ""

    if [[ ${#PARITY_DISKS[@]} -gt 0 ]]; then
        print_warning "Recuerda ejecutar 'snapraid sync' antes de escribir datos al pool.
  Sin sync inicial, SnapRAID no puede recuperar archivos perdidos."
    fi
    echo ""
}
