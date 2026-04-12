#!/usr/bin/env bash
# modules/03-k8s-integration/generate-pvs.sh
# Genera manifests PV + PVC para exponer shares NFS en Kubernetes
# ESTADO: Preparado para uso futuro — activar desde setup.sh

NAS_SETUP_DIR="$(dirname "$(dirname "$(dirname "${BASH_SOURCE[0]}")")")"
TEMPLATE_DIR="${NAS_SETUP_DIR}/templates"

generate_pv_manifests() {
    local output_dir="${K8S_MANIFESTS_OUTPUT:-./generated/k8s}"
    mkdir -p "$output_dir"

    log_info "Generando manifests PV/PVC en: $output_dir"

    # Build list of shares to expose
    local shares=("$NFS_SHARE_DIR")
    if [[ -n "${NFS_EXTRA_DIRS:-}" ]]; then
        local extras=()
        split_colon_var NFS_EXTRA_DIRS extras
        shares+=("${extras[@]}")
    fi
    # Add MergerFS pool if configured
    [[ -n "${MERGERFS_POOL_PATH:-}" ]] && shares+=("$MERGERFS_POOL_PATH")

    # Get NFS server IP
    local nfs_server
    nfs_server=$(hostname -I | awk '{print $1}')

    echo ""
    echo -e "  ${BOLD}Shares a exponer como PVs:${RESET}"
    for share in "${shares[@]}"; do
        [[ -z "$share" ]] && continue
        echo -e "  ${CYAN}•${RESET} $share"
    done
    echo ""

    local pv_size
    read -rp "$(echo -e "  ${BOLD}Capacidad por PV (ej: 512Gi, 1Ti): ${RESET}")" pv_size
    pv_size="${pv_size:-100Gi}"

    for share in "${shares[@]}"; do
        [[ -z "$share" ]] && continue

        local pv_name
        pv_name=$(echo "$share" | tr '/' '-' | sed 's/^-//')
        local manifest_file="${output_dir}/pv-${pv_name}.yaml"

        export PV_NAME="$pv_name"
        export PV_SIZE="$pv_size"
        export NFS_SERVER="$nfs_server"
        export NFS_SHARE_PATH="$share"

        envsubst < "${TEMPLATE_DIR}/k8s-nfs-pv.yaml.j2" > "$manifest_file"
        log_success "Manifest generado: $manifest_file"
    done

    echo ""
    log_info "Para aplicar al cluster:"
    echo -e "  ${BOLD}kubectl apply -f ${output_dir}/${RESET}"
    echo ""
    log_info "Para dry-run primero:"
    echo -e "  ${BOLD}kubectl apply --dry-run=client -f ${output_dir}/${RESET}"
    echo ""

    print_recommendation "Si usas Flux GitOps, copia los manifests a k8-homelab/apps/kahunaz/
  y haz push — Flux los aplicará automáticamente en ~2 minutos."
}

show_longhorn_guide() {
    print_header "GUÍA: LONGHORN (K8s Native Storage Dashboard)"
    cat << 'GUIDE'

  Longhorn es un sistema de almacenamiento distribuido CNCF para Kubernetes.
  Ofrece: snapshots, backups S3, replicación, y un dashboard web integrado.

  REQUISITOS:
  • open-iscsi instalado en todos los nodos: apt install open-iscsi
  • nfs-common: apt install nfs-common
  • Espacio en disco de bloque (no NFS — complementa tu setup actual)

  INSTALACIÓN (Helm / GitOps Flux):

  1. Añade a infrastructure/sources/helm-repos.yaml:
     ---
     apiVersion: source.toolkit.fluxcd.io/v1
     kind: HelmRepository
     metadata:
       name: longhorn
       namespace: flux-system
     spec:
       interval: 24h
       url: https://charts.longhorn.io

  2. Crea infrastructure/controllers/longhorn.yaml:
     ---
     apiVersion: helm.toolkit.fluxcd.io/v2
     kind: HelmRelease
     metadata:
       name: longhorn
       namespace: longhorn-system
     spec:
       interval: 30m
       chart:
         spec:
           chart: longhorn
           version: ">=1.7.0 <2.0.0"
           sourceRef:
             kind: HelmRepository
             name: longhorn
             namespace: flux-system
       values:
         defaultSettings:
           defaultReplicaCount: 1  # Single-node cluster
         ingress:
           enabled: true
           host: longhorn.kahunaz.duckdns.org

  3. Haz push y Flux lo desplegará.
     Dashboard en: https://longhorn.kahunaz.duckdns.org

  NOTA: Longhorn provee almacenamiento de bloque (ReadWriteOnce).
  Tu NFS-CSI actual provee ReadWriteMany. Son complementarios.
  Usa Longhorn para apps que necesiten I/O intensivo o snapshots.

GUIDE
}
