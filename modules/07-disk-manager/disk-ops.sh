#!/usr/bin/env bash
# modules/07-disk-manager/disk-ops.sh — Formateo, montaje y symlinks de discos
# Depends on: lib/{colors,logging,env,idempotency}.sh

_DM_DIR="$(dirname "$(dirname "$(dirname "${BASH_SOURCE[0]}")")")"

# Globals de retorno para las funciones de selección
declare -g DM_SELECTED_DEV=""
declare -g DM_SELECTED_MP=""

# ── Helpers de detección ───────────────────────────────────────────────────────

_dm_get_boot_disk() {
    local root_src
    root_src=$(findmnt -n -o SOURCE / 2>/dev/null)
    # Strip partition suffix: sda1→sda, nvme0n1p1→nvme0n1
    echo "$root_src" | sed -E 's/(nvme[0-9]+n[0-9]+)p[0-9]+$/\1/' | sed -E 's/[0-9]+$//'
}

_dm_part_dev() {
    local disk="$1"
    if [[ "$disk" =~ nvme ]]; then
        echo "${disk}p1"
    else
        echo "${disk}1"
    fi
}

# ── Visualización de discos ────────────────────────────────────────────────────

_dm_show_disks() {
    echo ""
    echo -e "  ${BOLD}Estado actual de discos:${RESET}"
    echo ""
    printf "  ${BOLD}%-24s %-8s %-6s %-24s %-14s${RESET}\n" \
        "DISPOSITIVO" "TAMAÑO" "TIPO" "PUNTO DE MONTAJE" "ETIQUETA"
    printf "  %-24s %-8s %-6s %-24s %-14s\n" \
        "────────────────────────" "────────" "──────" "────────────────────────" "──────────────"

    while IFS= read -r line; do
        eval "$line" 2>/dev/null
        local color="${RESET}" indent=""
        [[ "$TYPE" == "disk" ]] && color="${BOLD}"
        [[ "$TYPE" == "part" || "$TYPE" == "lvm" ]] && indent="  └─"
        [[ -n "$MOUNTPOINT" ]] && color="${GREEN}"

        printf "  ${color}%-24s %-8s %-6s %-24s %-14s${RESET}\n" \
            "${indent}${NAME}" "$SIZE" "$TYPE" \
            "${MOUNTPOINT:--}" "${LABEL:--}"
    done < <(lsblk -pPo NAME,SIZE,TYPE,MOUNTPOINT,LABEL 2>/dev/null)
    echo ""
}

# ── Selección interactiva ──────────────────────────────────────────────────────

