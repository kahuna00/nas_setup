# CLAUDE.md — Contexto para Claude Code

Referencia técnica de este repositorio. Léela antes de modificar cualquier archivo.

---

## Qué es este proyecto

Suite de scripts Bash para configurar el almacenamiento NAS en un servidor CM3588 (ARM64) que corre k3s Kubernetes con Flux GitOps. El repo está en `/home/jgomez/nas-setup`. El cluster k8s está en `/home/jgomez/k8-homelab`.

---

## Infraestructura del servidor

| Campo | Valor |
|-------|-------|
| Hardware | FriendlyElec CM3588 NAS (ARM64/aarch64) |
| OS | Linux 6.1.115-vendor-rk35xx (Debian/Ubuntu) |
| IP del NAS | 192.168.0.14 |
| IP NFS remoto (sync) | 192.168.0.197 |
| Kubernetes | k3s v1.31.4+k3s1 |
| GitOps | Flux CD (reconcilia cada 2 min al hacer push) |
| Dominio | kahunaz.duckdns.org |
| Storage class default | `nfs-csi` (servidor: 192.168.0.14, path: /nfs/kahunaz) |
| Rutas NFS en uso por k8s | `/nfs/kahunaz` (CSI dynamic), `/armhot/Media/downloads`, `/armhot/respaldo-asm`, `/armhot/backups/k8s` |

---

## Menú de install.sh

| Opción | Módulo | Descripción |
|--------|--------|-------------|
| `[1]`  | 01-nfs-samba | NFS server: instalar, reconfigurar o desactivar |
| `[2]`  | 01-nfs-samba | Samba/CIFS: instalar, reconfigurar o desactivar |
| `[3]`  | 02-mergerfs-snapraid | MergerFS: pool unificado de discos |
| `[4]`  | 02-mergerfs-snapraid | SnapRAID: paridad + timers de sync/scrub |
| `[5]`  | 07-disk-manager | Gestión de discos: formatear, copiar desde NFS remoto, montar/desmontar, symlinks |
| `[6]`  | 03-k8s-integration | Integración k8s: cambio modo storage, PVs, cluster-vars |
| `[7]`  | 04-nfs-sync | Copia rsync periódica desde NFS remoto → local (con timer) |
| `[8]`  | 05-schedule-config | Reconfigurar periodicidad y horarios de timers |
| `[9]`  | 06-smart-report | Reporte SMART: health %, TBW, temperatura por disco |
| `[10]` | — | Ejecutar tests de verificación |
| `[11]` | — | Resetear sentinels de idempotencia |

Cada uno de los módulos 1–4 tiene su propio sub-menú con opciones: instalar/configurar, reconfigurar parámetros y desactivar (detiene el servicio y limpia la configuración).

---

## Arquitectura del código

### Carga de dependencias

Todos los módulos se ejecutan sourced (no como subprocesos). El orden de source es obligatorio:

```
lib/colors.sh → lib/logging.sh → lib/os.sh → lib/env.sh → lib/idempotency.sh → lib/k8s.sh
```

`install.sh` hace este source antes de llamar a cualquier módulo. Los módulos individuales NO deben re-sourcear la lib si ya fueron llamados desde `install.sh`.

### Helpers compartidos en lib/env.sh

Además de `load_env` y `validate_env`, `lib/env.sh` expone:

```bash
set_env_var KEY VALUE        # actualiza la línea KEY=... en .env y exporta al proceso actual
prompt_env_value LABEL CURR  # prompt con valor actual visible; Enter mantiene el actual
split_colon_var VAR ARRAY    # split de variable separada por : en array
```

`set_env_var` usa `sed -i "s|^KEY=.*|KEY=VALUE|"`. Si el valor contiene `|` hay que cambiar el delimitador.

### Idempotencia

Los estados se guardan como archivos vacíos en `/var/lib/nas-setup/state/`. La función `skip_if_done "nombre"` devuelve 0 (skip) si el sentinel existe y `FORCE_RERUN != 1`. Siempre wrappear operaciones destructivas o de configuración con este patrón:

