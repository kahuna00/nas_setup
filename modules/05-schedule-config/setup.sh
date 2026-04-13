#!/usr/bin/env bash
# modules/05-schedule-config/setup.sh — Módulo 5: Reconfigurar schedules
# Permite cambiar periodicidad y horarios de SnapRAID y NFS Sync.
# Uso: sourced desde install.sh, llamar setup_schedule_config()

NAS_SETUP_DIR="$(dirname "$(dirname "$(dirname "${BASH_SOURCE[0]}")")")"
TEMPLATE_DIR="${NAS_SETUP_DIR}/templates"
SYSTEMD_DIR="/etc/systemd/system"
SCRIPTS_DIR="/var/lib/nas-setup/scripts"

# ── Validación ─────────────────────────────────────────────────────────────────

_validate_int() {
    local val="$1" min="$2" max="$3"
    [[ "$val" =~ ^[0-9]+$ ]] && (( val >= min && val <= max ))
}

_validate_day() {
    [[ "$1" =~ ^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)$ ]]
}

# ── OnCalendar y etiquetas ──────────────────────────────────────────────────────
# Calcula la expresión OnCalendar de systemd y una etiqueta legible.
# Salida: "ONCALENDAR_EXPR|LABEL_STRING"

_build_oncalendar() {
    local period="$1"     # daily | weekly | monthly | disabled
    local hour="$2"       # 0-23
    local day="${3:-Sun}" # Mon-Sun (solo para weekly)

    case "$period" in
        weekly)   echo "${day} *-*-* ${hour}:00:00|Semanal · ${day} ${hour}:00" ;;
        monthly)  echo "*-*-01 ${hour}:00:00|Mensual · día 1 ${hour}:00" ;;
        disabled) echo "disabled|Desactivado" ;;
        *)        echo "*-*-* ${hour}:00:00|Diario · ${hour}:00" ;;
    esac
}

# Exporta las variables *_ONCALENDAR y *_SCHEDULE_LABEL al entorno actual.
# Llamar antes de renderizar cualquier template de timer.
export_oncalendar_vars() {
    local result

    result=$(_build_oncalendar \
        "${SNAPRAID_SYNC_PERIOD:-daily}" \
        "${SNAPRAID_SYNC_HOUR:-3}" \
        "${SNAPRAID_SYNC_DAY:-Sun}")
    export SNAPRAID_SYNC_ONCALENDAR="${result%%|*}"
    export SNAPRAID_SYNC_SCHEDULE_LABEL="${result##*|}"

    result=$(_build_oncalendar \
        "${NFS_SYNC_PERIOD:-daily}" \
        "${NFS_SYNC_HOUR:-2}" \
        "${NFS_SYNC_DAY:-Sun}")
    export NFS_SYNC_ONCALENDAR="${result%%|*}"
    export NFS_SYNC_SCHEDULE_LABEL="${result##*|}"
}

# ── Estimador de desgaste anual ────────────────────────────────────────────────