# Selecciona un disco completo (TYPE=disk). Resultado en DM_SELECTED_DEV.
_dm_pick_disk() {
    local -a names=() sizes=()
    local boot_disk
    boot_disk=$(_dm_get_boot_disk)

    printf "  ${BOLD}%-4s %-18s %-8s %-32s %-6s${RESET}\n" \
        "#" "DISPOSITIVO" "TAMAÑO" "MODELO" "BOOT"
    printf "  %-4s %-18s %-8s %-32s\n" \
        "────" "──────────────────" "────────" "────────────────────────────────"

    local idx=1
    while IFS= read -r line; do
        eval "$line" 2>/dev/null
        [[ "$TYPE" != "disk" ]] && continue
        local boot_flag=""
        [[ "$NAME" == "$boot_disk" ]] && boot_flag="${RED}[BOOT]${RESET}"
        printf "  ${BOLD}[%-2s]${RESET} %-18s ${CYAN}%-8s${RESET} %-32s %b\n" \
            "$idx" "$NAME" "$SIZE" "${MODEL:0:32}" "$boot_flag"
        names+=("$NAME")
        sizes+=("$SIZE")
        ((idx++))
    done < <(lsblk -pPo NAME,SIZE,TYPE,MODEL 2>/dev/null)

    [[ ${#names[@]} -eq 0 ]] && { log_error "No se encontraron discos"; return 1; }

    echo ""
    local sel
    read -rp "$(echo -e "  ${BOLD}Selecciona número (0=cancelar): ${RESET}")" sel </dev/tty

    [[ "$sel" == "0" || -z "$sel" ]] && return 1
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel-1 >= ${#names[@]} )); then
        log_warn "Número inválido"
        return 1
    fi

    DM_SELECTED_DEV="${names[$((sel-1))]}"
    return 0
}

# Selecciona una partición MONTADA. Resultado en DM_SELECTED_DEV y DM_SELECTED_MP.
_dm_pick_mounted_part() {
    local -a names=() mps=()

    printf "  ${BOLD}%-4s %-22s %-8s %-28s %-14s${RESET}\n" \
        "#" "PARTICIÓN" "TAMAÑO" "PUNTO DE MONTAJE" "ETIQUETA"
    printf "  %-4s %-22s %-8s %-28s\n" \
        "────" "──────────────────────" "────────" "────────────────────────────"

    local idx=1
    while IFS= read -r line; do
        eval "$line" 2>/dev/null
        [[ "$TYPE" != "part" && "$TYPE" != "lvm" ]] && continue
        [[ -z "$MOUNTPOINT" || "$MOUNTPOINT" == "-" ]] && continue
        printf "  ${BOLD}[%-2s]${RESET} %-22s ${CYAN}%-8s${RESET} ${GREEN}%-28s${RESET} %-14s\n" \
            "$idx" "$NAME" "$SIZE" "$MOUNTPOINT" "${LABEL:--}"
        names+=("$NAME")
        mps+=("$MOUNTPOINT")
        ((idx++))
    done < <(lsblk -pPo NAME,SIZE,TYPE,MOUNTPOINT,LABEL 2>/dev/null)

    if [[ ${#names[@]} -eq 0 ]]; then
        log_warn "No hay particiones montadas"
        return 1
    fi

    echo ""
    local sel
    read -rp "$(echo -e "  ${BOLD}Selecciona número (0=cancelar): ${RESET}")" sel </dev/tty

    [[ "$sel" == "0" || -z "$sel" ]] && return 1
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel-1 >= ${#names[@]} )); then
        log_warn "Número inválido"
        return 1
    fi

    DM_SELECTED_DEV="${names[$((sel-1))]}"
    DM_SELECTED_MP="${mps[$((sel-1))]}"
    return 0
}

# Selecciona una partición SIN MONTAR. Resultado en DM_SELECTED_DEV.
_dm_pick_unmounted_part() {
    local -a names=() sizes=() labels=()

    printf "  ${BOLD}%-4s %-22s %-8s %-14s${RESET}\n" \
        "#" "PARTICIÓN" "TAMAÑO" "ETIQUETA"
    printf "  %-4s %-22s %-8s\n" \
        "────" "──────────────────────" "────────"

    local idx=1
    while IFS= read -r line; do
        eval "$line" 2>/dev/null
        [[ "$TYPE" != "part" ]] && continue
        [[ -n "$MOUNTPOINT" && "$MOUNTPOINT" != "-" ]] && continue
        printf "  ${BOLD}[%-2s]${RESET} %-22s ${CYAN}%-8s${RESET} %-14s\n" \
            "$idx" "$NAME" "$SIZE" "${LABEL:--}"
        names+=("$NAME")
        sizes+=("$SIZE")
        labels+=("${LABEL:--}")
        ((idx++))
    done < <(lsblk -pPo NAME,SIZE,TYPE,MOUNTPOINT,LABEL 2>/dev/null)

    if [[ ${#names[@]} -eq 0 ]]; then
        log_warn "No hay particiones sin montar disponibles"
        return 1
    fi

    echo ""
    local sel
    read -rp "$(echo -e "  ${BOLD}Selecciona número (0=cancelar): ${RESET}")" sel </dev/tty

    [[ "$sel" == "0" || -z "$sel" ]] && return 1
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel-1 >= ${#names[@]} )); then
        log_warn "Número inválido"
        return 1
    fi

    DM_SELECTED_DEV="${names[$((sel-1))]}"
    return 0
}

# ── Operaciones de disco ───────────────────────────────────────────────────────

_dm_format_and_register() {
    local disk="$1" label="$2" mp="$3" fs="$4"
    local part_dev
    part_dev=$(_dm_part_dev "$disk")

    log_info "Creando tabla GPT en ${disk}..."
    parted -s "$disk" mklabel gpt || return 1

    log_info "Creando partición única en ${disk}..."
    parted -s "$disk" mkpart primary 0% 100% || return 1
    sleep 1; partprobe "$disk" 2>/dev/null || true; sleep 1

    log_info "Formateando ${part_dev} como ${fs} (etiqueta: ${label})..."
    case "$fs" in
        ext4) mkfs.ext4 -L "$label" -m 1 "$part_dev" >> "$LOG_FILE" 2>&1 || return 1 ;;
        xfs)  mkfs.xfs  -L "$label" -f  "$part_dev" >> "$LOG_FILE" 2>&1 || return 1 ;;
    esac

    local uuid
    uuid=$(blkid -s UUID -o value "$part_dev" 2>/dev/null)
    [[ -z "$uuid" ]] && { log_error "No se pudo leer UUID de ${part_dev}"; return 1; }

    mkdir -p "$mp"

    if ! grep -q "UUID=${uuid}" /etc/fstab; then
        {
            echo ""
            echo "# nas-setup: ${label} (${mp})"
            echo "UUID=${uuid}  ${mp}  ${fs}  defaults,nofail,x-systemd.device-timeout=5  0  2"
        } >> /etc/fstab
        log_success "fstab: UUID=${uuid} → ${mp}"
    fi

    mount "$mp" || return 1
    log_success "Disco formateado y montado en: ${mp}"
    echo ""
    df -h "$mp" | tail -1 | sed 's/^/  /'
}

# ── Symlink + exportación NFS/Samba ───────────────────────────────────────────

_dm_create_share_symlink() {
    local source_path="$1"
    local label="${2:-$(basename "$source_path")}"

    local default_link="${NFS_SHARE_DIR:-/nfs/kahunaz}/${label}"

    echo ""
    echo -e "  ${BOLD}Crear symlink de acceso${RESET}"
    echo -e "  Apunta a : ${CYAN}${source_path}${RESET}"
    echo ""

    local link_path
    link_path=$(prompt_env_value "Ruta del symlink" "$default_link")

    if [[ -L "$link_path" ]]; then
        log_warn "Ya existe symlink: ${link_path} → $(readlink "$link_path")"
        confirm "¿Reemplazar?" "N" || return 0
        rm "$link_path"
    elif [[ -e "$link_path" ]]; then
        log_error "${link_path} ya existe y no es un symlink — no se toca"
        return 1
    fi

    mkdir -p "$(dirname "$link_path")"
    ln -s "$source_path" "$link_path"
    log_success "Symlink creado: ${link_path} → ${source_path}"

    # ── Exportar vía NFS ──────────────────────────────────────────────────────
    echo ""
    if systemctl is-active --quiet nfs-server 2>/dev/null && \
       confirm "¿Añadir al export NFS? (actualiza NFS_EXTRA_DIRS y recarga exports)" "Y"; then

        local extras="${NFS_EXTRA_DIRS:-}"
        if echo "$extras" | grep -qF "$link_path"; then
            log_info "Ya está en NFS_EXTRA_DIRS"
        else
            local new_extras
            [[ -z "$extras" ]] && new_extras="$link_path" || new_extras="${extras}:${link_path}"
            set_env_var NFS_EXTRA_DIRS "$new_extras"
        fi

        source "${_DM_DIR}/modules/01-nfs-samba/nfs.sh"
        state_clear "nfs_configured"
        if render_exports && exportfs -ra; then
            log_success "NFS recargado — ${link_path} exportado"
        else
            log_warn "Exports renderizados pero exportfs falló — verifica con: exportfs -v"
        fi
    fi

    # ── Añadir share Samba ────────────────────────────────────────────────────
    echo ""
    if systemctl is-active --quiet smbd 2>/dev/null && \
       confirm "¿Añadir share Samba para este directorio?" "Y"; then

        # Samba extra shares usan NFS_EXTRA_DIRS — si ya lo añadimos arriba, OK
        # Si no se añadió a NFS_EXTRA_DIRS, lo hacemos aquí solo para Samba también
        local extras="${NFS_EXTRA_DIRS:-}"
        if ! echo "$extras" | grep -qF "$link_path"; then
            local new_extras
            [[ -z "$extras" ]] && new_extras="$link_path" || new_extras="${extras}:${link_path}"
            set_env_var NFS_EXTRA_DIRS "$new_extras"
        fi

        source "${_DM_DIR}/modules/01-nfs-samba/samba.sh"
        state_clear "samba_configured"
        if render_smb_conf && systemctl reload smbd; then
            log_success "Samba recargado — share '$(basename "$link_path" | tr '[:lower:]' '[:upper:]')' disponible"
        else
            log_warn "smb.conf renderizado pero reload falló — verifica con: testparm"
        fi
    fi
}

# ── Flujos públicos ────────────────────────────────────────────────────────────

dm_format_disk() {
    print_header "FORMATEAR DISCO"

    _dm_show_disks

    log_warn "Esta operación borrará PERMANENTEMENTE todos los datos del disco seleccionado."
    echo ""
    echo -e "  Selecciona el disco a formatear:"

    _dm_pick_disk || { log_info "Cancelado"; return 0; }
    local disk="$DM_SELECTED_DEV"
    local boot_disk
    boot_disk=$(_dm_get_boot_disk)

    if [[ "$disk" == "$boot_disk" ]]; then
        log_error "¡DISCO DE BOOT SELECCIONADO! Formatear destruirá el sistema operativo."
        confirm "¿Estás ABSOLUTAMENTE seguro?" "N" || return 0
    fi

    # Desmontar particiones activas si las hay
    local active_mps
    active_mps=$(lsblk -lpo MOUNTPOINT "$disk" 2>/dev/null | grep -v "^$\|^MOUNTPOINT\|-" || true)
    if [[ -n "$active_mps" ]]; then
        log_warn "El disco tiene particiones montadas:"
        lsblk -lpo NAME,MOUNTPOINT "$disk" | awk 'NR>1 && $2!="" && $2!="-" {print "    " $1 " → " $2}'
        echo ""
        confirm "¿Desmontar y continuar?" "N" || return 0
        while IFS= read -r part; do
            [[ -b "$part" ]] && umount "$part" 2>/dev/null || true
        done < <(lsblk -lpo NAME,MOUNTPOINT "$disk" 2>/dev/null | \
            awk 'NR>1 && $2!="" && $2!="-" {print $1}')
    fi

    # Etiqueta
    local disk_idx
    disk_idx=$(lsblk -dpno NAME | grep -c sd 2>/dev/null || echo "1")
    local label
    label=$(prompt_env_value "Etiqueta del disco" "disco${disk_idx}")

    # Punto de montaje
    local mp
    mp=$(prompt_env_value "Punto de montaje" "/mnt/${label}")

    # Filesystem
    echo ""
    echo -e "  ${BOLD}Sistema de archivos:${RESET}"
    echo -e "  ${CYAN}[1]${RESET} ext4  ${DIM}(recomendado — compatible con MergerFS y SnapRAID)${RESET}"
    echo -e "  ${CYAN}[2]${RESET} xfs   ${DIM}(mejor rendimiento con archivos muy grandes)${RESET}"
    echo ""
    local fs_choice
    read -rp "$(echo -e "  ${BOLD}Opción [1]: ${RESET}")" fs_choice </dev/tty
    local fs="ext4"
    [[ "$fs_choice" == "2" ]] && fs="xfs"

    # Confirmación final
    local disk_size
    disk_size=$(lsblk -dnpo SIZE "$disk" 2>/dev/null || echo "?")
    echo ""
    echo -e "  ${BOLD}${RED}Esta operación es IRREVERSIBLE:${RESET}"
    echo -e "  Disco      : ${BOLD}${disk}${RESET} (${disk_size})"
    echo -e "  Filesystem : ${BOLD}${fs}${RESET}"
    echo -e "  Etiqueta   : ${BOLD}${label}${RESET}"
    echo -e "  Montaje    : ${BOLD}${mp}${RESET}"
    echo ""
    local confirm_word
    read -rp "$(echo -e "  ${BOLD}Escribe 'FORMATEAR' para confirmar (Enter=cancelar): ${RESET}")" confirm_word </dev/tty
    [[ "$confirm_word" != "FORMATEAR" ]] && { log_info "Cancelado"; return 0; }

    _dm_format_and_register "$disk" "$label" "$mp" "$fs" || return 1

    echo ""
    if confirm "¿Crear symlink de acceso para compartir este disco vía NFS o Samba?" "Y"; then
        _dm_create_share_symlink "$mp" "$label"
    fi
}

dm_manage_mounts() {
    print_header "GESTIONAR MONTAJE Y ACCESO"

    while true; do
        _dm_show_disks

        echo -e "  ${BOLD}¿Qué deseas hacer?${RESET}"
        echo ""
        echo -e "  ${CYAN}[1]${RESET} Desmontar partición"
        echo -e "  ${CYAN}[2]${RESET} Montar / remontar partición"
        echo -e "  ${CYAN}[3]${RESET} Crear symlink de acceso  ${DIM}(para compartir vía NFS / Samba)${RESET}"
        echo -e "  ${DIM}[0]${RESET} Volver"
        echo ""

        local choice
        read -rp "$(echo -e "  ${BOLD}Opción: ${RESET}")" choice

        case "$choice" in
            1) _dm_op_unmount ;;
            2) _dm_op_mount ;;
            3) _dm_op_symlink ;;
            0) return 0 ;;
            *) log_warn "Opción inválida" ;;
        esac
        echo ""
    done
}

_dm_op_unmount() {
    echo ""
    echo -e "  ${BOLD}Selecciona la partición a desmontar:${RESET}"
    echo ""
    _dm_pick_mounted_part || { log_info "Cancelado"; return 0; }

    local part="$DM_SELECTED_DEV"
    local mp="$DM_SELECTED_MP"

    confirm "¿Desmontar ${part} (${mp})?" "Y" || return 0

    umount "$mp" && log_success "Desmontado: ${mp}" || {
        log_error "No se pudo desmontar ${mp}"
        log_info "Comprueba si hay procesos usando el disco: lsof +D ${mp}"
    }
}

_dm_op_mount() {
    echo ""
    echo -e "  ${BOLD}Selecciona la partición a montar:${RESET}"
    echo ""
    _dm_pick_unmounted_part || { log_info "Cancelado"; return 0; }

    local part="$DM_SELECTED_DEV"

    # Buscar en fstab por UUID de la partición
    local uuid
    uuid=$(blkid -s UUID -o value "$part" 2>/dev/null || true)
    local fstab_mp=""
    [[ -n "$uuid" ]] && fstab_mp=$(grep "UUID=${uuid}" /etc/fstab 2>/dev/null | awk '{print $2}' | head -1)

    local mp
    if [[ -n "$fstab_mp" ]]; then
        log_info "Entrada en fstab: UUID=${uuid} → ${fstab_mp}"
        mp=$(prompt_env_value "Punto de montaje" "$fstab_mp")
    else
        local label
        label=$(blkid -s LABEL -o value "$part" 2>/dev/null || basename "$part")
        mp=$(prompt_env_value "Punto de montaje" "/mnt/${label}")
    fi

    mkdir -p "$mp"

    if mount "$part" "$mp" 2>/dev/null || mount "$mp" 2>/dev/null; then
        log_success "Montado: ${part} → ${mp}"
    else
        log_error "Error al montar ${part}"
        return 1
    fi

    # Si no estaba en fstab, ofrecer añadirlo
    if [[ -z "$fstab_mp" ]] && confirm "¿Añadir a /etc/fstab para montaje automático al arrancar?" "Y"; then
        local fs_type
        fs_type=$(blkid -s TYPE -o value "$part" 2>/dev/null || echo "ext4")
        if [[ -n "$uuid" ]]; then
            {
                echo ""
                echo "# nas-setup: ${part} (${mp})"
                echo "UUID=${uuid}  ${mp}  ${fs_type}  defaults,nofail,x-systemd.device-timeout=5  0  2"
            } >> /etc/fstab
            log_success "Añadido a /etc/fstab: UUID=${uuid} → ${mp}"
        else
            log_warn "Sin UUID disponible — no se pudo añadir a fstab"
        fi
    fi

    echo ""
    if confirm "¿Crear symlink de acceso para compartir este directorio?" "Y"; then
        local label
        label=$(blkid -s LABEL -o value "$part" 2>/dev/null || basename "$part")
        _dm_create_share_symlink "$mp" "$label"
    fi
}

_dm_op_symlink() {
    echo ""
    echo -e "  ${BOLD}Selecciona el directorio montado para crear el symlink:${RESET}"
    echo ""
    _dm_pick_mounted_part || { log_info "Cancelado"; return 0; }

    local mp="$DM_SELECTED_MP"
    local label
    label=$(blkid -s LABEL -o value "$DM_SELECTED_DEV" 2>/dev/null || basename "$DM_SELECTED_DEV")
    _dm_create_share_symlink "$mp" "$label"
}