```bash
skip_if_done "operacion_nombre" "descripción legible" && return 0
# ... hacer el trabajo ...
state_mark "operacion_nombre"
```

### Templates

Los templates en `templates/` usan sintaxis de `envsubst` (`${VAR}`). Se renderizan con:

```bash
envsubst < templates/archivo.j2 > /destino/archivo
```

Los placeholders `##NOMBRE##` en `snapraid.conf.j2` NO son para envsubst — los reemplaza el script Python en `snapraid.sh:render_snapraid_conf()` porque el número de líneas es dinámico.

**Templates de timers systemd** usan variables precomputadas antes de envsubst:
- `snapraid-sync.timer.j2` → requiere `SNAPRAID_SYNC_ONCALENDAR` y `SNAPRAID_SYNC_SCHEDULE_LABEL`
- `nfs-sync.timer.j2` → requiere `NFS_SYNC_ONCALENDAR` y `NFS_SYNC_SCHEDULE_LABEL`

Estas variables las calcula `export_oncalendar_vars()` (definida en `modules/05-schedule-config/setup.sh` y duplicada como `_export_snapraid_oncalendar()` en módulo 02 y `_export_nfs_sync_oncalendar()` en módulo 04). Siempre llamar antes de renderizar esos templates.

### Sistema de periodicidad de schedules

Las variables `*_PERIOD` controlan la expresión `OnCalendar` de systemd:

| Valor | OnCalendar generado |
|-------|---------------------|
| `daily` | `*-*-* HOUR:00:00` |
| `weekly` | `DAY *-*-* HOUR:00:00` |
| `monthly` | `*-*-01 HOUR:00:00` |
| `disabled` | timer parado y deshabilitado |

Variables: `SNAPRAID_SYNC_PERIOD`, `SNAPRAID_SYNC_DAY`, `NFS_SYNC_PERIOD`, `NFS_SYNC_DAY`.

### Funciones interactivas dentro de subshell `$()`

Cuando una función se captura con `$()` su stdin (fd 0) deja de ser el terminal. Patrón obligatorio:
- Todo display (menús, prompts) → `>&2`
- `read` del usuario → `</dev/tty`
- Solo el valor de retorno → `stdout`

Ejemplo: `_pick_period()` en módulo 05.

### Arrays globales del módulo 2

`discover.sh` popula arrays globales que usan todos los scripts del módulo 2:

```bash
ALL_DISKS=()            # devices: /dev/sda, /dev/sdb, ...
DISK_SIZE["$dev"]       # string: "4.0T"
DISK_SIZE_BYTES["$dev"] # bytes para comparación numérica
DISK_MODEL["$dev"]
DISK_SERIAL["$dev"]
DISK_SMART["$dev"]      # PASSED / FAILED / UNKNOWN
DISK_TYPE["$dev"]       # HDD / SSD / NVMe
```

`assign.sh` popula `DATA_DISKS[]` y `PARITY_DISKS[]`.
`format.sh` popula `DISK_MOUNTPOINT["$dev"]` (dev → /mnt/dataN o /mnt/parityN).

Estos arrays deben estar disponibles cuando se llamen los scripts de pasos posteriores — todos son sourced en `modules/02-mergerfs-snapraid/setup.sh`.

---

## Módulos 1 y 2 — NFS y Samba (separados)

NFS y Samba son ahora opciones independientes del menú (`[1]` y `[2]`). Ambos viven en `01-nfs-samba/` pero se invocan por separado.

### Sub-menú de cada servicio

```
[1] Instalar / configurar
[2] Reconfigurar parámetros
[3] Desactivar (detiene el servicio y limpia la config)
[0] Volver
```

### Variable SAMBA_SHARE_DIR

Samba tiene su propio directorio raíz de share, independiente de `NFS_SHARE_DIR`:

```
SAMBA_SHARE_DIR=/nfs/kahunaz   # puede ser cualquier ruta, no necesariamente la misma que NFS
NFS_SHARE_DIR=/nfs/kahunaz     # ruta exportada vía NFS
```