_show_wear_estimate() {
    local period="${1:-daily}"
    local daily_gb

    echo ""
    echo -e "  ${BOLD}Estimación de desgaste anual (parity SSD)${RESET}"
    echo -e "  ${DIM}SnapRAID escribe en paridad proporcional a los datos que cambiaron.${RESET}"
    echo ""

    read -rp "$(echo -e "  ${BOLD}¿Cuántos GB estimas que cambian por sync en el pool?${RESET} ${DIM}[default: 20]${RESET}: ")" daily_gb
    daily_gb="${daily_gb:-20}"
    if ! _validate_int "$daily_gb" 1 100000; then
        log_warn "Valor no válido, usando 20 GB"
        daily_gb=20
    fi

    # Syncs por año según periodicidad
    local syncs_year
    case "$period" in
        weekly)  syncs_year=52  ;;
        monthly) syncs_year=12  ;;
        *)       syncs_year=365 ;;
    esac

    local writes_year_gb=$(( daily_gb * syncs_year ))
    local writes_year_tb
    writes_year_tb=$(echo "scale=1; $writes_year_gb / 1000" | bc 2>/dev/null || echo "$(( writes_year_gb / 1000 ))")

    # Años de vida para SSDs de referencia
    local tbw_600 tbw_300
    tbw_600=$(echo "scale=0; 600000 / $writes_year_gb" | bc 2>/dev/null || echo "$(( 600000 / writes_year_gb ))")
    tbw_300=$(echo "scale=0; 300000 / $writes_year_gb" | bc 2>/dev/null || echo "$(( 300000 / writes_year_gb ))")

    # Tabla comparativa de las tres periodicidades
    local d_gb=$(( daily_gb * 365 )) w_gb=$(( daily_gb * 52 )) m_gb=$(( daily_gb * 12 ))
    local d_tb w_tb m_tb d_600 w_600 m_600
    d_tb=$(echo "scale=1; $d_gb / 1000" | bc 2>/dev/null || echo "$(( d_gb / 1000 ))")
    w_tb=$(echo "scale=1; $w_gb / 1000" | bc 2>/dev/null || echo "$(( w_gb / 1000 ))")
    m_tb=$(echo "scale=1; $m_gb / 1000" | bc 2>/dev/null || echo "$(( m_gb / 1000 ))")
    d_600=$(echo "scale=0; 600000 / $d_gb" | bc 2>/dev/null || echo "$(( 600000 / d_gb ))")
    w_600=$(echo "scale=0; 600000 / $w_gb" | bc 2>/dev/null || echo "$(( 600000 / w_gb ))")
    m_600=$(echo "scale=0; 600000 / $m_gb" | bc 2>/dev/null || echo "$(( 600000 / m_gb ))")

    local mark_d="" mark_w="" mark_m=""
    case "$period" in
        daily)   mark_d=" ◀" ;;
        weekly)  mark_w=" ◀" ;;
        monthly) mark_m=" ◀" ;;
    esac

    echo ""
    echo -e "  Con ${BOLD}${daily_gb} GB/sync${RESET}:"
    echo ""
    printf  "  %-22s  %12s  %16s\n" "Periodicidad" "TB/año parity" "SSD 1TB / 600TBW"
    printf  "  %-22s  %12s  %16s\n" "──────────────────────" "────────────" "────────────────"
    printf  "  %-22s  %12s  %16s\n" "Diario (365×)${mark_d}"   "${d_tb} TB"  "~${d_600} años"
    printf  "  %-22s  %12s  %16s\n" "Semanal (52×)${mark_w}"   "${w_tb} TB"  "~${w_600} años"
    printf  "  %-22s  %12s  %16s\n" "Mensual (12×)${mark_m}"   "${m_tb} TB"  "~${m_600} años"
    echo ""

    if (( tbw_600 < 5 )); then
        log_warn "Con esta periodicidad el SSD de paridad se agotaría en ~${tbw_600} años"
        log_warn "Considera sync semanal o mensual, HDD como parity, o ZFS RAIDZ1"
    elif (( tbw_600 < 15 )); then
        log_info "Desgaste moderado. Monitorea TBW con: smartctl -A /dev/sdX | grep Written"
    else
        log_success "Desgaste bajo. Viable con SSDs a esta periodicidad."
    fi
    echo ""
}

# ── Renderizar y recargar unidades ─────────────────────────────────────────────

_reload_snapraid_units() {
    export_oncalendar_vars

    if [[ "${SNAPRAID_SYNC_PERIOD:-daily}" == "disabled" ]]; then
        systemctl stop    snapraid-sync.timer 2>/dev/null || true
        systemctl disable snapraid-sync.timer 2>/dev/null || true
        log_success "Timer snapraid-sync.timer desactivado"
        # Scrub y smart siguen activos
        for timer in snapraid-scrub.timer snapraid-smart.timer; do
            local template="${TEMPLATE_DIR}/${timer%.timer}.timer.j2"
            [[ -f "${TEMPLATE_DIR}/${timer}.j2" ]] && \
                envsubst < "${TEMPLATE_DIR}/${timer}.j2" > "${SYSTEMD_DIR}/${timer}"
        done
        systemctl daemon-reload
        return 0
    fi

    local units=("snapraid-sync.timer" "snapraid-sync.service"
                 "snapraid-scrub.timer" "snapraid-scrub.service"
                 "snapraid-smart.timer" "snapraid-smart.service")
    for unit in "${units[@]}"; do
        local template="${TEMPLATE_DIR}/${unit}.j2"
        [[ -f "$template" ]] || continue
        envsubst < "$template" > "${SYSTEMD_DIR}/${unit}"
        log_debug "Re-renderizado: ${unit}"
    done

    if [[ -f "${SCRIPTS_DIR}/snapraid-sync-safe.sh" ]]; then
        sed -i "s|^THRESHOLD=.*|THRESHOLD=${SNAPRAID_DIFF_THRESHOLD}|" \
            "${SCRIPTS_DIR}/snapraid-sync-safe.sh"
    fi

    systemctl daemon-reload
    for timer in snapraid-sync.timer snapraid-scrub.timer snapraid-smart.timer; do
        if systemctl is-enabled --quiet "$timer" 2>/dev/null; then
            systemctl restart "$timer" && log_success "Timer recargado: $timer"
        fi
    done
}

