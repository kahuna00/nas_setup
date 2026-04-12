#!/usr/bin/env bash
# tests/test-nfs.sh — Verifica que NFS esté correctamente configurado

NAS_SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${NAS_SETUP_DIR}/lib/colors.sh"
source "${NAS_SETUP_DIR}/lib/logging.sh"
source "${NAS_SETUP_DIR}/lib/os.sh"
source "${NAS_SETUP_DIR}/lib/env.sh"
source "${NAS_SETUP_DIR}/lib/idempotency.sh"
source "${NAS_SETUP_DIR}/lib/k8s.sh"

detect_os; detect_pkg_manager
load_env

PASS=0; FAIL=0
_pass() { log_success "$1"; ((PASS++)); }
_fail() { log_error "$1"; ((FAIL++)); }

echo ""
print_header "TEST: NFS"

# ── Test 1: nfs-server corriendo ──────────────────────────────────────────────
if systemctl is-active --quiet nfs-server; then
    _pass "nfs-server está activo"
else
    _fail "nfs-server NO está activo"
fi

# ── Test 2: exports activos ───────────────────────────────────────────────────
# exportfs -v is reliable; showmount requires rpcbind which may not run on NFSv4-only setups
if exportfs -v 2>/dev/null | grep -q "${NFS_SHARE_DIR}"; then
    _pass "Share principal exportada: ${NFS_SHARE_DIR}"
else
    _fail "Share principal NO está en exports activos: ${NFS_SHARE_DIR}"
fi

# ── Test 3: mount/write/read/umount ───────────────────────────────────────────
# Use the actual server IP — localhost (127.0.0.1) is outside the allowed NFS network
SERVER_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
SERVER_IP="${SERVER_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
TEST_MOUNT=$(mktemp -d)
if mount -t nfs -o nfsvers=4.1 "${SERVER_IP}:${NFS_SHARE_DIR}" "$TEST_MOUNT" 2>/dev/null; then
    TEST_FILE="${TEST_MOUNT}/nas-setup-test-$$.txt"
    if echo "test" > "$TEST_FILE" && cat "$TEST_FILE" &>/dev/null && rm -f "$TEST_FILE"; then
        _pass "NFS mount → write → read → delete: OK"
    else
        _fail "NFS montado pero fallo en escritura/lectura"
    fi
    umount "$TEST_MOUNT" 2>/dev/null || true
else
    _fail "No se pudo montar NFS desde localhost"
fi
rm -rf "$TEST_MOUNT"

# ── Test 4: Kubernetes PVs ────────────────────────────────────────────────────
if kubectl_available; then
    if check_nfs_mounts; then
        _pass "Kubernetes PVs NFS en estado Bound"
    else
        _fail "Algunos Kubernetes PVs NFS no están Bound"
    fi
else
    log_warn "kubectl no disponible — saltando test de PVs"
fi

# ── Resultado ─────────────────────────────────────────────────────────────────
echo ""
echo -e "  Resultados: ${GREEN}${PASS} pasaron${RESET} | ${RED}${FAIL} fallaron${RESET}"
[[ "$FAIL" -eq 0 ]]
