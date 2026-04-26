#!/usr/bin/env bash
# modules/07-disk-manager/nfs-copy.sh — Copia selectiva de carpetas desde NFS remoto
# Depends on: lib/{colors,logging,env,os}.sh

# Global: carpetas seleccionadas por _dm_select_folders()
declare -ga SELECTED_FOLDERS=()

_dm_mount_remote() {
    local host="$1" remote_path="$2" local_mp="$3" opts="$4"

    if mountpoint -q "$local_mp" 2>/dev/null; then
        log_info "NFS remoto ya montado en: ${local_mp}"
        return 0
    fi

    log_info "Verificando nfs-common..."
    if ! dpkg -s nfs-common &>/dev/null 2>&1; then
        apt_update_once
        pkg_install nfs-common || return 1
    fi

    mkdir -p "$local_mp"
    log_info "Montando ${host}:${remote_path} → ${local_mp}..."
    mount -t nfs -o "${opts}" "${host}:${remote_path}" "$local_mp" || {
        log_error "No se pudo montar el NFS remoto."
        log_info "Verifica: ping ${host}  |  showmount -e ${host}"
        return 1
    }
    log_success "NFS remoto montado: ${local_mp}"
}

_dm_unmount_remote() {
    local local_mp="$1"
    mountpoint -q "$local_mp" 2>/dev/null && {
        umount "$local_mp" 2>/dev/null && \
            log_info "NFS remoto desmontado: ${local_mp}" || \
            log_warn "No se pudo desmontar ${local_mp} — puede haber procesos activos"
    }
}

