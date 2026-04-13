#!/usr/bin/env bash
# modules/06-smart-report/setup.sh — Módulo 6: Reporte SMART de salud de discos
# Muestra health %, TBW, temperatura, horas y sectores reasignados por disco.
# Incluye todos los discos (también el de boot y NVMe).
# Uso: sourced desde install.sh, llamar setup_smart_report()

NAS_SETUP_DIR="$(dirname "$(dirname "$(dirname "${BASH_SOURCE[0]}")")")"

# ── Parser SMART (Python3) ─────────────────────────────────────────────────────
# Lee JSON de smartctl y extrae los campos relevantes.
# Salida: HEALTH|HEALTH_PCT|TEMP|HOURS|TBW_TB|REALLOC|TYPE|MODEL
# HEALTH_PCT = -- si no hay dato de vida para ese tipo de disco (HDD)

_parse_smart_json='
import json, sys

try:
    data = json.load(sys.stdin)
except Exception:
    print("UNKNOWN|--|--|--|--|--|UNKNOWN|Unknown")
    sys.exit(0)

# ── Valores base ──────────────────────────────────────────────────────────────
health  = "PASSED" if data.get("smart_status", {}).get("passed", False) else "FAILED"
model   = data.get("model_name", data.get("model_family", "Unknown")).strip()[:26]
temp    = data.get("temperature", {}).get("current", "--")
hours   = data.get("power_on_time", {}).get("hours", "--")

# Detectar tipo de disco
device_type = data.get("device", {}).get("type", "")
rotation    = data.get("rotation_rate", 0)

if device_type == "nvme":
    disk_type = "NVMe"
elif rotation == 0:
    disk_type = "SSD"
else:
    disk_type = "HDD"

# ── Health % ──────────────────────────────────────────────────────────────────
health_pct = "--"

if disk_type == "NVMe":
    nvme = data.get("nvme_smart_health_information_log", {})
    pct_used = nvme.get("percentage_used")
    if pct_used is not None:
        health_pct = str(100 - int(pct_used)) + "%"

elif disk_type == "SSD":
    # Atributos que contienen vida restante (valor normalizado 0-100)
    # Los IDs más comunes ordenados por fiabilidad
    LIFE_ATTRS = {
        231: "SSD_Life_Left",          # Samsung, Kingston, genérico
        177: "Wear_Leveling_Count",    # Samsung (inverso: 100=nuevo)
        233: "Media_Wearout_Indicator",# Intel
        232: "Available_Reservd_Space",# Intel/WD
        173: "Erase_Fail_Count",       # Crucial/Micron (valor = % restante)
        202: "Percent_Lifetime_Remain",# Crucial
        169: "Remaining_Life_Percent", # Toshiba/Kioxia
    }
    attrs = {a["id"]: a for a in
             data.get("ata_smart_attributes", {}).get("table", [])}
    for attr_id in LIFE_ATTRS:
        if attr_id in attrs:
            val = attrs[attr_id].get("value")
            if val is not None and 0 <= int(val) <= 100:
                health_pct = str(int(val)) + "%"
                break

# ── TBW (Total Bytes Written) ─────────────────────────────────────────────────
tbw = "--"

if disk_type == "NVMe":
    nvme = data.get("nvme_smart_health_information_log", {})
    units_written = nvme.get("data_units_written")
    if units_written is not None:
        # Cada unidad = 1000 × 512 bytes = 512 000 bytes
        tb = units_written * 512000 / 1e12
        tbw = f"{tb:.1f}TB" if tb >= 1 else f"{tb*1000:.0f}GB"

else:
    attrs = {a["id"]: a for a in
             data.get("ata_smart_attributes", {}).get("table", [])}
    lba_written = attrs.get(241, {}).get("raw", {}).get("value")
    if lba_written is not None:
        tb = int(lba_written) * 512 / 1e12
        tbw = f"{tb:.1f}TB" if tb >= 1 else f"{tb*1000:.0f}GB"

# ── Sectores reasignados ───────────────────────────────────────────────────────
realloc = "--"
attrs = {a["id"]: a for a in
         data.get("ata_smart_attributes", {}).get("table", [])}
rsc = attrs.get(5, {}).get("raw", {}).get("value")
if rsc is not None:
    realloc = str(int(rsc))

