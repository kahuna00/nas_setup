#!/usr/bin/env bash
# modules/04-nfs-sync/schedule.sh — Programa el sync NFS vía systemd timer o cron
# Depends on: lib/{logging,idempotency}.sh

NAS_SETUP_DIR="$(dirname "$(dirname "$(dirname "${BASH_SOURCE[0]}")")")"
TEMPLATE_DIR="${NAS_SETUP_DIR}/templates"
SYSTEMD_DIR="/etc/systemd/system"
SCRIPTS_DIR="/var/lib/nas-setup/scripts"

_install_systemd_units() {
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
        log_info "Configurando cron para NFS sync..."
        _install_cron || return 1
    else
        log_info "Instalando unidades systemd para NFS sync..."
        _install_systemd_units || return 1
        log_info "Habilitando timer..."
        _enable_systemd_timer || return 1
    fi

    state_mark "nfs_sync_schedule"
    log_success "Schedule configurado (${schedule_type})"
    echo ""
    echo -e "  ${CYAN}Sync diario : ${BOLD}${NFS_SYNC_HOUR}:00${RESET}"
    echo -e "  ${CYAN}Fuente      : ${BOLD}${NFS_SYNC_REMOTE_HOST}:${NFS_SYNC_REMOTE_PATH}${RESET}"
    echo -e "  ${CYAN}Destino     : ${BOLD}${NFS_SYNC_DEST_DIR}${RESET}"
    echo ""
}
