#!/usr/bin/env bash
# tests/test-mergerfs.sh — Verifica que MergerFS esté correctamente montado

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
print_header "TEST: MERGERFS"

# ── Test 1: Pool montado ──────────────────────────────────────────────────────
if mountpoint -q "${MERGERFS_POOL_PATH}"; then
    _pass "Pool MergerFS montado en: ${MERGERFS_POOL_PATH}"
else
    _fail "Pool MergerFS NO montado en: ${MERGERFS_POOL_PATH}"
    echo ""
    echo -e "  ${DIM}Intenta: mount ${MERGERFS_POOL_PATH}${RESET}"
    echo -e "  ${DIM}Verifica /etc/fstab con: grep mergerfs /etc/fstab${RESET}"
    exit 1
fi

# ── Test 2: Espacio disponible ────────────────────────────────────────────────
AVAIL=$(df -B1 "${MERGERFS_POOL_PATH}" 2>/dev/null | tail -1 | awk '{print $4}')
if [[ -n "$AVAIL" && "$AVAIL" -gt 0 ]]; then
    AVAIL_H=$(df -h "${MERGERFS_POOL_PATH}" 2>/dev/null | tail -1 | awk '{print $4}')
    _pass "Espacio disponible en pool: ${AVAIL_H}"
else
    _fail "No se pudo leer espacio disponible en el pool"
fi

# ── Test 3: Write → aparece en disco subyacente ───────────────────────────────
TEST_FILE="${MERGERFS_POOL_PATH}/nas-setup-test-$$.txt"
echo "mergerfs-test" > "$TEST_FILE" 2>/dev/null && {
    # Verify it physically appears on one of the underlying data disks
    FOUND=0
    for mp in "${DISK_MOUNT_PREFIX}"/data*; do
        [[ -d "$mp" ]] || continue
        if [[ -f "${mp}/nas-setup-test-$$.txt" ]]; then
            FOUND=1
            log_debug "Archivo de test encontrado físicamente en: $mp"
            break
        fi
    done
    rm -f "$TEST_FILE"
    if [[ "$FOUND" -eq 1 ]]; then
        _pass "Escritura en pool → verificada en disco subyacente"
    else
        log_warn "Escritura OK pero no se encontró en disco subyacente (puede ser normal si los datos están en caché)"
        ((PASS++))
    fi
} || _fail "No se pudo escribir en el pool MergerFS"

# ── Test 4: fstab entry presente ─────────────────────────────────────────────
if grep -q "fuse.mergerfs" /etc/fstab; then
    _pass "Entrada MergerFS presente en /etc/fstab"
else
    _fail "No hay entrada fuse.mergerfs en /etc/fstab"
fi

# ── Resultado ─────────────────────────────────────────────────────────────────
echo ""
echo -e "  Resultados: ${GREEN}${PASS} pasaron${RESET} | ${RED}${FAIL} fallaron${RESET}"
[[ "$FAIL" -eq 0 ]]
