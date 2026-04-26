#!/usr/bin/env bash
# modules/02-mergerfs-snapraid/setup.sh — Módulo 2: MergerFS + SnapRAID guided setup
# Uso: sourced desde install.sh, llamar setup_mergerfs() / setup_snapraid()

NAS_SETUP_DIR="$(dirname "$(dirname "$(dirname "${BASH_SOURCE[0]}")")")"

# Source module files
source "${NAS_SETUP_DIR}/modules/02-mergerfs-snapraid/discover.sh"
source "${NAS_SETUP_DIR}/modules/02-mergerfs-snapraid/assign.sh"
source "${NAS_SETUP_DIR}/modules/02-mergerfs-snapraid/estimate.sh"
source "${NAS_SETUP_DIR}/modules/02-mergerfs-snapraid/format.sh"
source "${NAS_SETUP_DIR}/modules/02-mergerfs-snapraid/mergerfs.sh"
source "${NAS_SETUP_DIR}/modules/02-mergerfs-snapraid/snapraid.sh"
source "${NAS_SETUP_DIR}/modules/02-mergerfs-snapraid/schedule.sh"

# ── Helpers compartidos ────────────────────────────────────────────────────────

_discover_and_assign() {
    apt_update_once
    pkg_install lsblk parted bc 2>/dev/null || true

    print_step "1" "Descubrimiento de discos"
    discover_disks || return 1
    print_disk_table

    print_step "2" "Asignación de roles (DATA / PARITY / SKIP)"
    interactive_role_assignment
    confirm_roles || {
        log_warn "Configuración cancelada en asignación de roles"
        return 1
    }

    if [[ ${#DATA_DISKS[@]} -eq 0 ]]; then
        log_error "No se asignó ningún disco DATA — cancelando"
        return 1
    fi
}

_format_or_map_disks() {
    print_step "3" "Estimación de espacio"
    print_space_estimate

    print_step "4" "Formateo de discos (opcional)"
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
}

# ── MergerFS ───────────────────────────────────────────────────────────────────

setup_mergerfs() {
    print_header "MERGERFS"

    echo -e "  ${BOLD}¿Qué deseas hacer?${RESET}"
    echo ""
    echo -e "  ${CYAN}[1]${RESET} Instalar / configurar  ${DIM}(descubrimiento de discos, formateo y pool)${RESET}"
    echo -e "  ${CYAN}[2]${RESET} ${RED}Desactivar MergerFS${RESET}  ${DIM}(desmonta el pool y elimina entradas fstab)${RESET}"
    echo -e "  ${CYAN}[0]${RESET} Volver"
    echo ""

    local choice
    read -rp "$(echo -e "  ${BOLD}Opción: ${RESET}")" choice

    case "$choice" in
        1) _install_mergerfs ;;
        2) disable_mergerfs ;;
        0) return 0 ;;
        *) log_warn "Opción inválida" ;;
    esac
}

_install_mergerfs() {
    validate_env \
        MERGERFS_POOL_PATH \
        MERGERFS_CREATE_POLICY \
        DISK_MOUNT_PREFIX || return 1

    _discover_and_assign || return 1
    _format_or_map_disks || return 1

    print_step "5" "Configurando MergerFS"
    configure_mergerfs || return 1

    echo ""
    log_success "MergerFS configurado — pool: ${MERGERFS_POOL_PATH}"
    echo -e "  ${DIM}df -h ${MERGERFS_POOL_PATH}${RESET}"
    echo ""
    echo -e "  ${BOLD}Próximo paso:${RESET} configura SnapRAID (opción 4 del menú) para añadir paridad."
    echo ""
}

# ── SnapRAID ───────────────────────────────────────────────────────────────────

setup_snapraid() {
    print_header "SNAPRAID"

    echo -e "  ${BOLD}¿Qué deseas hacer?${RESET}"
    echo ""
    echo -e "  ${CYAN}[1]${RESET} Instalar / configurar  ${DIM}(genera snapraid.conf y timers)${RESET}"
    echo -e "  ${CYAN}[2]${RESET} ${RED}Desactivar SnapRAID${RESET}  ${DIM}(detiene timers y elimina configuración)${RESET}"
    echo -e "  ${CYAN}[0]${RESET} Volver"
    echo ""

    local choice
    read -rp "$(echo -e "  ${BOLD}Opción: ${RESET}")" choice

    case "$choice" in
        1) _install_snapraid ;;
        2) disable_snapraid ;;
        0) return 0 ;;
        *) log_warn "Opción inválida" ;;
    esac
}

