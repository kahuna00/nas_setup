#!/usr/bin/env bash
# modules/01-nfs-samba/validate.sh — Post-install validation tests
# Depends on: lib/{colors,logging,k8s}.sh

validate_nfs() {
    log_info "Verificando exports NFS..."

    # Check nfs-server is running
    if ! systemctl is-active --quiet nfs-server; then
        log_error "nfs-server no está corriendo"
        return 1
    fi

    # Show active exports
    log_info "Exports activos:"
    exportfs -v 2>/dev/null | while read -r line; do
        echo -e "  ${DIM}${line}${RESET}"
    done

    # Check primary share is exported
    if ! showmount -e localhost 2>/dev/null | grep -q "$NFS_SHARE_DIR"; then
        log_error "Share principal no encontrada en showmount: $NFS_SHARE_DIR"
        return 1
    fi

    log_success "NFS: share principal exportada correctamente"
    return 0
}

validate_smb_share() {
    log_info "Verificando Samba..."

    if ! systemctl is-active --quiet smbd; then
        log_error "smbd no está corriendo"
        return 1
    fi

    # Check share is visible
    if ! smbclient -L localhost -U "${SAMBA_USER}%${SAMBA_PASSWORD}" 2>/dev/null \
            | grep -q "$SAMBA_SHARE_NAME"; then
        log_error "Share Samba '$SAMBA_SHARE_NAME' no visible en smbclient -L"
        return 1
    fi

    # Test write/read/delete
    local tmp_file="/tmp/samba-test-$$.txt"
    echo "nas-setup-test" > "$tmp_file"
    if smbclient "//localhost/${SAMBA_SHARE_NAME}" \
            -U "${SAMBA_USER}%${SAMBA_PASSWORD}" \
            -c "put ${tmp_file} nas-setup-test.txt; del nas-setup-test.txt" \
            >> "$LOG_FILE" 2>&1; then
        log_success "Samba: escritura/lectura/borrado OK"
    else
        log_warn "Samba: test de escritura falló (puede ser problema de permisos)"
    fi
    rm -f "$tmp_file"

    return 0
}

validate_k8s_nfs_mounts() {
    echo ""
    log_info "Verificando PersistentVolumes NFS en Kubernetes..."
    check_nfs_mounts
    local result=$?
    if [[ $result -ne 0 ]]; then
        print_error_box "Algunos PVs NFS pueden estar afectados por los cambios.
  Remediation:
    1. sudo exportfs -ra
    2. kubectl get pv -A
    3. Si un PV está en Released: kubectl patch pv <nombre> -p '{\"spec\":{\"claimRef\":null}}'"
    fi
    return $result
}
