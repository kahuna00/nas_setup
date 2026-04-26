#!/usr/bin/env bash
# install.sh — NAS Setup Suite — Punto de entrada principal
# Uso: sudo bash install.sh
#
# Módulos disponibles:
#   1. NFS + Samba         — Configura shares de red desde .env
#   2. MergerFS + SnapRAID — Setup guiado de pool + paridad
#   3. K8s Integration     — Integración con cluster Kubernetes (NFS ↔ local)
#   4. NFS Sync            — Copia periódica NFS remoto → local
#   5. Schedule Config     — Cambia horarios de SnapRAID y NFS Sync
#   6. SMART Report        — Salud, health %, TBW y temperatura de discos
#   7. Tests               — Verificación post-instalación
#
# Requisitos: Debian/Ubuntu, ARM64 o amd64, root

set -euo pipefail

NAS_SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Source librería compartida ──────────────────────────────────────────────────
source "${NAS_SETUP_DIR}/lib/colors.sh"
source "${NAS_SETUP_DIR}/lib/logging.sh"
source "${NAS_SETUP_DIR}/lib/os.sh"
source "${NAS_SETUP_DIR}/lib/env.sh"
source "${NAS_SETUP_DIR}/lib/idempotency.sh"
source "${NAS_SETUP_DIR}/lib/k8s.sh"

# ── Banner ──────────────────────────────────────────────────────────────────────
show_banner() {
    clear
    echo -e "${CYAN}${BOLD}"
    cat << 'BANNER'
  ███╗   ██╗ █████╗ ███████╗    ███████╗███████╗████████╗██╗   ██╗██████╗
  ████╗  ██║██╔══██╗██╔════╝    ██╔════╝██╔════╝╚══██╔══╝██║   ██║██╔══██╗
  ██╔██╗ ██║███████║███████╗    ███████╗█████╗     ██║   ██║   ██║██████╔╝
  ██║╚██╗██║██╔══██║╚════██║    ╚════██║██╔══╝     ██║   ██║   ██║██╔═══╝
  ██║ ╚████║██║  ██║███████║    ███████║███████╗   ██║   ╚██████╔╝██║
  ╚═╝  ╚═══╝╚═╝  ╚═╝╚══════╝    ╚══════╝╚══════╝   ╚═╝    ╚═════╝ ╚═╝
BANNER
    echo -e "${RESET}"
    echo -e "  ${DIM}NFS · Samba · MergerFS · SnapRAID · NFS Sync · Kubernetes Storage${RESET}"
    echo -e "  ${DIM}$(uname -srm) | $(date '+%Y-%m-%d %H:%M')${RESET}"
    echo ""
}

# ── Pre-flight checks ───────────────────────────────────────────────────────────
preflight_check() {
    require_root
    detect_os
    detect_pkg_manager

    # Check for envsubst
    if ! command -v envsubst &>/dev/null; then
        log_info "Instalando gettext-base (envsubst)..."
        $PKG_MGR install -y gettext-base >> "$LOG_FILE" 2>&1 || {
            log_error "No se pudo instalar gettext-base"
            exit 1
        }
    fi

    # Warn if not ARM64 (not blocking, just informational)
    local arch
    arch=$(get_arch)
    if [[ "$arch" != "arm64" ]]; then
        log_warn "Arquitectura detectada: $arch (este setup está optimizado para ARM64/CM3588)"
    fi

    log_info "Sistema: ${OS_ID} ${OS_VERSION} | Arch: ${arch} | Log: ${LOG_FILE}"
}

