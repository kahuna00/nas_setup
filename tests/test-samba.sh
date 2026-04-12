#!/usr/bin/env bash
# tests/test-samba.sh — Verifica que Samba esté correctamente configurado

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
print_header "TEST: SAMBA"

# ── Test 1: smbd corriendo ────────────────────────────────────────────────────
if systemctl is-active --quiet smbd; then
    _pass "smbd está activo"
else
    _fail "smbd NO está activo"
fi

# ── Test 2: Share visible en listing ─────────────────────────────────────────
pkg_install smbclient 2>/dev/null || true

if smbclient -L localhost -U "${SAMBA_USER}%${SAMBA_PASSWORD}" 2>/dev/null \
        | grep -q "$SAMBA_SHARE_NAME"; then
    _pass "Share '${SAMBA_SHARE_NAME}' visible en smbclient -L"
else
    _fail "Share '${SAMBA_SHARE_NAME}' NO visible en smbclient -L localhost"
fi

# ── Test 3: Write/read/delete via Samba ──────────────────────────────────────
TMP_FILE=$(mktemp)
echo "nas-setup-test-content" > "$TMP_FILE"
TMP_NAME="nas-setup-test-$$.txt"

if smbclient "//localhost/${SAMBA_SHARE_NAME}" \
        -U "${SAMBA_USER}%${SAMBA_PASSWORD}" \
        -c "put ${TMP_FILE} ${TMP_NAME}; del ${TMP_NAME}" \
        >> "$LOG_FILE" 2>&1; then
    _pass "Samba: write → delete via smbclient: OK"
else
    _fail "Samba: test de escritura/borrado falló"
fi
rm -f "$TMP_FILE"

# ── Test 4: smb.conf válido ───────────────────────────────────────────────────
if testparm -s /etc/samba/smb.conf &>/dev/null; then
    _pass "smb.conf válido (testparm OK)"
else
    _fail "smb.conf tiene errores (testparm falló)"
fi

# ── Resultado ─────────────────────────────────────────────────────────────────
echo ""
echo -e "  Resultados: ${GREEN}${PASS} pasaron${RESET} | ${RED}${FAIL} fallaron${RESET}"
[[ "$FAIL" -eq 0 ]]
