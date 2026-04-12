#!/usr/bin/env bash
# modules/04-nfs-sync/validate.sh — Verifica que el setup de NFS sync está correcto
# Depends on: lib/{colors,logging}.sh

SCRIPTS_DIR="/var/lib/nas-setup/scripts"

validate_nfs_sync() {
    local ok=1

    # rsync disponible
    if ! command -v rsync &>/dev/null; then
        log_error "rsync no encontrado"
        ok=0
    else
        log_success "rsync: $(rsync --version | head -1)"
    fi

    # Script de sync generado
    if [[ ! -x "${SCRIPTS_DIR}/nfs-sync.sh" ]]; then
        log_error "Script de sync no encontrado: ${SCRIPTS_DIR}/nfs-sync.sh"
        ok=0
    else
        log_success "Script de sync presente: ${SCRIPTS_DIR}/nfs-sync.sh"
    fi

    # Punto de montaje existe
    if [[ ! -d "$NFS_SYNC_MOUNT_POINT" ]]; then
        log_error "Punto de montaje no existe: $NFS_SYNC_MOUNT_POINT"
        ok=0
    else
        log_success "Punto de montaje existe: $NFS_SYNC_MOUNT_POINT"
    fi

    # Entrada en fstab
    if grep -qF "${NFS_SYNC_REMOTE_HOST}:${NFS_SYNC_REMOTE_PATH}" /etc/fstab 2>/dev/null; then
        log_success "Entrada fstab presente para ${NFS_SYNC_REMOTE_HOST}:${NFS_SYNC_REMOTE_PATH}"
    else
        log_warn "Entrada fstab no encontrada para ${NFS_SYNC_REMOTE_HOST}:${NFS_SYNC_REMOTE_PATH}"
    fi

    # Conectividad al host remoto
    log_info "Verificando conectividad con ${NFS_SYNC_REMOTE_HOST}..."
    if ping -c 1 -W 3 "$NFS_SYNC_REMOTE_HOST" &>/dev/null; then
        log_success "Host remoto accesible: $NFS_SYNC_REMOTE_HOST"
    else
        log_warn "No se puede hacer ping a ${NFS_SYNC_REMOTE_HOST} (puede ser normal si ICMP está bloqueado)"
    fi

    # Timer systemd activo (solo si no es cron)
    if [[ "${SCHEDULE_TYPE:-systemd}" != "cron" ]]; then
        if systemctl is-active --quiet nfs-sync.timer 2>/dev/null; then
            log_success "Timer nfs-sync.timer activo"
        else
            log_warn "Timer nfs-sync.timer no está activo"
        fi
    fi

    if [[ "$ok" -eq 0 ]]; then
        return 1
    fi
    return 0
}