_reload_nfs_sync_units() {
    export_oncalendar_vars

    if [[ "${NFS_SYNC_PERIOD:-daily}" == "disabled" ]]; then
        systemctl stop    nfs-sync.timer 2>/dev/null || true
        systemctl disable nfs-sync.timer 2>/dev/null || true
        log_success "Timer nfs-sync.timer desactivado"
        return 0
    fi

    for unit in "nfs-sync.timer" "nfs-sync.service"; do
        local template="${TEMPLATE_DIR}/${unit}.j2"
        [[ -f "$template" ]] || continue
        envsubst < "$template" > "${SYSTEMD_DIR}/${unit}"
        log_debug "Re-renderizado: ${unit}"
    done

    systemctl daemon-reload
    if systemctl is-enabled --quiet nfs-sync.timer 2>/dev/null; then
        systemctl restart nfs-sync.timer && log_success "Timer recargado: nfs-sync.timer"
    else
        systemctl enable nfs-sync.timer 2>/dev/null
        systemctl start  nfs-sync.timer 2>/dev/null
        log_success "Timer nfs-sync.timer habilitado y arrancado"
    fi
}

# ── Selección de periodicidad (submenú) ────────────────────────────────────────
# IMPORTANTE: todo el display va a stderr; solo el valor de retorno va a stdout.
# Así la captura new_period=$(_pick_period ...) solo recibe "daily/weekly/..."

_pick_period() {
    local current="$1"   # daily | weekly | monthly | disabled
    local label_var="$2" # nombre descriptivo para el prompt

    local current_label
    case "$current" in
        weekly)   current_label="Semanal" ;;
        monthly)  current_label="Mensual" ;;
        disabled) current_label="Desactivado" ;;
        *)        current_label="Diario" ;;
    esac

    {
        echo ""
        echo -e "  ${BOLD}Periodicidad ${label_var}:${RESET}"
        echo ""
        echo -e "  ${CYAN}[1]${RESET} Diario      — cada día a la hora configurada"
        echo -e "  ${CYAN}[2]${RESET} Semanal     — un día de la semana a elegir"
        echo -e "  ${CYAN}[3]${RESET} Mensual     — el día 1 de cada mes"
        echo -e "  ${CYAN}[4]${RESET} Desactivado — deshabilitar el timer automático"
        echo ""
        echo -e "  Actual: ${CYAN}${current_label}${RESET}"
        echo ""
    } >&2

    local choice
    # Leer desde /dev/tty porque stdin está capturado por $() en el caller
    read -rp "$(echo -e "  ${BOLD}Opción [Enter=mantener]: ${RESET}")" choice </dev/tty

    case "$choice" in
        1) echo "daily"    ;;
        2) echo "weekly"   ;;
        3) echo "monthly"  ;;
        4) echo "disabled" ;;
        *) echo "$current" ;;
    esac
}

# ── Mostrar configuración actual ───────────────────────────────────────────────

