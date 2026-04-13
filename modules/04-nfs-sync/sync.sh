#!/usr/bin/env bash
# modules/04-nfs-sync/sync.sh — Genera el script de runtime rsync para NFS remoto→local
# Depends on: lib/{colors,logging,idempotency}.sh

SCRIPTS_DIR="/var/lib/nas-setup/scripts"

_build_rsync_excludes() {
    local args=""
    if [[ -n "${NFS_SYNC_EXCLUDES:-}" ]]; then
        local patterns=()
        IFS=':' read -ra patterns <<< "$NFS_SYNC_EXCLUDES"
        for p in "${patterns[@]}"; do
            [[ -z "$p" ]] && continue
            args+=" --exclude='${p}'"
        done
    fi
    echo "$args"
}

_create_sync_script() {
    mkdir -p "$SCRIPTS_DIR"

    local bw_opt=""
    if [[ "${NFS_SYNC_BW_LIMIT:-0}" -gt 0 ]]; then
        bw_opt="--bwlimit=${NFS_SYNC_BW_LIMIT}"
    fi

    local exclude_args
    exclude_args=$(_build_rsync_excludes)

    cat > "${SCRIPTS_DIR}/nfs-sync.sh" << SCRIPT
#!/bin/bash
# nfs-sync — generado por nas-setup
# Sincroniza NFS remoto → local usando rsync
# Fuente : ${NFS_SYNC_REMOTE_HOST}:${NFS_SYNC_REMOTE_PATH}
# Destino: ${NFS_SYNC_DEST_DIR}
set -uo pipefail

MOUNT_POINT="${NFS_SYNC_MOUNT_POINT}"
DEST_DIR="${NFS_SYNC_DEST_DIR}"
LOG_TAG="nfs-sync"
RSYNC_OPTS="${NFS_SYNC_RSYNC_OPTS} ${bw_opt} ${exclude_args}"

log() { logger -t "\$LOG_TAG" "\$1"; echo "\$(date '+%Y-%m-%d %H:%M:%S') \$1"; }

# ── Montar NFS remoto si no está montado ────────────────────────────────────
if ! mountpoint -q "\$MOUNT_POINT"; then
    log "Montando NFS remoto en \$MOUNT_POINT..."
    if ! mount "\$MOUNT_POINT"; then
        log "ERROR: no se pudo montar \$MOUNT_POINT"
        exit 1
    fi
    log "Montaje OK"
    MOUNTED_BY_US=1
else
    log "NFS remoto ya montado en \$MOUNT_POINT"
    MOUNTED_BY_US=0
fi

# ── Crear destino si no existe ───────────────────────────────────────────────
mkdir -p "\$DEST_DIR"

# ── Rsync ────────────────────────────────────────────────────────────────────
log "Iniciando rsync: \$MOUNT_POINT/ → \$DEST_DIR/"
START=\$(date +%s)

# shellcheck disable=SC2086
# set -e desactivado para rsync: capturamos su exit code manualmente.
# exit 23 = archivos parcialmente no transferidos (p.ej. ficheros activos de BD/Prometheus)
# exit 24 = archivos desaparecieron durante la transferencia (normal en NFS en vivo)
# Ambos se tratan como advertencia, no como error.
rsync \$RSYNC_OPTS "\$MOUNT_POINT/" "\$DEST_DIR/" && EXIT_CODE=0 || EXIT_CODE=\$?

ELAPSED=\$(( \$(date +%s) - START ))
if [[ \$EXIT_CODE -eq 0 ]]; then
    log "Sync completado en \${ELAPSED}s"
elif [[ \$EXIT_CODE -eq 23 || \$EXIT_CODE -eq 24 ]]; then
    log "Sync completado con advertencias (archivos en tránsito o activos, código \${EXIT_CODE}) en \${ELAPSED}s"
    EXIT_CODE=0
else
    log "ERROR: rsync finalizó con código \$EXIT_CODE después de \${ELAPSED}s"
fi

# ── Desmontar si este script hizo el montaje ─────────────────────────────────
if [[ "\$MOUNTED_BY_US" -eq 1 ]]; then
    umount "\$MOUNT_POINT" && log "NFS remoto desmontado" || log "WARN: no se pudo desmontar \$MOUNT_POINT"
fi

exit \$EXIT_CODE
SCRIPT

    chmod +x "${SCRIPTS_DIR}/nfs-sync.sh"
    log_success "Script de sync creado: ${SCRIPTS_DIR}/nfs-sync.sh"
}

configure_sync() {
    skip_if_done "nfs_sync_script" "generación del script de sync" && return 0

    if ! command -v rsync &>/dev/null; then
        log_info "Instalando rsync..."
        apt_update_once
        pkg_install rsync || return 1
    fi

    log_info "Generando script de sync en ${SCRIPTS_DIR}/nfs-sync.sh..."
    _create_sync_script || return 1

    state_mark "nfs_sync_script"
}
