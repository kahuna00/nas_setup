#!/usr/bin/env bash
# modules/04-nfs-sync/schedule.sh — Programa el sync NFS vía systemd timer o cron
# Depends on: lib/{logging,idempotency}.sh

NAS_SETUP_DIR="$(dirname "$(dirname "$(dirname "${BASH_SOURCE[0]}")")")"
TEMPLATE_DIR="${NAS_SETUP_DIR}/templates"
SYSTEMD_DIR="/etc/systemd/system"
SCRIPTS_DIR="/var/lib/nas-setup/scripts"

_export_nfs_sync_oncalendar() {
    local period="${NFS_SYNC_PERIOD:-daily}"
    local hour="${NFS_SYNC_HOUR:-2}"
    local day="${NFS_SYNC_DAY:-Sun}"

    case "$period" in
        weekly)  export NFS_SYNC_ONCALENDAR="${day} *-*-* ${hour}:00:00"
                 export NFS_SYNC_SCHEDULE_LABEL="Semanal · ${day} ${hour}:00" ;;
        monthly) export NFS_SYNC_ONCALENDAR="*-*-01 ${hour}:00:00"
                 export NFS_SYNC_SCHEDULE_LABEL="Mensual · día 1 ${hour}:00" ;;
        *)       export NFS_SYNC_ONCALENDAR="*-*-* ${hour}:00:00"
                 export NFS_SYNC_SCHEDULE_LABEL="Diario · ${hour}:00" ;;
    esac
}

_install_systemd_units() {
    _export_nfs_sync_oncalendar

    for unit in "nfs-sync.service" "nfs-sync.timer"; do
        local template="${TEMPLATE_DIR}/${unit}.j2"
        local dest="${SYSTEMD_DIR}/${unit}"

        if [[ ! -f "$template" ]]; then
            log_warn "Template no encontrado: $template"
            return 1
        fi

        envsubst < "$template" > "$dest"
        log_debug "Unit instalada: $dest"
    done

    systemctl daemon-reload
    log_success "Unidades systemd instaladas"
}

_install_cron() {
    local cron_file="/etc/cron.d/nfs-sync"
    cat > "$cron_file" << EOF
# nfs-sync schedule — generado por nas-setup
# Sync diario a las ${NFS_SYNC_HOUR}:00
0 ${NFS_SYNC_HOUR} * * * root ${SCRIPTS_DIR}/nfs-sync.sh >> /var/log/nfs-sync.log 2>&1
EOF
    log_success "Cron configurado en: $cron_file"
}

_enable_systemd_timer() {
    systemctl enable nfs-sync.timer >> "$LOG_FILE" 2>&1
    systemctl start nfs-sync.timer >> "$LOG_FILE" 2>&1
    log_success "Timer habilitado: nfs-sync.timer"

    echo ""
    log_info "Próxima ejecución programada:"
    systemctl list-timers nfs-sync.timer --no-pager 2>/dev/null | while read -r line; do
        echo -e "  ${DIM}${line}${RESET}"
    done
}

configure_sync_schedule() {
    skip_if_done "nfs_sync_schedule" "configuración de schedule NFS sync" && return 0

    local schedule_type="${SCHEDULE_TYPE:-systemd}"

    if [[ "$schedule_type" == "cron" ]]; then
        [[ "${NFS_SYNC_PERIOD:-daily}" != "daily" ]] && \
            log_warn "Backend cron solo soporta periodicidad diaria — usa SCHEDULE_TYPE=systemd para weekly/monthly"
        log_info "Configurando cron para NFS sync..."
        _install_cron || return 1
    else
        log_info "Instalando unidades systemd para NFS sync..."
        _install_systemd_units || return 1
        log_info "Habilitando timer..."
        _enable_systemd_timer || return 1
    fi

    _export_nfs_sync_oncalendar
    state_mark "nfs_sync_schedule"
    log_success "Schedule configurado (${schedule_type})"
    echo ""
    echo -e "  ${CYAN}Sync        : ${BOLD}${NFS_SYNC_SCHEDULE_LABEL}${RESET}"
    echo -e "  ${CYAN}Fuente      : ${BOLD}${NFS_SYNC_REMOTE_HOST}:${NFS_SYNC_REMOTE_PATH}${RESET}"
    echo -e "  ${CYAN}Destino     : ${BOLD}${NFS_SYNC_DEST_DIR}${RESET}"
    echo ""
}
