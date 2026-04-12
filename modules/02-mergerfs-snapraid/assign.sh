#!/usr/bin/env bash
# modules/02-mergerfs-snapraid/assign.sh — Interactive disk role assignment
# Depends on: discover.sh (ALL_DISKS, DISK_* arrays must be populated)

# Output arrays
declare -ga DATA_DISKS=()
declare -ga PARITY_DISKS=()

_print_assignment_guide() {
    echo ""
    echo -e "  ${BOLD}Asignación de roles:${RESET}"
    echo -e "  ${CYAN}[d]${RESET} DATA   — Disco de datos. MergerFS lo incluye en el pool unificado."
    echo -e "  ${CYAN}[p]${RESET} PARITY — Disco de paridad. SnapRAID guarda información de recuperación."
    echo -e "  ${CYAN}[s]${RESET} SKIP   — Ignorar este disco (no se incluye en el array)."
    echo ""
    print_recommendation "Reglas de SnapRAID:
  • El disco de paridad debe ser ≥ al disco de datos más grande
  • Con 1 parity disk: tolera 1 fallo de disco
  • Con 2 parity disks: tolera 2 fallos simultáneos
  • SnapRAID es ideal para HDDs; SSDs se desgastan más con syncs frecuentes"
    echo ""
}

interactive_role_assignment() {
    DATA_DISKS=()
    PARITY_DISKS=()

    _print_assignment_guide

    local idx=1
    for dev in "${ALL_DISKS[@]}"; do
        local type_warn=""
        [[ "${DISK_TYPE[$dev]}" == "SSD" || "${DISK_TYPE[$dev]}" == "NVMe" ]] && \
            type_warn=" ${YELLOW}[SSD — no recomendado como parity]${RESET}"

        local smart_warn=""
        [[ "${DISK_SMART[$dev]}" == "FAILED" ]] && \
            smart_warn=" ${RED}[SMART FAILED — usar con precaución]${RESET}"

        echo -e "  ${BOLD}[${idx}] ${dev}${RESET} — ${CYAN}${DISK_SIZE[$dev]}${RESET} ${DISK_MODEL[$dev]}${type_warn}${smart_warn}"

        local role=""
        while true; do
            read -rp "$(echo -e "      Rol ${BOLD}[d/p/s]${RESET}: ")" role
            role="${role,,}"
            case "$role" in
                d|data)
                    DATA_DISKS+=("$dev")
                    log_info "  → ${dev} asignado como DATA"
                    break
                    ;;
                p|parity)
                    PARITY_DISKS+=("$dev")
                    log_info "  → ${dev} asignado como PARITY"
                    if [[ "${DISK_TYPE[$dev]}" == "SSD" || "${DISK_TYPE[$dev]}" == "NVMe" ]]; then
                        print_warning "Usas un SSD como disco de paridad. Considera usar un HDD para menor desgaste."
                    fi
                    break
                    ;;
                s|skip)
                    log_info "  → ${dev} ignorado"
                    break
                    ;;
                *)
                    echo -e "  ${RED}Opción inválida. Escribe d (data), p (parity) o s (skip)${RESET}"
                    ;;
            esac
        done
        echo ""
        ((idx++))
    done
}

validate_parity_size() {
    if [[ ${#PARITY_DISKS[@]} -eq 0 ]]; then
        log_warn "No se seleccionó ningún disco de paridad — SnapRAID no ofrecerá protección contra fallos"
        confirm "¿Continuar sin disco de paridad?" "N" || return 1
        return 0
    fi

    # Find the largest data disk
    local max_data_bytes=0
    local max_data_dev=""
    for dev in "${DATA_DISKS[@]}"; do
        local bytes="${DISK_SIZE_BYTES[$dev]}"
        if [[ "$bytes" -gt "$max_data_bytes" ]]; then
            max_data_bytes="$bytes"
            max_data_dev="$dev"
        fi
    done

    # Validate each parity disk is large enough
    local failed=0
    for pdev in "${PARITY_DISKS[@]}"; do
        local parity_bytes="${DISK_SIZE_BYTES[$pdev]}"
        if [[ "$parity_bytes" -lt "$max_data_bytes" ]]; then
            log_error "Disco de paridad ${pdev} (${DISK_SIZE[$pdev]}) es más pequeño que el disco de datos más grande: ${max_data_dev} (${DISK_SIZE[$max_data_dev]})"
            log_error "SnapRAID requiere que el disco de paridad sea ≥ al disco de datos más grande"
            failed=1
        fi
    done

    [[ "$failed" -eq 1 ]] && return 1
    return 0
}

print_role_summary() {
    echo ""
    echo -e "  ${BOLD}${WHITE}Resumen de asignación de roles:${RESET}"
    echo ""

    if [[ ${#DATA_DISKS[@]} -gt 0 ]]; then
        echo -e "  ${GREEN}${BOLD}DATA disks (${#DATA_DISKS[@]}):${RESET}"
        for dev in "${DATA_DISKS[@]}"; do
            echo -e "    ${GREEN}●${RESET} ${dev} — ${DISK_SIZE[$dev]} ${DISK_MODEL[$dev]}"
        done
    fi

    echo ""

    if [[ ${#PARITY_DISKS[@]} -gt 0 ]]; then
        echo -e "  ${YELLOW}${BOLD}PARITY disks (${#PARITY_DISKS[@]}):${RESET}"
        for dev in "${PARITY_DISKS[@]}"; do
            echo -e "    ${YELLOW}●${RESET} ${dev} — ${DISK_SIZE[$dev]} ${DISK_MODEL[$dev]}"
        done
    else
        echo -e "  ${YELLOW}  Sin discos de paridad — array sin protección${RESET}"
    fi

    echo ""
}

confirm_roles() {
    print_role_summary
    validate_parity_size || return 1
    confirm "¿Confirmar asignación de roles y continuar?" "Y" || return 1
}