# Selección multi-carpeta con toggle interactivo
# Resultado en el array global SELECTED_FOLDERS
_dm_select_folders() {
    local base_path="$1"
    local -a folders=()
    local -a sel=()

    while IFS= read -r d; do
        folders+=("$d")
        sel+=(0)
    done < <(find "$base_path" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null | sort)

    if [[ ${#folders[@]} -eq 0 ]]; then
        log_warn "No se encontraron carpetas en: ${base_path}"
        return 1
    fi

    SELECTED_FOLDERS=()

    while true; do
        echo ""
        echo -e "  ${BOLD}Carpetas disponibles en el NFS remoto:${RESET}"
        echo ""
        for i in "${!folders[@]}"; do
            if [[ "${sel[$i]}" -eq 1 ]]; then
                printf "  ${GREEN}[✓]${RESET} ${BOLD}[%2d]${RESET} %s\n" "$((i+1))" "${folders[$i]}"
            else
                printf "  ${DIM}[ ]${RESET} ${BOLD}[%2d]${RESET} %s\n" "$((i+1))" "${folders[$i]}"
            fi
        done
        echo ""
        echo -e "  ${DIM}Número(s) para toggle · 'a' todo · 'n' ninguno · 'c' confirmar · 'q' cancelar${RESET}"

        local input
        read -rp "$(echo -e "  ${BOLD}> ${RESET}")" input </dev/tty

        case "$input" in
            a|A) for i in "${!sel[@]}"; do sel[$i]=1; done ;;
            n|N) for i in "${!sel[@]}"; do sel[$i]=0; done ;;
            c|C|"") break ;;
            q|Q) return 1 ;;
            *)
                for num in $input; do
                    if [[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num-1 < ${#folders[@]} )); then
                        local idx=$((num-1))
                        sel[$idx]=$(( 1 - sel[$idx] ))
                    fi
                done
                ;;
        esac
    done

    for i in "${!folders[@]}"; do
        [[ "${sel[$i]}" -eq 1 ]] && SELECTED_FOLDERS+=("${folders[$i]}")
    done

    if [[ ${#SELECTED_FOLDERS[@]} -eq 0 ]]; then
        log_warn "No seleccionaste ninguna carpeta"
        return 1
    fi
    return 0
}

dm_copy_from_nfs() {
    print_header "COPIAR DESDE NFS REMOTO"

    echo ""
    echo -e "  ${BOLD}Configuración del origen (NFS remoto):${RESET}"
    echo ""

    local host remote_path local_mp opts
    host=$(prompt_env_value "Host / IP del servidor NFS remoto" "${NFS_SYNC_REMOTE_HOST:-192.168.0.197}")
    remote_path=$(prompt_env_value "Path exportado en el servidor remoto" "${NFS_SYNC_REMOTE_PATH:-/nfs}")
    local_mp=$(prompt_env_value "Punto de montaje temporal" "${NFS_SYNC_MOUNT_POINT:-/mnt/nfs-remote-copy}")
    opts="${NFS_SYNC_MOUNT_OPTIONS:-ro,hard,timeo=30,retrans=3,nfsvers=4}"

    # Montar NFS remoto
    _dm_mount_remote "$host" "$remote_path" "$local_mp" "$opts" || return 1

    # Selección de carpetas
    _dm_select_folders "$local_mp" || {
        _dm_unmount_remote "$local_mp"
        return 0
    }

    # Calcular tamaño estimado de selección
    echo ""
    log_info "Calculando tamaño de las carpetas seleccionadas..."
    local total_bytes=0
    for f in "${SELECTED_FOLDERS[@]}"; do
        local b
        b=$(du -sb "${local_mp}/${f}" 2>/dev/null | cut -f1 || echo 0)
        total_bytes=$((total_bytes + b))
    done
    local total_human
    total_human=$(numfmt --to=iec-i --suffix=B "$total_bytes" 2>/dev/null || \
                  echo "$((total_bytes / 1024 / 1024 / 1024)) GiB")

    # Destino
    echo ""
    echo -e "  ${BOLD}Carpetas seleccionadas:${RESET} ${DIM}(tamaño total estimado: ${total_human})${RESET}"
    for f in "${SELECTED_FOLDERS[@]}"; do
        local sz
        sz=$(du -sh "${local_mp}/${f}" 2>/dev/null | cut -f1 || echo "?")
        printf "  ${GREEN}✓${RESET} %-35s ${DIM}%s${RESET}\n" "$f" "$sz"
    done
    echo ""

    local dest
    dest=$(prompt_env_value "Directorio destino local" "${MERGERFS_POOL_PATH:-/mnt/data1}")

    if [[ ! -d "$dest" ]]; then
        confirm "El directorio destino no existe — ¿crearlo?" "Y" || {
            _dm_unmount_remote "$local_mp"
            return 1
        }
        mkdir -p "$dest"
    fi

    # Verificar espacio disponible
    local free_bytes
    free_bytes=$(df -B1 --output=avail "$dest" 2>/dev/null | tail -1 | tr -d ' ' || echo 0)
    if (( total_bytes > 0 && free_bytes > 0 && total_bytes > free_bytes )); then
        local free_human
        free_human=$(numfmt --to=iec-i --suffix=B "$free_bytes" 2>/dev/null || echo "?")
        log_warn "Espacio insuficiente en destino: necesitas ${total_human}, disponible ${free_human}"
        confirm "¿Continuar de todas formas?" "N" || {
            _dm_unmount_remote "$local_mp"
            return 1
        }
    fi

    # Opciones rsync
    local -a rsync_cmd=(rsync --archive --hard-links --numeric-ids --info=progress2 --stats)
    [[ -n "${NFS_SYNC_RSYNC_OPTS:-}" ]] && {
        read -ra extra_opts <<< "${NFS_SYNC_RSYNC_OPTS//--archive --hard-links --numeric-ids/}"
        rsync_cmd+=("${extra_opts[@]}")
    }
    [[ "${NFS_SYNC_BW_LIMIT:-0}" -gt 0 ]] && rsync_cmd+=(--bwlimit="${NFS_SYNC_BW_LIMIT}")

    # Resumen final
    echo ""
    echo -e "  ${BOLD}Resumen de la operación:${RESET}"
    echo -e "  Origen   : ${CYAN}${host}:${remote_path}${RESET}"
    echo -e "  Destino  : ${CYAN}${dest}${RESET}"
    echo -e "  Tamaño   : ${BOLD}${total_human}${RESET}"
    echo ""
    confirm "¿Iniciar la copia?" "Y" || {
        _dm_unmount_remote "$local_mp"
        return 0
    }

    # Ejecutar rsync por carpeta
    local failed=0
    for folder in "${SELECTED_FOLDERS[@]}"; do
        echo ""
        log_info "Copiando: ${folder} → ${dest}/${folder}"
        mkdir -p "${dest}/${folder}"
        "${rsync_cmd[@]}" "${local_mp}/${folder}/" "${dest}/${folder}/"
        local exit_code=$?
        if [[ $exit_code -eq 0 ]]; then
            log_success "Completado: ${folder}"
        elif [[ $exit_code -eq 24 ]]; then
            log_warn "${folder}: algunos archivos cambiaron durante la copia (normal si el origen está en uso)"
        else
            log_error "Falló la copia de: ${folder} (exit ${exit_code})"
            failed=1
        fi
    done

    _dm_unmount_remote "$local_mp"

    echo ""
    if [[ "$failed" -eq 0 ]]; then
        log_success "Copia completada en: ${dest}"
        df -h "$dest" | tail -1 | sed 's/^/  /'
    else
        log_error "La copia completó con errores — revisa el log: ${LOG_FILE}"
        return 1
    fi
}
