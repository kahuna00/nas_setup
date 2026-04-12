#!/usr/bin/env bash
# install.sh — NAS Setup Suite — Punto de entrada principal
# Uso: sudo bash install.sh
#
# Módulos disponibles:
#   1. NFS + Samba        — Configura shares de red desde .env
#   2. MergerFS + SnapRAID — Setup guiado de pool + paridad
#   3. K8s Integration    — [EN DESARROLLO] Integración con cluster Kubernetes
#   4. NFS Sync           — Copia periódica NFS remoto → local
#   5. Tests              — Verificación post-instalación
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
    echo -e "  ${CYAN}[1]${RESET} ${BOLD}NFS + Samba${RESET}"
    echo -e "      Configura shares de red desde .env"
    echo -e "      (NFS para Linux/Kubernetes · Samba/CIFS para Windows/macOS)"
    echo ""
    echo -e "  ${CYAN}[2]${RESET} ${BOLD}MergerFS + SnapRAID${RESET}"
    echo -e "      Setup guiado: selección de discos, formateo, paridad y schedule"
    echo -e "      (Protege tus datos con paridad + pool unificado de almacenamiento)"
    echo ""
    echo -e "  ${YELLOW}[3]${RESET} ${BOLD}Kubernetes Integration${RESET} ${YELLOW}[EN DESARROLLO]${RESET}"
    echo -e "      Integra el NAS con tu cluster k3s (PVs, cluster-vars, Longhorn)"
    echo ""
    echo -e "  ${CYAN}[4]${RESET} ${BOLD}NFS Sync (remoto → local)${RESET}"
    echo -e "      Copia periódica desde un NFS remoto al almacenamiento local (rsync + timer)"
    echo ""
    echo -e "  ${CYAN}[5]${RESET} ${BOLD}Ejecutar Tests${RESET}"
    echo -e "      Verifica NFS, Samba y MergerFS post-instalación"
    echo ""
    echo -e "  ${CYAN}[6]${RESET} ${BOLD}Resetear estado${RESET} (permite re-ejecutar módulos ya configurados)"
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
                setup_nfs_samba
                ;;
            2)
                source "${NAS_SETUP_DIR}/modules/02-mergerfs-snapraid/setup.sh"
                setup_mergerfs_snapraid
                ;;
            3)
                source "${NAS_SETUP_DIR}/modules/03-k8s-integration/setup.sh"
                setup_k8s_integration
                ;;
            4)
                source "${NAS_SETUP_DIR}/modules/04-nfs-sync/setup.sh"
                setup_nfs_sync
                ;;
            5)
                run_tests
                ;;
            6)
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