`smb.conf.j2` usa `${SAMBA_SHARE_DIR}`. Si `SAMBA_SHARE_DIR` no está definido al instalar Samba, `_install_samba()` lo asigna a `NFS_SHARE_DIR` y lo persiste en `.env`.

`reconfig_samba()` en `reconfig.sh` permite cambiar `SAMBA_SHARE_DIR` de forma interactiva sin reinstalar.

### Funciones de desactivación

- `disable_nfs()` en `nfs.sh` — detiene `nfs-server`, elimina `/etc/exports.d/nas-setup.exports`, recarga exportfs, limpia sentinels `nfs_configured` y `nfs_installed`.
- `disable_samba()` en `samba.sh` — detiene `smbd`/`nmbd`, resetea `smb.conf` al mínimo global, limpia sentinels `samba_configured` y `samba_installed`.

### NFS_EXTRA_DIRS y deduplicación

`NFS_EXTRA_DIRS` se usa para añadir shares adicionales tanto a NFS como a Samba (las shares extras de `render_smb_conf` también iteran esta variable). Si `NFS_POOL_LINK` ya está en `NFS_EXTRA_DIRS`, la deduplicación en `render_exports()` evita la entrada duplicada. `fsid=20` se reserva para el pool link (rango 10-19 para extras).

---

## Módulos 3 y 4 — MergerFS y SnapRAID (separados)

MergerFS y SnapRAID son ahora opciones independientes (`[3]` y `[4]`). Ambos viven en `02-mergerfs-snapraid/` pero se invocan con `setup_mergerfs()` y `setup_snapraid()`.

### Helper compartido `_discover_and_assign()`

Definido en `setup.sh`, ejecuta discover + assign + confirmación de roles. Tanto `_install_mergerfs()` como `_install_snapraid()` lo llaman. Si SnapRAID se ejecuta de forma independiente (sin haber pasado por MergerFS en la misma sesión), `DATA_DISKS[]` está vacío y `_install_snapraid()` re-ejecuta el descubrimiento automáticamente — no formatea nada, solo mapea mountpoints existentes con `map_existing_mountpoints()`.

### Funciones de desactivación

- `disable_mergerfs()` en `mergerfs.sh` — desmonta el pool (`MERGERFS_POOL_PATH`), elimina líneas `mergerfs` de `/etc/fstab` (backup previo), limpia sentinels. Los datos en los discos individuales permanecen intactos.
- `disable_snapraid()` en `snapraid.sh` — para y deshabilita los 3 timers + 3 services, elimina los unit files de `/etc/systemd/system/snapraid-*`, elimina `/etc/snapraid.conf`, elimina cron fallback, limpia sentinels.

### Función legacy

`setup_mergerfs_snapraid()` sigue existiendo para ejecutar el flujo combinado completo (pasos 1-7 en una sola pasada).

---

## Módulo 5 — Gestión de discos (07-disk-manager)

Módulo de propósito general para operaciones sobre discos individuales. No depende de MergerFS ni SnapRAID.

```
modules/07-disk-manager/
├── setup.sh       # Punto de entrada + menú
├── disk-ops.sh    # Formateo, montaje, symlinks
└── nfs-copy.sh    # Copia selectiva desde NFS remoto
```

### [1] Formatear disco

Flujo interactivo en `dm_format_disk()`:
1. Muestra tabla de todos los discos con `lsblk -pP` (parseo con `eval`)
2. Selección numerada — incluye el boot disk con advertencia muy visible
3. Desmonta particiones activas si las hay
4. Pide etiqueta (label), punto de montaje y filesystem (ext4 / xfs)
5. Confirmación explícita escribiendo `FORMATEAR`
6. Crea GPT → partición única → `mkfs` → obtiene UUID → añade a `/etc/fstab` → monta
7. Ofrece crear symlink de acceso al terminar

### [2] Copiar desde NFS remoto

Flujo en `dm_copy_from_nfs()`:
1. Pide host/path/mountpoint (default: variables `NFS_SYNC_*` del `.env`)
2. Monta el NFS remoto temporalmente con `mount -t nfs`
3. Muestra carpetas con selección toggle: número para toggle, `a`=todo, `n`=ninguno, `c`=confirmar
4. Calcula tamaño estimado y verifica espacio libre en destino
5. Ejecuta rsync con `--info=progress2 --stats` por carpeta
6. exit 24 de rsync (archivos en tránsito) se trata como advertencia, no error
7. Desmonta el NFS remoto al terminar (éxito o fallo)

