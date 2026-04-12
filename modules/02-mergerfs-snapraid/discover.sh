#!/usr/bin/env bash
# modules/02-mergerfs-snapraid/discover.sh — Disk discovery and health survey
# Depends on: lib/{colors,logging,os}.sh

# Global arrays populated by discover_disks()
declare -ga ALL_DISKS=()       # device paths: /dev/sda, /dev/sdb, ...
declare -gA DISK_SIZE=()       # size string: "4.0T", "500G"
declare -gA DISK_SIZE_BYTES=() # size in bytes for comparison
declare -gA DISK_MODEL=()      # model string
declare -gA DISK_SERIAL=()     # serial number
declare -gA DISK_SMART=()      # PASSED / FAILED / UNKNOWN
declare -gA DISK_TYPE=()       # HDD / SSD / NVMe

BOOT_DISK=""

_get_boot_disk() {
    local root_dev
    root_dev=$(findmnt -n -o SOURCE / | sed 's/[0-9]*$//' | sed 's/p[0-9]*$//')
    # Handle nvme device names (e.g. /dev/nvme0n1p1 → /dev/nvme0n1)
    BOOT_DISK=$(lsblk -dpno PKNAME "$root_dev" 2>/dev/null || echo "$root_dev")
    log_debug "Disco de boot detectado: $BOOT_DISK"
}

_bytes_from_size() {
    # lsblk --bytes gives raw bytes
    local dev="$1"
    lsblk -dnbo SIZE "$dev" 2>/dev/null || echo "0"
}

_human_size() {
    local bytes="$1"
    local gb=$((bytes / 1024 / 1024 / 1024))
    if [[ $gb -ge 1000 ]]; then
        printf "%.1fT" "$(echo "scale=1; $gb / 1024" | bc)"
    else
        printf "%dG" "$gb"
    fi
}

_get_smart_info() {
    local dev="$1"
    local smart_health="UNKNOWN"
    local disk_type="HDD"

    if command -v smartctl &>/dev/null; then
        local smart_output
        smart_output=$(smartctl -i "$dev" 2>/dev/null)

        # Determine type
        if echo "$smart_output" | grep -q "NVMe"; then
            disk_type="NVMe"
        elif echo "$smart_output" | grep -qE "Solid State|SSD|0 rpm|Rotation Rate.*Solid"; then
            disk_type="SSD"
        elif echo "$smart_output" | grep -qE "Rotation Rate.*[1-9][0-9]+ rpm"; then
            disk_type="HDD"
        fi

        # Health check
        local health
        health=$(smartctl -H "$dev" 2>/dev/null | grep -oE "PASSED|FAILED" | head -1)
        smart_health="${health:-UNKNOWN}"
    fi

    echo "${smart_health}|${disk_type}"
}

discover_disks() {
    log_info "Escaneando discos disponibles..."

    pkg_install smartmontools 2>/dev/null || log_warn "smartmontools no disponible — sin info SMART"

    _get_boot_disk

    ALL_DISKS=()

    while IFS= read -r dev; do
        [[ -z "$dev" ]] && continue

        # Skip the boot disk
        if [[ "$dev" == "$BOOT_DISK" ]]; then
            log_debug "Saltando disco de boot: $dev"
            continue
        fi

        # Skip loop, rom, etc.
        local type
        type=$(lsblk -dnpo TYPE "$dev" 2>/dev/null)
        [[ "$type" != "disk" ]] && continue

        ALL_DISKS+=("$dev")

        DISK_SIZE_BYTES["$dev"]=$(_bytes_from_size "$dev")
        DISK_SIZE["$dev"]=$(_human_size "${DISK_SIZE_BYTES[$dev]}")
        DISK_MODEL["$dev"]=$(lsblk -dnpo MODEL "$dev" 2>/dev/null | sed 's/[[:space:]]*$//' || echo "Unknown")
        DISK_SERIAL["$dev"]=$(lsblk -dnpo SERIAL "$dev" 2>/dev/null | sed 's/[[:space:]]*$//' || echo "Unknown")

        local smart_info
        smart_info=$(_get_smart_info "$dev")
        DISK_SMART["$dev"]="${smart_info%%|*}"
        DISK_TYPE["$dev"]="${smart_info##*|}"

    done < <(lsblk -dpno NAME)

    if [[ ${#ALL_DISKS[@]} -eq 0 ]]; then
        log_error "No se encontraron discos disponibles (excluyendo disco de boot: $BOOT_DISK)"
        return 1
    fi

    log_success "Encontrados ${#ALL_DISKS[@]} disco(s) disponible(s)"
}

print_disk_table() {
    echo ""
    echo -e "  ${BOLD}${WHITE}Discos disponibles:${RESET}"
    echo ""
    printf "  ${BOLD}%-4s %-12s %-8s %-28s %-14s %-8s %-8s${RESET}\n" \
        "#" "DISPOSITIVO" "TAMAÑO" "MODELO" "SERIAL" "SALUD" "TIPO"
    printf "  %-4s %-12s %-8s %-28s %-14s %-8s %-8s\n" \
        "────" "────────────" "────────" "────────────────────────────" "──────────────" "────────" "────────"

    local idx=1
    for dev in "${ALL_DISKS[@]}"; do
        local health_color="$GREEN"
        [[ "${DISK_SMART[$dev]}" == "FAILED" ]] && health_color="$RED"
        [[ "${DISK_SMART[$dev]}" == "UNKNOWN" ]] && health_color="$YELLOW"

        local type_color="$CYAN"
        [[ "${DISK_TYPE[$dev]}" == "SSD" || "${DISK_TYPE[$dev]}" == "NVMe" ]] && type_color="$MAGENTA"

        printf "  ${BOLD}%-4s${RESET} %-12s ${CYAN}%-8s${RESET} %-28s %-14s ${health_color}%-8s${RESET} ${type_color}%-8s${RESET}\n" \
            "[$idx]" \
            "$dev" \
            "${DISK_SIZE[$dev]}" \
            "${DISK_MODEL[$dev]:0:28}" \
            "${DISK_SERIAL[$dev]:0:14}" \
            "${DISK_SMART[$dev]}" \
            "${DISK_TYPE[$dev]}"
        ((idx++))
    done
    echo ""

    # Warn about disks with FAILED SMART
    for dev in "${ALL_DISKS[@]}"; do
        if [[ "${DISK_SMART[$dev]}" == "FAILED" ]]; then
            print_warning "El disco ${dev} reporta fallo SMART — NO recomendado para uso en el array"
        fi
    done
}
