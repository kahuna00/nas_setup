#!/usr/bin/env bash
# modules/02-mergerfs-snapraid/snapraid.sh — SnapRAID installation and configuration
# Depends on: format.sh (DISK_MOUNTPOINT), lib/{logging,os,idempotency}.sh

NAS_SETUP_DIR="$(dirname "$(dirname "$(dirname "${BASH_SOURCE[0]}")")")"
TEMPLATE_DIR="${NAS_SETUP_DIR}/templates"
SNAPRAID_CONF="/etc/snapraid.conf"
SNAPRAID_CACHE_DIR="/var/cache/nas-setup"

install_snapraid() {
    skip_if_done "snapraid_installed" "instalación de SnapRAID" && return 0

    log_info "Instalando SnapRAID..."

    # Try apt first (available on newer Ubuntu/Debian)
    if apt-cache show snapraid &>/dev/null 2>&1; then
        pkg_install snapraid && {
            state_mark "snapraid_installed"
            log_success "SnapRAID instalado desde apt: $(snapraid --version 2>&1 | head -1)"
            return 0
        }
    fi

    # Fallback: download binary from GitHub
    local arch
    arch=$(get_arch)
    mkdir -p "$SNAPRAID_CACHE_DIR"

    log_info "Descargando SnapRAID desde GitHub releases..."
    local latest_tag
    latest_tag=$(curl -sf "https://api.github.com/repos/amadvance/snapraid/releases/latest" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'])" 2>/dev/null)

    if [[ -z "$latest_tag" ]]; then
        log_error "No se pudo obtener la versión más reciente de SnapRAID"
        log_info "Instala manualmente: https://www.snapraid.it/download"
        return 1
    fi

    # SnapRAID provides tar.gz with binary inside
    local version="${latest_tag#v}"
    local tarball="${SNAPRAID_CACHE_DIR}/snapraid-${version}.tar.gz"
    local download_url="https://github.com/amadvance/snapraid/releases/download/${latest_tag}/snapraid-${version}.tar.gz"

    if [[ ! -f "$tarball" ]]; then
        curl -Lf "$download_url" -o "$tarball" || {
            log_error "Descarga de SnapRAID fallida"
            return 1
        }
    fi

    # Build from source
    pkg_install build-essential libblkid-dev || return 1
    local build_dir
    build_dir=$(mktemp -d)
    tar -xzf "$tarball" -C "$build_dir" || return 1
    pushd "${build_dir}/snapraid-${version}" > /dev/null
    ./configure >> "$LOG_FILE" 2>&1 || return 1
    make -j"$(nproc)" >> "$LOG_FILE" 2>&1 || return 1
    make install >> "$LOG_FILE" 2>&1 || return 1
    popd > /dev/null
    rm -rf "$build_dir"

    state_mark "snapraid_installed"
    log_success "SnapRAID compilado e instalado: $(snapraid --version 2>&1 | head -1)"
}

render_snapraid_conf() {
    skip_if_done "snapraid_conf" "generación de snapraid.conf" && return 0

    if [[ -f "$SNAPRAID_CONF" ]]; then
        cp "$SNAPRAID_CONF" "${SNAPRAID_CONF}.bak.$(date +%s)"
        log_debug "Backup de snapraid.conf creado"
    fi

    # Start from template
    cp "${TEMPLATE_DIR}/snapraid.conf.j2" "$SNAPRAID_CONF"

    # ── Build parity lines ────────────────────────────────────────────────────
    local parity_lines=""
    local pidx=1
    for dev in "${PARITY_DISKS[@]}"; do
        local mp="${DISK_MOUNTPOINT[$dev]}"
        if [[ -z "$mp" ]]; then
            log_warn "Sin mountpoint para disco de paridad ${dev} — saltando"
            continue
        fi
        if [[ $pidx -eq 1 ]]; then
            parity_lines+="parity ${mp}/.snapraid.parity"$'\n'
        else
            parity_lines+="${pidx}-parity ${mp}/.snapraid.parity"$'\n'
        fi
        ((pidx++))
    done

    # ── Build content lines ───────────────────────────────────────────────────
    local content_lines="content /var/snapraid.content"$'\n'
    local didx=1
    for dev in "${DATA_DISKS[@]}"; do
        local mp="${DISK_MOUNTPOINT[$dev]}"
        [[ -n "$mp" ]] && content_lines+="content ${mp}/.snapraid.content"$'\n'
        ((didx++))
    done

    # ── Build data lines ──────────────────────────────────────────────────────
    local data_lines=""
    local didx=1
    for dev in "${DATA_DISKS[@]}"; do
        local mp="${DISK_MOUNTPOINT[$dev]}"
        [[ -z "$mp" ]] && { log_warn "Sin mountpoint para ${dev}"; continue; }
        data_lines+="data d${didx} ${mp}"$'\n'
        ((didx++))
    done

    # ── Inject lines into config using sed ────────────────────────────────────
    # Replace placeholder markers with generated content
    local tmp_conf
    tmp_conf=$(mktemp)

    export SNAPRAID_PARITY_LINES="$parity_lines"
    export SNAPRAID_CONTENT_LINES="$content_lines"
    export SNAPRAID_DATA_LINES="$data_lines"

    python3 - "$SNAPRAID_CONF" "$tmp_conf" << 'PYEOF'
import sys, os
with open(sys.argv[1], 'r') as f:
    content = f.read()
parity = os.environ.get('SNAPRAID_PARITY_LINES', '')
content_files = os.environ.get('SNAPRAID_CONTENT_LINES', '')
data = os.environ.get('SNAPRAID_DATA_LINES', '')
content = content.replace('##PARITY_LINES##', parity.rstrip())
content = content.replace('##CONTENT_LINES##', content_files.rstrip())
content = content.replace('##DATA_LINES##', data.rstrip())
with open(sys.argv[2], 'w') as f:
    f.write(content)
PYEOF

    mv "$tmp_conf" "$SNAPRAID_CONF"

    state_mark "snapraid_conf"
    log_success "snapraid.conf generado en: $SNAPRAID_CONF"

    # Show generated config summary
    echo ""
    echo -e "  ${DIM}$(grep -E '^(parity|[0-9]+-parity|content|data )' "$SNAPRAID_CONF" | head -20)${RESET}"
    echo ""
}

validate_snapraid_conf() {
    log_info "Validando configuración SnapRAID..."

    if ! snapraid status &>/dev/null 2>&1; then
        # New array: run initial sync check
        if snapraid diff 2>&1 | grep -q "No differences"; then
            log_success "Configuración SnapRAID válida (array nuevo)"
        else
            log_warn "snapraid status retornó error — puede ser un array nuevo. Ejecuta 'snapraid sync' para inicializar."
        fi
    else
        log_success "snapraid status OK"
    fi
}

configure_snapraid() {
    log_info "Instalando SnapRAID..."
    install_snapraid || return 1

    log_info "Generando snapraid.conf..."
    render_snapraid_conf || return 1

    validate_snapraid_conf

    log_success "SnapRAID configurado"
}