### [3] Gestionar montaje y acceso

Sub-menú en `dm_manage_mounts()`:

- **Desmontar** — lista particiones montadas, `umount`
- **Montar** — lista particiones sin montar; busca UUID en fstab para determinar mountpoint, si no está en fstab pregunta dónde y ofrece añadirlo
- **Crear symlink de acceso** — selecciona una partición montada, crea symlink en la ruta elegida (default: `NFS_SHARE_DIR/etiqueta`), y opcionalmente:
  - Añade la ruta a `NFS_EXTRA_DIRS`, actualiza `.env`, re-renderiza exports y recarga nfs-server
  - Re-renderiza `smb.conf` y recarga smbd

### Selección de discos en disk-ops.sh

Las funciones de selección usan `lsblk -pPo NAME,SIZE,TYPE,MOUNTPOINT,LABEL` con `eval` para parsear las líneas en variables. Retornan el resultado vía globales:
- `DM_SELECTED_DEV` — path del dispositivo seleccionado
- `DM_SELECTED_MP` — mountpoint (solo en funciones de partición montada)

---

## Módulo 6 (menú [6]) — K8s Integration

Soporta dos modos de storage controlados por `K8S_STORAGE_MODE` en `.env`:

- `nfs` — PVs con spec `nfs:` (nfs-csi, ReadWriteMany, multi-nodo). Patchea `NFS_SERVER`, `NFS_PATH`, `STORAGE_MODE=nfs` en cluster-vars.yaml.
- `local` — PVs con `hostPath:` + `nodeAffinity` al nodo actual (single-node, sin overhead de red). Patchea `STORAGE_PATH`, `STORAGE_MODE=local`.

Templates: `k8s-nfs-pv.yaml.j2` (modo nfs) y `k8s-hostpath-pv.yaml.j2` (modo local).
El cambio de modo hace `git commit + push` para que Flux reconcilie en ~2 min.

---

## Módulo 7 (menú [7]) — NFS Sync

Copia rsync desde un NFS remoto al almacenamiento local. El script de runtime en `/var/lib/nas-setup/scripts/nfs-sync.sh`:
1. Monta el remoto si no está montado (y lo desmonta al terminar)
2. Ejecuta rsync
3. rsync exit 24 (archivos en tránsito) se trata como éxito
4. Loga con `logger -t nfs-sync` → `journalctl -t nfs-sync`

La entrada en `/etc/fstab` usa `noauto` — el script gestiona el montaje, no systemd.

---

## Módulo 8 (menú [8]) — Schedule Config

Permite reconfigurar periodicidad y horarios sin re-ejecutar los módulos completos. Actualiza `.env` con `set_env_var`, re-renderiza los templates de timer con `envsubst` y recarga los timers activos.

Incluye estimador de desgaste anual para parity SSD: calcula TB escritos/año según periodicidad y GB/sync estimados, con comparativa diario/semanal/mensual.

---

## Módulo 9 (menú [9]) — SMART Report

Usa `smartctl --json -a` + Python3 para parsear datos de todos los discos (incluido boot disk y NVMe). Extrae:
- Health % desde atributos por fabricante (231, 177, 233, 232, 169) o `percentage_used` NVMe
- TBW desde atributo 241 (ATA) o `data_units_written` (NVMe)
- Temperatura, horas, sectores reasignados

El módulo 9 incluye boot disk en el reporte (a diferencia del módulo 02-mergerfs-snapraid que lo excluye).

---

## Patrones importantes

### Logging

Siempre usar las funciones de `lib/logging.sh`, nunca `echo` directo:
- `log_info` — información normal (cyan)
- `log_success` — operación completada (verde)
- `log_warn` — advertencia no bloqueante (amarillo)
- `log_error` — error (rojo, va a stderr)
- `log_cmd "descripción" comando args` — ejecuta y loggea exit code

