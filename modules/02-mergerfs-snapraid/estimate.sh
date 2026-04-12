#!/usr/bin/env bash
# modules/02-mergerfs-snapraid/estimate.sh — Space estimation calculator
# Depends on: assign.sh (DATA_DISKS, PARITY_DISKS, DISK_SIZE_BYTES arrays)

print_space_estimate() {
    if [[ ${#DATA_DISKS[@]} -eq 0 ]]; then
        log_warn "No hay discos DATA asignados — no se puede calcular espacio"
        return
    fi

    local total_data_bytes=0
    local total_parity_bytes=0

    for dev in "${DATA_DISKS[@]}"; do
        total_data_bytes=$((total_data_bytes + DISK_SIZE_BYTES[$dev]))
    done
    for dev in "${PARITY_DISKS[@]}"; do
        total_parity_bytes=$((total_parity_bytes + DISK_SIZE_BYTES[$dev]))
    done

    local total_gb=$((total_data_bytes / 1024 / 1024 / 1024))
    local parity_gb=$((total_parity_bytes / 1024 / 1024 / 1024))
    local total_tb; total_tb=$(printf "%.1f" "$(echo "scale=1; $total_gb / 1024" | bc)")
    local parity_tb; parity_tb=$(printf "%.1f" "$(echo "scale=1; $parity_gb / 1024" | bc)")

    echo ""
    echo -e "  ${BOLD}${WHITE}┌─────────────────────────────────────────────┐${RESET}"
    echo -e "  ${BOLD}${WHITE}│       ESTIMACIÓN DE ESPACIO                  │${RESET}"
    echo -e "  ${BOLD}${WHITE}└─────────────────────────────────────────────┘${RESET}"
    echo ""
    echo -e "  ${GREEN}Espacio útil (datos)  : ${BOLD}${total_tb} TB${RESET}${GREEN} (${#DATA_DISKS[@]} disco(s))${RESET}"
    echo -e "  ${YELLOW}Overhead (paridad)    : ${BOLD}${parity_tb} TB${RESET}${YELLOW} (${#PARITY_DISKS[@]} disco(s))${RESET}"
    echo ""
    echo -e "  ${CYAN}Protección            : ${BOLD}${#PARITY_DISKS[@]} fallo(s) simultáneo(s)${RESET}"
    echo -e "  ${CYAN}Pool MergerFS en      : ${BOLD}${MERGERFS_POOL_PATH}${RESET}"
    echo -e "  ${CYAN}Política de escritura : ${BOLD}${MERGERFS_CREATE_POLICY}${RESET} (most-free-space)"
    echo ""

    print_recommendation "MergerFS no añade overhead de espacio — suma directamente los discos DATA.
  SnapRAID solo usa espacio en los discos PARITY, no en los DATA.
  El espacio mínimo de reserva por disco será 4GB (minfreespace en fstab)."
    echo ""
}
