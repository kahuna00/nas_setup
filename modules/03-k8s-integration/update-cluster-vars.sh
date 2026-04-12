#!/usr/bin/env bash
# modules/03-k8s-integration/update-cluster-vars.sh
# Actualiza cluster-vars.yaml en el repositorio k8-homelab
# ESTADO: Preparado para uso futuro — activar desde setup.sh

update_nfs_path() {
    local cluster_vars="${K8S_HOMELAB_PATH}/clusters/kahunaz/cluster-vars.yaml"

    log_info "Actualizando NFS_PATH en cluster-vars.yaml..."

    [[ ! -f "$cluster_vars" ]] && {
        log_error "No se encontró cluster-vars.yaml en: $cluster_vars"
        log_info "Verifica que K8S_HOMELAB_PATH esté configurado correctamente en .env"
        return 1
    }

    echo -e "  ${BOLD}Valor actual en cluster-vars.yaml:${RESET}"
    grep "NFS_PATH\|NFS_SERVER" "$cluster_vars" | while read -r line; do
        echo -e "  ${DIM}  $line${RESET}"
    done
    echo ""

    local new_path="${MERGERFS_POOL_PATH:-}"
    if [[ -z "$new_path" ]]; then
        read -rp "$(echo -e "  ${BOLD}Nueva ruta NFS_PATH: ${RESET}")" new_path
    fi

    [[ -z "$new_path" ]] && { log_warn "Sin nueva ruta — cancelando"; return 0; }

    # Validate the path exists
    [[ ! -d "$new_path" ]] && {
        log_warn "El directorio $new_path no existe aún — ¿continuar de todas formas?"
        confirm "¿Aplicar aunque el directorio no exista?" "N" || return 0
    }

    patch_cluster_vars "NFS_PATH" "$new_path" "$cluster_vars"

    echo ""
    log_info "Cambio aplicado en: $cluster_vars"

    if confirm "¿Hacer commit y push para que Flux reconcilie?" "Y"; then
        pushd "$K8S_HOMELAB_PATH" > /dev/null
        git add "clusters/kahunaz/cluster-vars.yaml"
        git commit -m "chore: update NFS_PATH to ${new_path} via nas-setup"
        git push
        popd > /dev/null
        log_success "Push completado — Flux reconciliará en ~2 minutos"
        log_info "Monitorea con: kubectl get kustomization -A -w"
    else
        log_info "Cambio guardado localmente. Haz push manualmente cuando estés listo."
    fi
}