### Verificación pre/post en NFS

`_install_nfs()` llama `validate_k8s_nfs_mounts()` (de `lib/k8s.sh`) antes y después de cambiar NFS. Si algún PV estaba Bound antes y deja de estarlo, imprime alerta roja con remediation steps. No bloquea la ejecución pero sí advierte.

### Safety gate de SnapRAID

`/var/lib/nas-setup/scripts/snapraid-sync-safe.sh` corre `snapraid diff` y aborta si el porcentaje de archivos eliminados supera `SNAPRAID_DIFF_THRESHOLD`. El timer systemd llama a este script, no a `snapraid sync` directamente.

### Descarga de binarios ARM64

MergerFS: usa la GitHub releases API para detectar la última versión y descarga el `.deb` correcto para la distribución detectada. Caché en `/var/cache/nas-setup/`.

SnapRAID: intenta apt primero; si no está disponible, descarga el tarball y compila desde fuente.

---

## Archivos clave del sistema modificados

| Archivo | Módulo (directorio) | Qué hace el script |
|---------|---------------------|--------------------|
| `/etc/exports.d/nas-setup.exports` | 01-nfs-samba | Sobreescribe (backup .bak.TIMESTAMP antes) |
| `/etc/samba/smb.conf` | 01-nfs-samba | Sobreescribe (backup .bak.TIMESTAMP, valida con testparm) |
| `/etc/fstab` | 02-mergerfs-snapraid, 04-nfs-sync, 07-disk-manager | Solo append — nunca elimina (excepto disable_mergerfs que borra líneas mergerfs) |
| `/etc/snapraid.conf` | 02-mergerfs-snapraid | Sobreescribe (backup .bak.TIMESTAMP antes) |
| `/etc/systemd/system/snapraid-*.{service,timer}` | 02-mergerfs-snapraid, 05-schedule-config | 6 unidades — requieren `SNAPRAID_SYNC_ONCALENDAR` exportada |
| `/etc/systemd/system/nfs-sync.{service,timer}` | 04-nfs-sync, 05-schedule-config | 2 unidades — requieren `NFS_SYNC_ONCALENDAR` exportada |
| `/var/lib/nas-setup/scripts/snapraid-sync-safe.sh` | 02-mergerfs-snapraid, 05-schedule-config | Script de sync con safety gate (THRESHOLD actualizable con sed) |
| `/var/lib/nas-setup/scripts/nfs-sync.sh` | 04-nfs-sync | Script de sync NFS remoto → local |

---

## Relación con k8-homelab

El repo hermano es `/home/jgomez/k8-homelab`. Puntos de contacto:

- `lib/k8s.sh:check_nfs_mounts()` — consulta PVs vía kubectl
- `modules/03-k8s-integration/update-cluster-vars.sh` — patch de `clusters/kahunaz/cluster-vars.yaml` con `yq`
- `modules/03-k8s-integration/generate-pvs.sh` — genera manifests según `K8S_STORAGE_MODE`
- Los manifests generados preservan la sintaxis `${NFS_SERVER}` de Flux (no la expanden con envsubst)

La variable `K8S_HOMELAB_PATH` en `.env` apunta a ese repo.

---

## Convenciones de código

- Bash con `set -euo pipefail` en todos los scripts ejecutables (no en los sourced)
- Los scripts sourced (`lib/*.sh`, `modules/*/setup.sh`) NO tienen `set -euo pipefail` para no interferir con el contexto del caller
- Funciones públicas: `snake_case`
- Funciones internas del módulo: prefijo `_snake_case`
- Variables globales de arrays compartidos: `declare -ga` o `declare -gA`
- Variables de retorno en funciones de selección: globales `DM_SELECTED_DEV`, `DM_SELECTED_MP`
- Templates: extensión `.j2` (Jinja-like pero procesados con envsubst o Python)
- Backups: sufijo `.bak.$(date +%s)` (epoch timestamp, único)

---

## Comandos de diagnóstico útiles