# NVMe: media errors como indicador equivalente
if disk_type == "NVMe":
    nvme = data.get("nvme_smart_health_information_log", {})
    media_err = nvme.get("media_errors")
    if media_err is not None:
        realloc = str(int(media_err))

# ── Formatear horas ───────────────────────────────────────────────────────────
if hours != "--":
    h = int(hours)
    if h >= 8760:
        hours_str = f"{h//8760}a {(h%8760)//720}m"
    elif h >= 720:
        hours_str = f"{h//720}m {(h%720)//24}d"
    else:
        hours_str = f"{h}h"
else:
    hours_str = "--"

temp_str = f"{temp}°C" if temp != "--" else "--"

print(f"{health}|{health_pct}|{temp_str}|{hours_str}|{tbw}|{realloc}|{disk_type}|{model}")
'

# ── Recopilar datos SMART de un disco ─────────────────────────────────────────

_smart_data_for() {
    local dev="$1"
    local json
    json=$(smartctl --json -a "$dev" 2>/dev/null)

    if [[ -z "$json" ]]; then
        # Fallback sin JSON: solo health básico
        local h
        h=$(smartctl -H "$dev" 2>/dev/null | grep -oE "PASSED|FAILED" | head -1)
        echo "${h:-UNKNOWN}|--|--|--|--|--|UNKNOWN|Unknown"
        return
    fi

    python3 -c "$_parse_smart_json" <<< "$json"
}

# ── Tabla principal ────────────────────────────────────────────────────────────

_print_smart_table() {
    local devs=("$@")

    echo ""
    printf "  ${BOLD}%-12s %-26s %-6s %-8s %-6s %-10s %-8s %-8s %-8s${RESET}\n" \
        "DISPOSITIVO" "MODELO" "TIPO" "SALUD" "HLTH%" "HORAS" "TEMP" "TBW" "REASIGN"
    printf "  %-12s %-26s %-6s %-8s %-6s %-10s %-8s %-8s %-8s\n" \
        "────────────" "──────────────────────────" "──────" "────────" "──────" "──────────" "────────" "────────" "────────"

    local any_failed=0
    local any_warn=0

    for dev in "${devs[@]}"; do
        local raw
        raw=$(_smart_data_for "$dev")

        IFS='|' read -r health health_pct temp hours tbw realloc disk_type model <<< "$raw"

        # Color de salud
        local hcolor="$GREEN"
        [[ "$health" == "FAILED" ]]  && { hcolor="$RED";    any_failed=1; }
        [[ "$health" == "UNKNOWN" ]] && { hcolor="$YELLOW"; any_warn=1;   }

        # Color de health %
        local pcolor="$GREEN"
        if [[ "$health_pct" != "--" ]]; then
            local pnum="${health_pct//%/}"
            (( pnum < 20 )) && { pcolor="$RED";    any_failed=1; }
            (( pnum < 50 )) && (( pnum >= 20 )) && { pcolor="$YELLOW"; any_warn=1; }
        fi

        # Color de sectores reasignados
        local rcolor="$GREEN"
        if [[ "$realloc" != "--" && "$realloc" != "0" ]]; then
            rcolor="$RED"
            any_failed=1
        fi

        # Color de tipo
        local tcolor="$CYAN"
        [[ "$disk_type" == "SSD" || "$disk_type" == "NVMe" ]] && tcolor="$MAGENTA"

        printf "  %-12s ${tcolor}%-26s %-6s${RESET} ${hcolor}%-8s${RESET} ${pcolor}%-6s${RESET} %-10s %-8s %-8s ${rcolor}%-8s${RESET}\n" \
            "$dev" "${model:0:26}" "$disk_type" "$health" "$health_pct" \
            "$hours" "$temp" "$tbw" "$realloc"
    done

    echo ""

    if [[ "$any_failed" -eq 1 ]]; then
        echo -e "  ${RED}${BOLD}  ✖  Uno o más discos requieren atención inmediata${RESET}"
    elif [[ "$any_warn" -eq 1 ]]; then
        echo -e "  ${YELLOW}  ⚠  Revisa los discos marcados en amarillo${RESET}"
    else
        echo -e "  ${GREEN}${BOLD}  ✔  Todos los discos en buen estado${RESET}"
    fi
    echo ""
}

