#!/usr/bin/env bash
# modules/02-mergerfs-snapraid/format.sh — Disk formatting and fstab management
# Depends on: assign.sh (DATA_DISKS, PARITY_DISKS)

DISK_MOUNT_PREFIX="${DISK_MOUNT_PREFIX:-/mnt}"

# Global: populated by mount_individual_disks()
declare -gA DISK_MOUNTPOINT=()  # dev → mountpoint

_format_disk() {
    local dev="$1"
    local label="$2"

    log_info "Formateando ${dev} con etiqueta '${label}'..."

    # Safety: unmount if mounted
    if mountpoint -q "$dev" 2>/dev/null || grep -q "^${dev}" /proc/mounts 2>/dev/null; then
        log_warn "Desmontando ${dev} antes de formatear..."
        umount "$dev" 2>/dev/null || true
    fi

    # Create GPT partition table
    log_cmd "parted: crear tabla GPT en ${dev}" \
        parted -s "$dev" mklabel gpt || return 1

    # Create single partition using full disk
    log_cmd "parted: crear partición en ${dev}" \
        parted -s "$dev" mkpart primary 0% 100% || return 1

    # Wait for kernel to recognize new partition
    sleep 1
    partprobe "$dev" 2>/dev/null || true
    sleep 1

    # Get partition device (handle nvme naming: nvme0n1p1 vs sda1)
    local part_dev
    if [[ "$dev" =~ nvme ]]; then
        part_dev="${dev}p1"
    else
        part_dev="${dev}1"
    fi

    # Format ext4 with label
    log_cmd "mkfs.ext4 en ${part_dev}" \
        mkfs.ext4 -L "$label" -m 1 "$part_dev" || return 1

    log_success "Disco ${dev} formateado como ext4 con etiqueta '${label}'"
    echo "$part_dev"
}

_add_fstab_entry() {
    local uuid="$1"
    local mountpoint="$2"
    local label="$3"

    # Check if already in fstab
    if grep -q "UUID=${uuid}" /etc/fstab; then
        log_debug "UUID ${uuid} ya existe en /etc/fstab — saltando"
        return 0
    fi

    # Create mountpoint
    mkdir -p "$mountpoint"

    # Append to fstab
    echo "" >> /etc/fstab
    echo "# nas-setup: ${label} (${mountpoint})" >> /etc/fstab
    echo "UUID=${uuid}  ${mountpoint}  ext4  defaults,nofail,x-systemd.device-timeout=5  0  2" >> /etc/fstab

    log_success "fstab actualizado: UUID=${uuid} → ${mountpoint}"
}

format_data_disks() {
    [[ ${#DATA_DISKS[@]} -eq 0 ]] && return 0

    echo ""
    echo -e "  ${BOLD}Discos DATA a formatear:${RESET}"
    local idx=1
    for dev in "${DATA_DISKS[@]}"; do
        echo -e "  ${RED}  • ${dev} (${DISK_SIZE[$dev]}) — ${BOLD}SE BORRARÁN TODOS LOS DATOS${RESET}"
        ((idx++))
    done
    echo ""

    confirm "¿Formatear los discos DATA listados? (IRREVERSIBLE)" "N" || {
        log_info "Formateo cancelado. Se asumirá que los discos ya están formateados."
        return 0
    }

    local idx=1
    for dev in "${DATA_DISKS[@]}"; do
        local label="data${idx}"
        local part_dev
        part_dev=$(_format_disk "$dev" "$label") || {
            log_error "Falló el formateo de ${dev}"
            return 1
        }
        local uuid
        uuid=$(blkid -s UUID -o value "$part_dev")
        local mp="${DISK_MOUNT_PREFIX}/${label}"
        _add_fstab_entry "$uuid" "$mp" "$label"
        DISK_MOUNTPOINT["$dev"]="$mp"
        ((idx++))
    done
}

format_parity_disks() {
    [[ ${#PARITY_DISKS[@]} -eq 0 ]] && return 0

    echo ""
    echo -e "  ${BOLD}Discos PARITY a formatear:${RESET}"
    for dev in "${PARITY_DISKS[@]}"; do
        echo -e "  ${RED}  • ${dev} (${DISK_SIZE[$dev]}) — ${BOLD}SE BORRARÁN TODOS LOS DATOS${RESET}"
    done
    echo ""

    confirm "¿Formatear los discos PARITY listados? (IRREVERSIBLE)" "N" || {
        log_info "Formateo cancelado. Se asumirá que los discos de paridad ya están formateados."
        return 0
    }

    local idx=1
    for dev in "${PARITY_DISKS[@]}"; do
        local label="parity${idx}"
        local part_dev
        part_dev=$(_format_disk "$dev" "$label") || {
            log_error "Falló el formateo de ${dev}"
            return 1
        }
        local uuid
        uuid=$(blkid -s UUID -o value "$part_dev")
        local mp="${DISK_MOUNT_PREFIX}/${label}"
        _add_fstab_entry "$uuid" "$mp" "$label"
        DISK_MOUNTPOINT["$dev"]="$mp"
        ((idx++))
    done
}

# If disks already formatted (no format requested), map them to mountpoints
map_existing_mountpoints() {
    local idx=1
    for dev in "${DATA_DISKS[@]}"; do
        if [[ -z "${DISK_MOUNTPOINT[$dev]:-}" ]]; then
            DISK_MOUNTPOINT["$dev"]="${DISK_MOUNT_PREFIX}/data${idx}"
            log_debug "Mountpoint asumido: ${dev} → ${DISK_MOUNTPOINT[$dev]}"
        fi
        ((idx++))
    done
    idx=1
    for dev in "${PARITY_DISKS[@]}"; do
        if [[ -z "${DISK_MOUNTPOINT[$dev]:-}" ]]; then
            DISK_MOUNTPOINT["$dev"]="${DISK_MOUNT_PREFIX}/parity${idx}"
            log_debug "Mountpoint asumido: ${dev} → ${DISK_MOUNTPOINT[$dev]}"
        fi
        ((idx++))
    done
}

mount_all_disks() {
    log_info "Montando discos vía fstab..."
    mount -a 2>&1 | tee -a "$LOG_FILE" || log_warn "Algunos discos pueden no haberse montado correctamente"

    # Verify each disk is mounted
    local all_ok=1
    for dev in "${DATA_DISKS[@]}" "${PARITY_DISKS[@]}"; do
        local mp="${DISK_MOUNTPOINT[$dev]:-}"
        [[ -z "$mp" ]] && continue
        if mountpoint -q "$mp"; then
            log_success "Montado: ${mp}"
        else
            log_error "No se pudo montar: ${mp} (${dev})"
            all_ok=0
        fi
    done

    [[ "$all_ok" -eq 1 ]] || return 1
}