_show_current_config() {
    export_oncalendar_vars
    echo ""
    echo -e "  ${BOLD}Schedule actual:${RESET}"
    echo ""
    echo -e "  ${CYAN}SnapRAID${RESET}"
    echo -e "    Sync           : ${BOLD}${SNAPRAID_SYNC_SCHEDULE_LABEL}${RESET}"
    echo -e "    Scrub semanal  : ${BOLD}${SNAPRAID_SCRUB_DAY:-Sun} 04:00 (${SNAPRAID_SCRUB_PERCENT:-5}% datos)${RESET}"
    echo -e "    Umbral diff    : ${BOLD}${SNAPRAID_DIFF_THRESHOLD:-20}%${RESET}  ${DIM}(aborta sync si más archivos eliminados)${RESET}"
    echo ""
    echo -e "  ${CYAN}NFS Sync${RESET}"
    echo -e "    Sync           : ${BOLD}${NFS_SYNC_SCHEDULE_LABEL}${RESET}"
    echo ""
    echo -e "  ${CYAN}Backend${RESET}"
    echo -e "    Tipo schedule  : ${BOLD}${SCHEDULE_TYPE:-systemd}${RESET}"
    echo ""
}

# ── Submenús de edición ────────────────────────────────────────────────────────

_edit_snapraid_schedule() {
    echo ""
    echo -e "  ${BOLD}Configurar schedule SnapRAID${RESET}"
    echo -e "  ${DIM}Presiona Enter para mantener el valor actual.${RESET}"
    echo ""

    local changed=0

    # Periodicidad
    local new_period
    new_period=$(_pick_period "${SNAPRAID_SYNC_PERIOD:-daily}" "sync SnapRAID")
    [[ "$new_period" != "${SNAPRAID_SYNC_PERIOD:-daily}" ]] && { set_env_var SNAPRAID_SYNC_PERIOD "$new_period"; changed=1; }

    # Día (solo si semanal)
    if [[ "$new_period" == "weekly" ]]; then
        local new_day
        new_day=$(prompt_env_value "Día del sync semanal (Mon/Tue/Wed/Thu/Fri/Sat/Sun)" "${SNAPRAID_SYNC_DAY:-Sun}")
        if ! _validate_day "$new_day"; then
            log_error "Día inválido: $new_day"; return 1
        fi
        [[ "$new_day" != "${SNAPRAID_SYNC_DAY:-Sun}" ]] && { set_env_var SNAPRAID_SYNC_DAY "$new_day"; changed=1; }
    fi

    # Hora
    local new_hour
    new_hour=$(prompt_env_value "Hora del sync (0-23)" "${SNAPRAID_SYNC_HOUR:-3}")
    if ! _validate_int "$new_hour" 0 23; then
        log_error "Hora inválida: $new_hour"; return 1
    fi
    [[ "$new_hour" != "${SNAPRAID_SYNC_HOUR:-3}" ]] && { set_env_var SNAPRAID_SYNC_HOUR "$new_hour"; changed=1; }

    # Scrub
    local new_scrub_day new_percent new_threshold

    new_scrub_day=$(prompt_env_value "Día del scrub semanal (Mon/Tue/Wed/Thu/Fri/Sat/Sun)" "${SNAPRAID_SCRUB_DAY:-Sun}")
    if ! _validate_day "$new_scrub_day"; then
        log_error "Día inválido: $new_scrub_day"; return 1
    fi
    [[ "$new_scrub_day" != "${SNAPRAID_SCRUB_DAY:-Sun}" ]] && { set_env_var SNAPRAID_SCRUB_DAY "$new_scrub_day"; changed=1; }

    new_percent=$(prompt_env_value "% de datos a verificar por scrub (1-100)" "${SNAPRAID_SCRUB_PERCENT:-5}")
    if ! _validate_int "$new_percent" 1 100; then
        log_error "Porcentaje inválido: $new_percent"; return 1
    fi
    [[ "$new_percent" != "${SNAPRAID_SCRUB_PERCENT:-5}" ]] && { set_env_var SNAPRAID_SCRUB_PERCENT "$new_percent"; changed=1; }

    new_threshold=$(prompt_env_value "Umbral diff % (aborta sync si más archivos eliminados)" "${SNAPRAID_DIFF_THRESHOLD:-20}")
    if ! _validate_int "$new_threshold" 1 100; then
        log_error "Umbral inválido: $new_threshold"; return 1
    fi
    [[ "$new_threshold" != "${SNAPRAID_DIFF_THRESHOLD:-20}" ]] && { set_env_var SNAPRAID_DIFF_THRESHOLD "$new_threshold"; changed=1; }

    if [[ "$changed" -eq 0 ]]; then
        log_info "Sin cambios."
    else
        echo ""
        log_info "Aplicando cambios en unidades systemd SnapRAID..."
        _reload_snapraid_units
        export_oncalendar_vars
        log_success "Schedule SnapRAID actualizado"
        echo -e "    Sync           : ${CYAN}${SNAPRAID_SYNC_SCHEDULE_LABEL}${RESET}"
        echo -e "    Scrub semanal  : ${CYAN}${SNAPRAID_SCRUB_DAY} 04:00 (${SNAPRAID_SCRUB_PERCENT}%)${RESET}"
        echo -e "    Umbral diff    : ${CYAN}${SNAPRAID_DIFF_THRESHOLD}%${RESET}"
    fi

    _show_wear_estimate "${SNAPRAID_SYNC_PERIOD:-daily}"
}