# ── Menú principal ──────────────────────────────────────────────────────────────
show_menu() {
    echo -e "  ${BOLD}${WHITE}¿Qué deseas configurar?${RESET}"
    echo ""
    echo -e "  ${CYAN}[1]${RESET} ${BOLD}NFS${RESET}"
    echo -e "      Instalar, reconfigurar o desactivar el servidor NFS"
    echo ""
    echo -e "  ${CYAN}[2]${RESET} ${BOLD}Samba${RESET}"
    echo -e "      Instalar, reconfigurar o desactivar Samba/CIFS (Windows/macOS)"
    echo ""
    echo -e "  ${CYAN}[3]${RESET} ${BOLD}MergerFS${RESET}"
    echo -e "      Pool unificado de almacenamiento (selección de discos, formateo, montaje)"
    echo ""
    echo -e "  ${CYAN}[4]${RESET} ${BOLD}SnapRAID${RESET}"
    echo -e "      Paridad de datos + timers de sync/scrub automático"
    echo ""
    echo -e "  ${CYAN}[5]${RESET} ${BOLD}Gestión de discos${RESET}"
    echo -e "      Formatear · Copiar desde NFS remoto · Montar / Desmontar · Symlinks de acceso"
    echo ""
    echo -e "  ${CYAN}[6]${RESET} ${BOLD}Kubernetes Integration${RESET}"
    echo -e "      Integra el NAS con tu cluster k3s (PVs, cluster-vars)"
    echo ""
    echo -e "  ${CYAN}[7]${RESET} ${BOLD}NFS Sync (remoto → local)${RESET}"
    echo -e "      Copia periódica desde un NFS remoto al almacenamiento local (rsync + timer)"
    echo ""
    echo -e "  ${CYAN}[8]${RESET} ${BOLD}Configurar schedules${RESET}"
    echo -e "      Cambia horarios de SnapRAID y NFS Sync sin re-ejecutar el módulo completo"
    echo ""
    echo -e "  ${CYAN}[9]${RESET} ${BOLD}Reporte SMART${RESET}"
    echo -e "      Salud, health %, TBW, temperatura y horas de todos los discos"
    echo ""
    echo -e "  ${CYAN}[10]${RESET} ${BOLD}Ejecutar Tests${RESET}"
    echo -e "      Verifica NFS, Samba y MergerFS post-instalación"
    echo ""
    echo -e "  ${CYAN}[11]${RESET} ${BOLD}Resetear estado${RESET} (permite re-ejecutar módulos ya configurados)"
    echo ""
    echo -e "  ${DIM}[0]${RESET} Salir"
    echo ""
    read -rp "$(echo -e "  ${BOLD}Opción: ${RESET}")" MENU_CHOICE
}

run_tests() {
    print_header "TESTS DE VERIFICACIÓN"
    local test_dir="${NAS_SETUP_DIR}/tests"
    local failed=0

    for test_script in "${test_dir}"/test-*.sh; do
        [[ -f "$test_script" ]] || continue
        local test_name
        test_name=$(basename "$test_script")
        log_info "Ejecutando: $test_name"
        if bash "$test_script"; then
            log_success "$test_name — PASÓ"
        else
            log_error "$test_name — FALLÓ"
            ((failed++))
        fi
        echo ""
    done

    if [[ "$failed" -eq 0 ]]; then
        log_success "Todos los tests pasaron"
    else
        log_error "$failed test(s) fallaron — revisa el log: $LOG_FILE"
    fi
}

reset_state() {
    echo ""
    log_warn "Esto limpiará todos los estados guardados y permitirá re-ejecutar módulos."
    confirm "¿Confirmar reset de estado?" "N" && {
        state_reset_all
        log_success "Estado reseteado. La próxima ejecución re-configurará todo."
    }
}

# ── Main ────────────────────────────────────────────────────────────────────────
main() {
    show_banner
    preflight_check
    load_env

    while true; do
        echo ""
        show_menu

        case "${MENU_CHOICE:-}" in
            1)
                source "${NAS_SETUP_DIR}/modules/01-nfs-samba/setup.sh"
                setup_nfs
                ;;
            2)
                source "${NAS_SETUP_DIR}/modules/01-nfs-samba/setup.sh"
                setup_samba
                ;;
            3)
                source "${NAS_SETUP_DIR}/modules/02-mergerfs-snapraid/setup.sh"
                setup_mergerfs
                ;;
            4)
                source "${NAS_SETUP_DIR}/modules/02-mergerfs-snapraid/setup.sh"
                setup_snapraid
                ;;
            5)
                source "${NAS_SETUP_DIR}/modules/07-disk-manager/setup.sh"
                setup_disk_manager
                ;;
            6)
                source "${NAS_SETUP_DIR}/modules/03-k8s-integration/setup.sh"
                setup_k8s_integration
                ;;
            7)
                source "${NAS_SETUP_DIR}/modules/04-nfs-sync/setup.sh"
                setup_nfs_sync
                ;;
            8)
                source "${NAS_SETUP_DIR}/modules/05-schedule-config/setup.sh"
                setup_schedule_config
                ;;
            9)
                source "${NAS_SETUP_DIR}/modules/06-smart-report/setup.sh"
                setup_smart_report
                ;;
            10)
                run_tests
                ;;
            11)
                reset_state
                ;;
            0|q|Q|exit|quit)
                echo ""
                log_info "Saliendo. Log guardado en: ${LOG_FILE}"
                echo ""
                exit 0
                ;;
            *)
                log_warn "Opción inválida: '${MENU_CHOICE}'"
                ;;
        esac

        echo ""
        read -rp "$(echo -e "  ${DIM}Presiona Enter para continuar...${RESET}")" _
    done
}

main "$@"
