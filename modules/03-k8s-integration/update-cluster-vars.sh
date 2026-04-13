#!/usr/bin/env bash
# modules/03-k8s-integration/update-cluster-vars.sh
# Actualiza cluster-vars.yaml en el repositorio k8-homelab

_cluster_vars_file() {
    echo "${K8S_HOMELAB_PATH}/clusters/kahunaz/cluster-vars.yaml"
}

_show_current_storage_vars() {
    local yaml_file
    yaml_file=$(_cluster_vars_file)
    echo -e "  ${BOLD}Valores actuales en cluster-vars.yaml:${RESET}"
    grep -E "NFS_SERVER|NFS_PATH|STORAGE_MODE|STORAGE_CLASS" "$yaml_file" 2>/dev/null | while read -r line; do
        echo -e "  ${DIM}  $line${RESET}"
    done
    echo ""
}

_commit_and_push() {
    local message="$1"
    if confirm "¿Hacer commit y push para que Flux reconcilie?" "Y"; then
        pushd "$K8S_HOMELAB_PATH" > /dev/null
        git add "clusters/kahunaz/cluster-vars.yaml"
        git commit -m "$message"
        git push
        popd > /dev/null
        log_success "Push completado — Flux reconciliará en ~2 minutos"
        log_info "Monitorea con: kubectl get kustomization -A -w"
    else
        log_info "Cambio guardado localmente. Haz push manualmente cuando estés listo."
    fi
}

update_nfs_path() {
    local cluster_vars
    cluster_vars=$(_cluster_vars_file)

    log_info "Actualizando NFS_PATH en cluster-vars.yaml..."

    [[ ! -f "$cluster_vars" ]] && {
        log_error "No se encontró cluster-vars.yaml en: $cluster_vars"
        log_info "Verifica que K8S_HOMELAB_PATH esté configurado correctamente en .env"
        return 1
    }

    _show_current_storage_vars

    local new_path="${MERGERFS_POOL_PATH:-}"
    if [[ -z "$new_path" ]]; then
        read -rp "$(echo -e "  ${BOLD}Nueva ruta NFS_PATH: ${RESET}")" new_path
    fi

    [[ -z "$new_path" ]] && { log_warn "Sin nueva ruta — cancelando"; return 0; }

    [[ ! -d "$new_path" ]] && {
        log_warn "El directorio $new_path no existe aún"
        confirm "¿Aplicar aunque el directorio no exista?" "N" || return 0
    }

    patch_cluster_vars "NFS_PATH" "$new_path" "$cluster_vars"
    _commit_and_push "chore: update NFS_PATH to ${new_path} via nas-setup"
}

# Cambia el modo de storage en cluster-vars.yaml entre nfs y local
# En modo nfs:   actualiza NFS_SERVER, NFS_PATH y STORAGE_MODE=nfs
# En modo local: actualiza STORAGE_PATH, STORAGE_MODE=local y STORAGE_CLASS=local-path
update_storage_mode() {
    local cluster_vars
    cluster_vars=$(_cluster_vars_file)
    local mode="${K8S_STORAGE_MODE:-nfs}"

    [[ ! -f "$cluster_vars" ]] && {
        log_error "No se encontró cluster-vars.yaml en: $cluster_vars"
        return 1
    }

    _show_current_storage_vars

    echo -e "  ${BOLD}Modo a aplicar: ${CYAN}${mode}${RESET}"
    echo ""

    case "$mode" in
        nfs)
            local nfs_server
            nfs_server=$(hostname -I | awk '{print $1}')
            local nfs_path="${NFS_SHARE_DIR}"

            echo -e "  ${DIM}NFS_SERVER → ${nfs_server}${RESET}"
            echo -e "  ${DIM}NFS_PATH   → ${nfs_path}${RESET}"
            echo -e "  ${DIM}STORAGE_MODE → nfs${RESET}"
            echo ""

            confirm "¿Aplicar modo NFS?" "Y" || return 0

            patch_cluster_vars "NFS_SERVER"   "$nfs_server"  "$cluster_vars" || return 1
            patch_cluster_vars "NFS_PATH"     "$nfs_path"    "$cluster_vars" || return 1
            patch_cluster_vars "STORAGE_MODE" "nfs"          "$cluster_vars" || return 1

            log_success "Cluster configurado en modo NFS"
            log_info "Storage class en uso: nfs-csi"
            _commit_and_push "chore: switch storage to NFS mode (${nfs_server}:${nfs_path})"
            ;;

        local)
            local node_name
            if kubectl_available; then
                node_name=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || hostname)
            else
                node_name=$(hostname)
            fi
            local local_path="${MERGERFS_POOL_PATH:-${NFS_SHARE_DIR}}"

            echo -e "  ${DIM}STORAGE_PATH  → ${local_path}${RESET}"
            echo -e "  ${DIM}STORAGE_MODE  → local${RESET}"
            echo -e "  ${DIM}Nodo fijado   → ${node_name}${RESET}"
            echo ""
            log_warn "Modo local: los pods quedan fijados al nodo '${node_name}'"
            log_warn "No usar en clusters multi-nodo"
            echo ""

            confirm "¿Aplicar modo local (hostPath)?" "Y" || return 0

            patch_cluster_vars "STORAGE_PATH" "$local_path" "$cluster_vars" || return 1
            patch_cluster_vars "STORAGE_MODE" "local"       "$cluster_vars" || return 1

            log_success "Cluster configurado en modo local (hostPath)"
            log_info "Los PVs generados usarán hostPath en nodo: ${node_name}"
            _commit_and_push "chore: switch storage to local hostPath mode (${local_path})"
            ;;

        *)
            log_error "Modo desconocido: '${mode}'. Valores válidos: nfs, local"
            return 1
            ;;
    esac
}