_edit_nfs_sync_schedule() {
    echo ""
    echo -e "  ${BOLD}Configurar schedule NFS Sync${RESET}"
    echo -e "  ${DIM}Presiona Enter para mantener el valor actual.${RESET}"
    echo ""

    local changed=0

    local new_period
    new_period=$(_pick_period "${NFS_SYNC_PERIOD:-daily}" "NFS Sync")
    [[ "$new_period" != "${NFS_SYNC_PERIOD:-daily}" ]] && { set_env_var NFS_SYNC_PERIOD "$new_period"; changed=1; }

    if [[ "$new_period" == "weekly" ]]; then
        local new_day
        new_day=$(prompt_env_value "Día del sync semanal (Mon/Tue/Wed/Thu/Fri/Sat/Sun)" "${NFS_SYNC_DAY:-Sun}")
        if ! _validate_day "$new_day"; then
            log_error "Día inválido: $new_day"; return 1
        fi
        [[ "$new_day" != "${NFS_SYNC_DAY:-Sun}" ]] && { set_env_var NFS_SYNC_DAY "$new_day"; changed=1; }
    fi

    local new_hour
    new_hour=$(prompt_env_value "Hora del sync (0-23)" "${NFS_SYNC_HOUR:-2}")
    if ! _validate_int "$new_hour" 0 23; then
        log_error "Hora inválida: $new_hour"; return 1
    fi
    [[ "$new_hour" != "${NFS_SYNC_HOUR:-2}" ]] && { set_env_var NFS_SYNC_HOUR "$new_hour"; changed=1; }

    if [[ "$changed" -eq 0 ]]; then
        log_info "Sin cambios."
        return 0
    fi

    echo ""
    log_info "Aplicando cambios en unidades systemd NFS Sync..."
    _reload_nfs_sync_units
    export_oncalendar_vars
    log_success "Schedule NFS Sync actualizado: ${CYAN}${NFS_SYNC_SCHEDULE_LABEL}${RESET}"
}

# ── Punto de entrada ───────────────────────────────────────────────────────────

setup_schedule_config() {
    print_header "MÓDULO 5: CONFIGURACIÓN DE SCHEDULES"

    _show_current_config

    echo -e "  ${BOLD}¿Qué deseas cambiar?${RESET}"
    echo ""
    echo -e "  ${CYAN}[1]${RESET} Schedule SnapRAID  ${DIM}(periodicidad · hora · scrub · umbral diff)${RESET}"
    echo -e "  ${CYAN}[2]${RESET} Schedule NFS Sync  ${DIM}(periodicidad · hora)${RESET}"
    echo -e "  ${CYAN}[3]${RESET} Ambos"
    echo -e "  ${CYAN}[0]${RESET} Volver"
    echo ""

    local choice
    read -rp "$(echo -e "  ${BOLD}Opción: ${RESET}")" choice

    case "$choice" in
        1) _edit_snapraid_schedule ;;
        2) _edit_nfs_sync_schedule ;;
        3) _edit_snapraid_schedule && _edit_nfs_sync_schedule ;;
        0) return 0 ;;
        *) log_warn "Opción inválida" ;;
    esac

    if [[ "$choice" =~ ^[123]$ ]]; then
        echo ""
        log_info "Próximas ejecuciones programadas:"
        systemctl list-timers 'snapraid-*.timer' 'nfs-sync.timer' --no-pager 2>/dev/null \
            | while read -r line; do echo -e "  ${DIM}${line}${RESET}"; done
        echo ""
    fi
}
