#!/usr/bin/env bash
# tests/test-snapraid.sh — Verifica que SnapRAID esté correctamente configurado

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
print_header "TEST: SNAPRAID"

# ── Test 1: SnapRAID instalado ────────────────────────────────────────────────
if command -v snapraid &>/dev/null; then
    VER=$(snapraid --version 2>&1 | head -1)
    _pass "SnapRAID instalado: $VER"
else
    _fail "SnapRAID no está instalado"
    exit 1
fi

# ── Test 2: Configuración válida ──────────────────────────────────────────────
if [[ -f /etc/snapraid.conf ]]; then
    _pass "/etc/snapraid.conf existe"
else
    _fail "/etc/snapraid.conf no existe"
    exit 1
fi

# Verify config has data disks configured
DATA_LINES=$(grep -c "^data " /etc/snapraid.conf 2>/dev/null || echo 0)
if [[ "$DATA_LINES" -gt 0 ]]; then
    _pass "Configuración tiene ${DATA_LINES} disco(s) DATA definido(s)"
else
    _fail "snapraid.conf no tiene discos DATA configurados"
fi

# ── Test 3: snapraid diff ─────────────────────────────────────────────────────
DIFF_OUT=$(snapraid diff 2>&1)
DIFF_EXIT=$?
if [[ "$DIFF_EXIT" -eq 0 ]] || [[ "$DIFF_EXIT" -eq 2 ]]; then
    # Exit code 2 = differences found (normal for a new array)
    ADDED=$(echo "$DIFF_OUT" | grep -oP '\d+(?= added)' | head -1 || echo 0)
    REMOVED=$(echo "$DIFF_OUT" | grep -oP '\d+(?= removed)' | head -1 || echo 0)
    _pass "snapraid diff OK (añadidos: ${ADDED:-0}, eliminados: ${REMOVED:-0})"
else
    _fail "snapraid diff falló con código: $DIFF_EXIT"
    echo -e "${DIM}  Salida: $DIFF_OUT${RESET}"
fi

# ── Test 4: Systemd timers activos ────────────────────────────────────────────
if [[ "${SCHEDULE_TYPE:-systemd}" == "systemd" ]]; then
    ACTIVE_TIMERS=0
    for timer in snapraid-sync.timer snapraid-scrub.timer snapraid-smart.timer; do
        if systemctl is-active --quiet "$timer" 2>/dev/null; then
            log_debug "Timer activo: $timer"
            ((ACTIVE_TIMERS++))
        fi
    done

    if [[ "$ACTIVE_TIMERS" -ge 3 ]]; then
        _pass "Todos los timers systemd están activos ($ACTIVE_TIMERS/3)"
    elif [[ "$ACTIVE_TIMERS" -gt 0 ]]; then
        log_warn "$ACTIVE_TIMERS/3 timers activos"
        ((PASS++))
    else
        _fail "Ningún timer SnapRAID está activo"
    fi

    # Show next scheduled times
    echo ""
    log_info "Próximas ejecuciones:"
    systemctl list-timers snapraid-*.timer --no-pager 2>/dev/null | grep -v "^$\|^NEXT\|timers" | while read -r line; do
        echo -e "  ${DIM}$line${RESET}"
    done
fi

# ── Resultado ─────────────────────────────────────────────────────────────────
echo ""
echo -e "  Resultados: ${GREEN}${PASS} pasaron${RESET} | ${RED}${FAIL} fallaron${RESET}"
echo ""
if [[ "$FAIL" -eq 0 ]]; then
    print_recommendation "Ejecuta 'snapraid sync' para inicializar la paridad si es un array nuevo."
fi
[[ "$FAIL" -eq 0 ]]
