#!/usr/bin/env bash
# modules/04-nfs-sync/mount.sh — Monta el NFS remoto en el punto de montaje local
# Depends on: lib/{colors,logging,idempotency}.sh

_create_mount_point() {
    if [[ ! -d "$NFS_SYNC_MOUNT_POINT" ]]; then
        mkdir -p "$NFS_SYNC_MOUNT_POINT"
        log_success "Directorio de montaje creado: $NFS_SYNC_MOUNT_POINT"
    else
        log_debug "Directorio de montaje ya existe: $NFS_SYNC_MOUNT_POINT"
    fi
}

_add_fstab_entry() {
    local fstab="/etc/fstab"
    local entry="${NFS_SYNC_REMOTE_HOST}:${NFS_SYNC_REMOTE_PATH}  ${NFS_SYNC_MOUNT_POINT}  nfs  ${NFS_SYNC_MOUNT_OPTIONS}  0  0"
    local marker="# nas-setup: nfs-sync remote"

    # Skip if entry already present
    if grep -qF "${NFS_SYNC_REMOTE_HOST}:${NFS_SYNC_REMOTE_PATH}" "$fstab" 2>/dev/null; then
        log_info "Entrada fstab para el NFS remoto ya existe — no se modifica"
        return 0
    fi

    {
        echo ""
        echo "${marker}"
        echo "${entry}"
    } >> "$fstab"
    log_success "Entrada añadida a /etc/fstab (noauto — montado por el script de sync)"
}

configure_remote_mount() {
    skip_if_done "nfs_sync_mount" "configuración de montaje NFS remoto" && return 0

    log_info "Verificando que nfs-common esté instalado..."
    if ! dpkg -s nfs-common &>/dev/null 2>&1; then
        apt_update_once
        pkg_install nfs-common || return 1
    fi

    log_info "Creando punto de montaje: $NFS_SYNC_MOUNT_POINT"
    _create_mount_point

    log_info "Añadiendo entrada a /etc/fstab..."
    _add_fstab_entry || return 1

    state_mark "nfs_sync_mount"
    log_success "Montaje remoto configurado: ${NFS_SYNC_REMOTE_HOST}:${NFS_SYNC_REMOTE_PATH} → ${NFS_SYNC_MOUNT_POINT}"
}
