#!/usr/bin/env bash
# modules/03-k8s-integration/setup.sh — Módulo 3: Kubernetes Integration
#
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  ⚠  MÓDULO EN DESARROLLO — NO EJECUTAR EN PRODUCCIÓN AÚN                   ║
# ║                                                                              ║
# ║  Este módulo está documentado y preparado para uso futuro.                  ║
# ║  Activa cuando estés listo para integrar el NAS con el cluster k8s.         ║
# ║                                                                              ║
# ║  Para activar: elimina la línea "return 0" de setup_k8s_integration()       ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

NAS_SETUP_DIR="$(dirname "$(dirname "$(dirname "${BASH_SOURCE[0]}")")")"

source "${NAS_SETUP_DIR}/modules/03-k8s-integration/update-cluster-vars.sh"
source "${NAS_SETUP_DIR}/modules/03-k8s-integration/generate-pvs.sh"

setup_k8s_integration() {
    print_header "MÓDULO 3: INTEGRACIÓN KUBERNETES [EN DESARROLLO]"

    echo ""
    echo -e "  ${YELLOW}${BOLD}Este módulo aún no está activo.${RESET}"
    echo ""
    echo -e "  Cuando estés listo para usarlo, este módulo te permitirá:"
    echo ""
    echo -e "  ${CYAN}1.${RESET} Actualizar ${BOLD}cluster-vars.yaml${RESET} con nuevas rutas NFS"
    echo -e "     (Flux reconcilia automáticamente en ~2 minutos)"
    echo ""
    echo -e "  ${CYAN}2.${RESET} Generar manifests de ${BOLD}PersistentVolume + PVC${RESET}"
    echo -e "     para exponer el pool MergerFS como almacenamiento Kubernetes"
    echo ""
    echo -e "  ${CYAN}3.${RESET} Ver recomendaciones de GUI para gestión de storage:"
    echo -e "     ${DIM}• Cockpit (OS management)${RESET}"
    echo -e "     ${DIM}• Longhorn (K8s native block storage + dashboard)${RESET}"
    echo -e "     ${DIM}• Filebrowser (ya desplegado en tu cluster)${RESET}"
    echo ""
    echo -e "  ${DIM}Repositorio k8-homelab detectado en: ${K8S_HOMELAB_PATH:-no configurado}${RESET}"
    echo ""

    # ── MÓDULO DESACTIVADO — descomenta para activar ──────────────────────────
    return 0

    # shellcheck disable=SC2317
    validate_env K8S_HOMELAB_PATH K8S_PV_NAMESPACE K8S_MANIFESTS_OUTPUT || return 1

    if ! kubectl_available; then
        log_error "kubectl no disponible o cluster no alcanzable"
        log_info "Asegúrate de que k3s esté corriendo y KUBECONFIG esté configurado"
        return 1
    fi

    echo -e "  ${BOLD}¿Qué deseas hacer?${RESET}"
    echo -e "  ${CYAN}[1]${RESET} Actualizar NFS_PATH en cluster-vars.yaml"
    echo -e "  ${CYAN}[2]${RESET} Generar manifests PV/PVC para el pool MergerFS"
    echo -e "  ${CYAN}[3]${RESET} Ambos"
    echo -e "  ${CYAN}[4]${RESET} Ver guía de instalación de Longhorn"
    echo -e "  ${CYAN}[0]${RESET} Salir"
    echo ""

    local choice
    read -rp "$(echo -e "  Opción: ")" choice

    case "$choice" in
        1) update_nfs_path ;;
        2) generate_pv_manifests ;;
        3) update_nfs_path && generate_pv_manifests ;;
        4) show_longhorn_guide ;;
        0) return 0 ;;
        *) log_warn "Opción inválida" ;;
    esac
}