```bash
# Estado del array SnapRAID
snapraid status
snapraid diff

# Exports NFS activos
exportfs -v
showmount -e localhost

# Shares Samba
smbclient -L localhost -U nasuser

# Pool MergerFS
df -h /mergerfs/pool
mount | grep mergerfs

# Timers systemd
systemctl list-timers snapraid-*.timer nfs-sync.timer

# SMART rápido de todos los discos
for d in $(lsblk -dpno NAME); do echo "=== $d ==="; smartctl -H $d; done

# Estado de PVs Kubernetes
kubectl get pv -A -o wide

# Logs de NFS Sync
journalctl -t nfs-sync -f

# Logs de sesión de nas-setup
ls -t /home/jgomez/nas-setup/logs/ | head -5

# Discos y particiones con estado de montaje
lsblk -po NAME,SIZE,TYPE,LABEL,MOUNTPOINT

# Verificar symlinks de acceso bajo NFS_SHARE_DIR
ls -la /nfs/kahunaz/
```

---

## Pitfalls conocidos

1. **Boot disk detection**: `_get_boot_disk()` en `discover.sh` y `disk-ops.sh` puede fallar en configuraciones con LVM o RAID software como boot. Verificar manualmente si el script excluye discos incorrectos. El módulo SMART sí incluye el boot disk.

2. **NVMe naming**: las particiones NVMe son `nvme0n1p1` (no `nvme0n11`). `format.sh` y `disk-ops.sh` manejan esto con `_dm_part_dev()` / condicional `[[ "$dev" =~ nvme ]]`.

3. **MergerFS .deb naming**: el formato del nombre del archivo cambia entre releases. Si la descarga falla, revisar `https://github.com/trapexit/mergerfs/releases` y ajustar la lógica en `mergerfs.sh:install_mergerfs()`.

4. **envsubst y variables Flux**: los manifests K8s generados en módulo 3 deben preservar `${NFS_SERVER}` literal para que Flux los sustituya. No pasar esas variables al entorno antes de llamar envsubst en ese contexto específico.

5. **FORCE_RERUN=1**: limpia todos los sentinels de idempotencia. Si se interrumpe a mitad de una operación, la próxima ejecución con `FORCE_RERUN=1` puede intentar re-formatear discos ya formateados. Confirmar con el usuario antes.

6. **set_env_var y caracteres especiales**: el delimitador `|` en el `sed` de `set_env_var` se rompe si el valor contiene `|`. Cambiar el delimitador en ese caso.

7. **Funciones capturadas con `$()`**: cualquier función que mezcle display y retorno de valor debe redirigir el display a `>&2` y usar `</dev/tty` en el `read`. Ver `_pick_period()` como ejemplo. Las funciones de selección del módulo 07 (`_dm_pick_disk`, etc.) ya usan `</dev/tty`.

8. **SnapRAID con SSDs**: el sync diario escribe en paridad proporcional a los cambios. Con mucha actividad puede agotar el TBW del SSD de paridad en pocos años. Usar periodicidad semanal o mensual, o cambiar a ZFS RAIDZ1 si todos los discos son SSD.

9. **SAMBA_SHARE_DIR no definido**: si `.env` no tiene `SAMBA_SHARE_DIR` (instalaciones previas a la separación de módulos), `_install_samba()` lo hereda de `NFS_SHARE_DIR` y lo persiste. Para apuntar Samba a otro directorio usar la opción `[2] Reconfigurar` dentro del módulo Samba.

10. **NFS/Samba y disable_mergerfs()**: `disable_mergerfs()` desmonta el pool y elimina entradas fstab, pero no actualiza NFS exports ni smb.conf. Si el pool estaba exportado vía `NFS_EXTRA_DIRS` o `NFS_POOL_LINK`, los exports seguirán apuntando a un directorio no montado. Re-ejecutar el módulo NFS después de desactivar MergerFS.

11. **lsblk eval en disk-ops.sh**: las funciones `_dm_pick_*` usan `eval "$line"` sobre el output de `lsblk -pP`. Esto es seguro porque el output es información del kernel, pero si algún label de disco contiene caracteres especiales de shell el eval puede fallar. Evitar labels con `$`, `` ` ``, `\` o `"`.
