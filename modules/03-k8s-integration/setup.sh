#!/usr/bin/env bash
# modules/03-k8s-integration/setup.sh — Módulo 3: Kubernetes Integration

NAS_SETUP_DIR="$(dirname "$(dirname "$(dirname "${BASH_SOURCE[0]}")")")"

source "${NAS_SETUP_DIR}/modules/03-k8s-integration/update-cluster-vars.sh"
source "${NAS_SETUP_DIR}/modules/03-k8s-integration/generate-pvs.sh"

setup_k8s_integration() {
    print_header "MÓDULO 3: INTEGRACIÓN KUBERNETES"

    validate_env K8S_HOMELAB_PATH K8S_PV_NAMESPACE K8S_MANIFESTS_OUTPUT K8S_STORAGE_MODE || return 1

    if ! kubectl_available; then
        log_error "kubectl no disponible o cluster no alcanzable"
        log_info "Asegúrate de que k3s esté corriendo y KUBECONFIG esté configurado"
        return 1
    fi

    local mode="${K8S_STORAGE_MODE:-nfs}"
    local mode_label
    if [[ "$mode" == "local" ]]; then
        mode_label="${YELLOW}local (hostPath)${RESET}"
    else
        mode_label="${GREEN}NFS${RESET}"
    fi

    echo -e "  ${BOLD}Modo de storage activo:${RESET} ${mode_label}"
    echo -e "  ${DIM}k8-homelab: ${K8S_HOMELAB_PATH}${RESET}"
    echo -e "  ${DIM}Namespace  : ${K8S_PV_NAMESPACE}${RESET}"
    echo ""

    echo -e "  ${BOLD}¿Qué deseas hacer?${RESET}"
    echo ""
    echo -e "  ${CYAN}[1]${RESET} Cambiar modo de storage  ${DIM}(actual: ${mode})${RESET}"
    echo -e "      Actualiza cluster-vars.yaml y cambia entre NFS ↔ local"
    echo ""
    echo -e "  ${CYAN}[2]${RESET} Generar manifests PV/PVC"
    echo -e "      Crea archivos YAML listos para kubectl apply (modo: ${mode})"
    echo ""
    echo -e "  ${CYAN}[3]${RESET} Actualizar NFS_PATH en cluster-vars.yaml"
    echo -e "      Cambia solo la ruta del share sin cambiar de modo"
    echo ""
    echo -e "  ${CYAN}[4]${RESET} Ver guía de instalación de Longhorn"
    echo ""
    echo -e "  ${CYAN}[0]${RESET} Volver"
    echo ""

    local choice
    read -rp "$(echo -e "  ${BOLD}Opción: ${RESET}")" choice

    case "$choice" in
        1) _switch_storage_mode ;;
        2) generate_pv_manifests ;;
        3) update_nfs_path ;;
        4) show_longhorn_guide ;;
        0) return 0 ;;
        *) log_warn "Opción inválida" ;;
    esac
}

# Submenú para cambiar de modo
_switch_storage_mode() {
    local current="${K8S_STORAGE_MODE:-nfs}"

    echo ""
    echo -e "  ${BOLD}Selecciona el modo de storage:${RESET}"
    echo ""
    echo -e "  ${CYAN}[1]${RESET} ${BOLD}NFS${RESET} — pods acceden al storage vía NFS"
    echo -e "      ${DIM}Storage class: nfs-csi | ReadWriteMany | multi-nodo OK${RESET}"
    echo ""
    echo -e "  ${CYAN}[2]${RESET} ${BOLD}Local (hostPath)${RESET} — pods acceden directamente al filesystem del nodo"
    echo -e "      ${DIM}Sin overhead de red | Solo single-node | Sin nfs-csi${RESET}"
    echo ""
    echo -e "  Modo actual: ${CYAN}${current}${RESET}"
    echo ""

    local choice
    read -rp "$(echo -e "  ${BOLD}Opción: ${RESET}")" choice

    case "$choice" in
        1)
            K8S_STORAGE_MODE=nfs
            export K8S_STORAGE_MODE
            update_storage_mode
            ;;
        2)
            K8S_STORAGE_MODE=local
            export K8S_STORAGE_MODE
            update_storage_mode
            ;;
        *)
            log_warn "Opción inválida — sin cambios"
            ;;
    esac
}
