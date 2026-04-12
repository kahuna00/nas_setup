#!/usr/bin/env bash
# lib/k8s.sh — Kubernetes integration utilities
# Used by: modules/01-nfs-samba/validate.sh, modules/03-k8s-integration/
# Depends on: lib/logging.sh

# Check if kubectl is available and cluster is reachable
kubectl_available() {
    command -v kubectl &>/dev/null && kubectl cluster-info &>/dev/null 2>&1
}

# Query all NFS PersistentVolumes and print their status
# Returns 1 if any previously-Bound PV is no longer Bound
check_nfs_mounts() {
    local nfs_server="${NFS_SERVER:-${NFS_SHARE_DIR}}"

    if ! kubectl_available; then
        log_warn "kubectl no disponible o cluster no alcanzable — saltando verificación de PVs"
        return 0
    fi

    log_info "Verificando PersistentVolumes NFS en el cluster..."

    local pv_json
    pv_json=$(kubectl get pv -A -o json 2>/dev/null) || {
        log_warn "No se pudo obtener PVs del cluster"
        return 0
    }

    # Print table header
    printf "\n  %-30s %-12s %-10s %-20s\n" "PV NAME" "STATUS" "CAPACITY" "NFS PATH"
    printf "  %-30s %-12s %-10s %-20s\n" "──────────────────────────────" "────────────" "──────────" "────────────────────"

    local any_failed=0

    # Parse PVs using python3 (more reliable than jq on ARM)
    while IFS='|' read -r name status capacity path; do
        local color="$GREEN"
        [[ "$status" != "Bound" ]] && color="$RED" && any_failed=1
        printf "  ${color}%-30s %-12s %-10s %-20s${RESET}\n" "$name" "$status" "$capacity" "$path"
    done < <(python3 -c "
import json, sys
data = json.load(sys.stdin)
for item in data.get('items', []):
    nfs = item.get('spec', {}).get('nfs', {})
    if nfs:
        name = item['metadata']['name']
        status = item.get('status', {}).get('phase', 'Unknown')
        cap = item.get('spec', {}).get('capacity', {}).get('storage', '?')
        path = nfs.get('path', '?')
        print(f'{name}|{status}|{cap}|{path}')
" <<< "$pv_json")

    echo ""

    if [[ "$any_failed" -eq 1 ]]; then
        log_error "Uno o más PVs NFS no están en estado Bound"
        log_info "Remediation: ejecuta 'exportfs -ra' y verifica con 'showmount -e localhost'"
        return 1
    fi

    log_success "Todos los PVs NFS están en estado Bound"
    return 0
}

# Surgically patch a key in cluster-vars.yaml using yq
# patch_cluster_vars KEY VALUE YAML_FILE
patch_cluster_vars() {
    local key="$1"
    local value="$2"
    local yaml_file="$3"

    require_cmd yq "apt-get install -y yq  # o: snap install yq" || return 1

    if [[ ! -f "$yaml_file" ]]; then
        log_error "Archivo no encontrado: $yaml_file"
        return 1
    fi

    # Show what we're about to change
    local current
    current=$(yq e ".data.${key}" "$yaml_file" 2>/dev/null)
    log_info "Actualizando ${key}: '${current}' → '${value}'"

    # Make backup
    cp "$yaml_file" "${yaml_file}.bak.$(date +%s)"

    # Patch only the specific key
    yq e ".data.${key} = \"${value}\"" -i "$yaml_file"
    log_success "cluster-vars.yaml actualizado"

    # Show diff
    diff "${yaml_file}.bak."* "$yaml_file" || true
}