_install_snapraid() {
    validate_env \
        SNAPRAID_SYNC_HOUR \
        SNAPRAID_SCRUB_DAY \
        SNAPRAID_SCRUB_PERCENT \
        SNAPRAID_DIFF_THRESHOLD || return 1

    # Si los arrays no están poblados (ejecución independiente), re-descubrir
    if [[ ${#DATA_DISKS[@]} -eq 0 ]]; then
        log_info "Arrays de discos no cargados — ejecutando descubrimiento..."
        apt_update_once
        pkg_install lsblk parted bc 2>/dev/null || true

        print_step "1" "Descubrimiento de discos"
        discover_disks || return 1
        print_disk_table

        print_step "2" "Asignación de roles (DATA / PARITY / SKIP)"
        log_info "Selecciona los mismos discos que ya tienes configurados en MergerFS."
        interactive_role_assignment
        confirm_roles || { log_warn "Cancelado en asignación de roles"; return 0; }

        if [[ ${#DATA_DISKS[@]} -eq 0 ]]; then
            log_error "No se asignaron discos DATA"
            return 1
        fi

        # No formatear — solo mapear mountpoints existentes
        map_existing_mountpoints
    fi

    print_step "3" "Configurando SnapRAID"
    configure_snapraid || return 1

    print_step "4" "Configurando schedule automático"
    configure_schedule || return 1

    echo ""
    log_success "SnapRAID configurado"
    echo -e "  ${BOLD}Próximos pasos:${RESET}"
    echo -e "  ${CYAN}1.${RESET} Ejecuta ${BOLD}snapraid sync${RESET} para inicializar la paridad (primera vez)"
    echo -e "  ${CYAN}2.${RESET} Verifica con ${BOLD}snapraid status${RESET}"
    echo ""
    if [[ ${#PARITY_DISKS[@]} -gt 0 ]]; then
        log_warn "Recuerda ejecutar 'snapraid sync' antes de escribir datos al pool."
    fi
    echo ""
}

# ── Función legacy: MergerFS + SnapRAID combinados ─────────────────────────────

setup_mergerfs_snapraid() {
    print_header "MERGERFS + SNAPRAID (CONFIGURACIÓN GUIADA)"

    validate_env \
        MERGERFS_POOL_PATH \
        MERGERFS_CREATE_POLICY \
        DISK_MOUNT_PREFIX \
        SNAPRAID_SYNC_HOUR \
        SNAPRAID_SCRUB_DAY \
        SNAPRAID_SCRUB_PERCENT \
        SNAPRAID_DIFF_THRESHOLD || return 1

    _discover_and_assign || return 1
    _format_or_map_disks || return 1

    print_step "5" "Configurando MergerFS"
    configure_mergerfs || return 1

    print_step "6" "Configurando SnapRAID"
    configure_snapraid || return 1

    print_step "7" "Configurando schedule automático"
    configure_schedule || return 1

    echo ""
    log_success "═══════════════════════════════════════════════"
    log_success "MergerFS + SnapRAID completados"
    log_success "═══════════════════════════════════════════════"
    echo ""
    echo -e "  ${BOLD}Próximos pasos:${RESET}"
    echo -e "  ${CYAN}1.${RESET} Ejecuta ${BOLD}snapraid sync${RESET} para inicializar la paridad"
    echo -e "  ${CYAN}2.${RESET} Verifica con ${BOLD}snapraid status${RESET}"
    echo -e "  ${CYAN}3.${RESET} El pool unificado está en: ${BOLD}${MERGERFS_POOL_PATH}${RESET}"
    echo ""
    if [[ ${#PARITY_DISKS[@]} -gt 0 ]]; then
        log_warn "Recuerda ejecutar 'snapraid sync' antes de escribir datos al pool."
    fi
    echo ""
}
