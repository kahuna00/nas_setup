#!/usr/bin/env bash
# modules/02-mergerfs-snapraid/mergerfs.sh — MergerFS installation and pool configuration
# Depends on: format.sh (DISK_MOUNTPOINT array), lib/{logging,os,idempotency}.sh

NAS_SETUP_DIR="$(dirname "$(dirname "$(dirname "${BASH_SOURCE[0]}")")")"
TEMPLATE_DIR="${NAS_SETUP_DIR}/templates"
MERGERFS_CACHE_DIR="/var/cache/nas-setup"

install_mergerfs() {
    skip_if_done "mergerfs_installed" "instalación de MergerFS" && return 0

    local arch
    arch=$(get_arch)
    log_info "Instalando MergerFS para arquitectura: ${arch}"

    mkdir -p "$MERGERFS_CACHE_DIR"

    # Check if already available via apt
    if apt-cache show mergerfs &>/dev/null 2>&1; then
        pkg_install mergerfs || return 1
        state_mark "mergerfs_installed"
        return 0
    fi

    # Download from GitHub releases
    log_info "Descargando MergerFS desde GitHub releases..."

    local latest_tag
    latest_tag=$(curl -sf "https://api.github.com/repos/trapexit/mergerfs/releases/latest" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'])" 2>/dev/null)

    if [[ -z "$latest_tag" ]]; then
        log_error "No se pudo obtener la versión más reciente de MergerFS"
        log_info "Descarga manual: https://github.com/trapexit/mergerfs/releases"
        return 1
    fi

    log_info "Versión detectada: $latest_tag"

    # Detect Debian/Ubuntu version for correct .deb
    local deb_variant="debian-bookworm"
    if [[ -f /etc/os-release ]]; then
        local version_id
        version_id=$(grep ^VERSION_ID /etc/os-release | cut -d'"' -f2)
        case "$version_id" in
            "22.04") deb_variant="ubuntu-jammy" ;;
            "24.04") deb_variant="ubuntu-noble" ;;
            "11")    deb_variant="debian-bullseye" ;;
            "12")    deb_variant="debian-bookworm" ;;
        esac
    fi

    local deb_file="${MERGERFS_CACHE_DIR}/mergerfs_${latest_tag}.${deb_variant}_${arch}.deb"

    if [[ ! -f "$deb_file" ]]; then
        local download_url="https://github.com/trapexit/mergerfs/releases/download/${latest_tag}/mergerfs_${latest_tag}.${deb_variant}_${arch}.deb"
        log_info "Descargando: $download_url"
        curl -Lf "$download_url" -o "$deb_file" || {
            log_error "Descarga fallida. Verifica la URL y la conexión a internet."
            return 1
        }
    else
        log_info "Usando .deb en caché: $deb_file"
    fi

    log_cmd "dpkg -i mergerfs" dpkg -i "$deb_file" || {
        log_error "Instalación de MergerFS fallida"
        return 1
    }

    state_mark "mergerfs_installed"
    log_success "MergerFS instalado: $(mergerfs --version 2>&1 | head -1)"
}

configure_mergerfs_fstab() {
    skip_if_done "mergerfs_fstab" "configuración de MergerFS en fstab" && return 0

    # Build sources string: /mnt/data1:/mnt/data2:...
    local sources=""
    for dev in "${DATA_DISKS[@]}"; do
        local mp="${DISK_MOUNTPOINT[$dev]}"
        [[ -z "$mp" ]] && continue
        [[ -n "$sources" ]] && sources="${sources}:"
        sources="${sources}${mp}"
    done

    if [[ -z "$sources" ]]; then
        log_error "No hay discos DATA montados para crear el pool MergerFS"
        return 1
    fi

    export MERGERFS_SOURCES="$sources"

    # Create pool mountpoint
    mkdir -p "$MERGERFS_POOL_PATH"

    # Check if already in fstab
    if grep -q "fuse.mergerfs" /etc/fstab && grep -q "$MERGERFS_POOL_PATH" /etc/fstab; then
        log_warn "Entrada MergerFS ya existe en fstab — actualizando..."
        # Remove old entry
        sed -i '/fuse\.mergerfs/d' /etc/fstab
        sed -i "/nas-setup: mergerfs/d" /etc/fstab
    fi

    # Add new entry
    echo "" >> /etc/fstab
    echo "# nas-setup: mergerfs pool → ${MERGERFS_POOL_PATH}" >> /etc/fstab
    envsubst < "${TEMPLATE_DIR}/mergerfs-fstab.j2" >> /etc/fstab

    state_mark "mergerfs_fstab"
    log_success "Entrada MergerFS añadida a /etc/fstab"
    log_info "  Fuentes : $sources"
    log_info "  Pool    : $MERGERFS_POOL_PATH"
    log_info "  Política: $MERGERFS_CREATE_POLICY"
}

mount_mergerfs_pool() {
    mkdir -p "$MERGERFS_POOL_PATH"

    if mountpoint -q "$MERGERFS_POOL_PATH"; then
        log_info "Pool MergerFS ya montado en: $MERGERFS_POOL_PATH"
        return 0
    fi

    log_info "Montando pool MergerFS en: $MERGERFS_POOL_PATH"
    mount "$MERGERFS_POOL_PATH" 2>&1 | tee -a "$LOG_FILE" || {
        log_error "No se pudo montar el pool MergerFS"
        log_info "Verifica con: mount -v ${MERGERFS_POOL_PATH}"
        return 1
    }

    log_success "Pool MergerFS montado correctamente"
    df -h "$MERGERFS_POOL_PATH" | tail -1 | while read -r line; do
        echo -e "  ${DIM}${line}${RESET}"
    done
}

configure_mergerfs() {
    log_info "Instalando MergerFS..."
    install_mergerfs || return 1

    log_info "Configurando fstab para pool MergerFS..."
    configure_mergerfs_fstab || return 1

    log_info "Montando pool..."
    mount_mergerfs_pool || return 1

    log_success "MergerFS configurado en: ${MERGERFS_POOL_PATH}"
}