# ── Vista detallada de un disco ────────────────────────────────────────────────

_smart_detail() {
    local dev="$1"

    echo ""
    echo -e "  ${BOLD}Detalle SMART: ${CYAN}${dev}${RESET}"
    echo ""

    # Información del dispositivo
    smartctl -i "$dev" 2>/dev/null | grep -E "Model|Serial|Firmware|Capacity|RPM|Form Factor" \
        | while read -r line; do echo -e "  ${DIM}${line}${RESET}"; done

    echo ""

    # Test de salud
    local health
    health=$(smartctl -H "$dev" 2>/dev/null | grep "overall-health")
    echo -e "  ${health}"
    echo ""

    # Atributos relevantes
    echo -e "  ${BOLD}Atributos SMART relevantes:${RESET}"
    smartctl -A "$dev" 2>/dev/null \
        | grep -E "^[[:space:]]*(5|9|12|177|190|194|197|198|231|232|233|241|242)[[:space:]]" \
        | while read -r line; do echo -e "  ${DIM}${line}${RESET}"; done

    echo ""

    # Para NVMe, mostrar el health log directamente
    if smartctl -i "$dev" 2>/dev/null | grep -q "NVMe"; then
        echo -e "  ${BOLD}NVMe Health Log:${RESET}"
        smartctl -A "$dev" 2>/dev/null | while read -r line; do
            echo -e "  ${DIM}${line}${RESET}"
        done
        echo ""
    fi

    # Último test SMART
    local last_test
    last_test=$(smartctl -l selftest "$dev" 2>/dev/null | grep -m1 "Completed\|Aborted\|Failed")
    if [[ -n "$last_test" ]]; then
        echo -e "  ${BOLD}Último self-test:${RESET} ${DIM}${last_test}${RESET}"
        echo ""
    fi
}

# ── Punto de entrada ───────────────────────────────────────────────────────────

setup_smart_report() {
    print_header "MÓDULO 6: REPORTE SMART"

    # Asegurar smartmontools instalado
    if ! command -v smartctl &>/dev/null; then
        log_info "Instalando smartmontools..."
        apt_update_once
        pkg_install smartmontools || {
            log_error "No se pudo instalar smartmontools"
            return 1
        }
    fi

    # Detectar todos los discos de bloque (incluye boot disk y NVMe)
    local devs=()
    while IFS= read -r dev; do
        [[ -z "$dev" ]] && continue
        local type
        type=$(lsblk -dnpo TYPE "$dev" 2>/dev/null)
        [[ "$type" == "disk" ]] || continue
        devs+=("$dev")
    done < <(lsblk -dpno NAME)

    if [[ ${#devs[@]} -eq 0 ]]; then
        log_error "No se encontraron discos de bloque"
        return 1
    fi

    log_info "Consultando SMART de ${#devs[@]} disco(s)... (puede tardar unos segundos)"
    _print_smart_table "${devs[@]}"

    echo -e "  ${BOLD}¿Qué deseas hacer?${RESET}"
    echo ""
    echo -e "  ${CYAN}[1-${#devs[@]}]${RESET} Ver detalle completo de un disco"
    echo -e "  ${CYAN}[r]${RESET}       Ejecutar self-test corto en todos los discos ${DIM}(~2 min)${RESET}"
    echo -e "  ${CYAN}[0]${RESET}       Volver"
    echo ""

    # Mostrar índice numerado
    local idx=1
    for dev in "${devs[@]}"; do
        echo -e "  ${DIM}[$idx] ${dev}${RESET}"
        ((idx++))
    done
    echo ""

    local choice
    read -rp "$(echo -e "  ${BOLD}Opción: ${RESET}")" choice

    case "$choice" in
        0) return 0 ;;
        r|R)
            echo ""
            log_info "Iniciando self-test corto en todos los discos..."
            for dev in "${devs[@]}"; do
                log_cmd "smartctl -t short $dev" smartctl -t short "$dev" || true
            done
            log_success "Tests iniciados. Resultados disponibles en ~2 minutos."
            log_info "Para ver resultados: sudo smartctl -l selftest /dev/sdX"
            ;;
        *)
            if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#devs[@]} )); then
                _smart_detail "${devs[$((choice - 1))]}"
            else
                log_warn "Opción inválida"
            fi
            ;;
    esac
}
