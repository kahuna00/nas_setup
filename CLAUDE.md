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
| `[1]` | 01-nfs-samba | Setup completo o reconfiguración rápida de NFS + Samba |
| `[2]` | 02-mergerfs-snapraid | Setup guiado de pool MergerFS + paridad SnapRAID |
| `[3]` | 03-k8s-integration | Integración k8s: cambio modo storage, PVs, cluster-vars |
| `[4]` | 04-nfs-sync | Copia rsync desde NFS remoto → local (con timer) |
| `[5]` | 05-schedule-config | Reconfigurar periodicidad y horarios de timers |
| `[6]` | 06-smart-report | Reporte SMART: health %, TBW, temperatura por disco |
| `[7]` | — | Ejecutar tests de verificación |
| `[8]` | — | Resetear sentinels de idempotencia |

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

## Módulo 1 — NFS + Samba

Al entrar a la opción [1] se presenta un submenú:
- `[1]` Configuración completa (`_setup_nfs_samba_full`) — flujo original con confirmación
- `[2]` Reconfigurar parámetros (`reconfig_nfs_samba` en `reconfig.sh`) — edición interactiva de variables sin reinstalar

`reconfig.sh` usa `set_env_var` para actualizar `.env`, luego limpia el sentinel con `state_clear` y llama a `render_exports` / `render_smb_conf` + reload de servicios. No toca lo que no cambia.

**Bug corregido**: `NFS_POOL_LINK` ahora se exporta vía NFS además de crear el symlink. Si `NFS_POOL_LINK` ya está en `NFS_EXTRA_DIRS`, la deduplicación evita entrada duplicada en exports. El `fsid=20` se reserva para el pool link (el rango 10-19 es para extras).

---

## Módulo 3 — Activo

Soporta dos modos de storage controlados por `K8S_STORAGE_MODE` en `.env`:

- `nfs` — PVs con spec `nfs:` (nfs-csi, ReadWriteMany, multi-nodo). Patchea `NFS_SERVER`, `NFS_PATH`, `STORAGE_MODE=nfs` en cluster-vars.yaml.
- `local` — PVs con `hostPath:` + `nodeAffinity` al nodo actual (single-node, sin overhead de red). Patchea `STORAGE_PATH`, `STORAGE_MODE=local`.

Templates: `k8s-nfs-pv.yaml.j2` (modo nfs) y `k8s-hostpath-pv.yaml.j2` (modo local).
El cambio de modo hace `git commit + push` para que Flux reconcilie en ~2 min.

---

## Módulo 4 — NFS Sync

Copia rsync desde un NFS remoto al almacenamiento local. El script de runtime en `/var/lib/nas-setup/scripts/nfs-sync.sh`:
1. Monta el remoto si no está montado (y lo desmonta al terminar)
2. Ejecuta rsync
3. rsync exit 24 (archivos en tránsito) se trata como éxito
4. Loga con `logger -t nfs-sync` → `journalctl -t nfs-sync`

La entrada en `/etc/fstab` usa `noauto` — el script gestiona el montaje, no systemd.

---

## Módulo 5 — Schedule Config

Permite reconfigurar periodicidad y horarios sin re-ejecutar los módulos completos. Actualiza `.env` con `set_env_var`, re-renderiza los templates de timer con `envsubst` y recarga los timers activos.

Incluye estimador de desgaste anual para parity SSD: calcula TB escritos/año según periodicidad y GB/sync estimados, con comparativa diario/semanal/mensual.

---

## Módulo 6 — SMART Report

Usa `smartctl --json -a` + Python3 para parsear datos de todos los discos (incluido boot disk y NVMe). Extrae:
- Health % desde atributos por fabricante (231, 177, 233, 232, 169) o `percentage_used` NVMe
- TBW desde atributo 241 (ATA) o `data_units_written` (NVMe)
- Temperatura, horas, sectores reasignados

El módulo 6 incluye boot disk en el reporte (a diferencia del módulo 2 que lo excluye).

---

## Patrones importantes

### Logging

Siempre usar las funciones de `lib/logging.sh`, nunca `echo` directo:
- `log_info` — información normal (cyan)
- `log_success` — operación completada (verde)
- `log_warn` — advertencia no bloqueante (amarillo)
- `log_error` — error (rojo, va a stderr)
- `log_cmd "descripción" comando args` — ejecuta y loggea exit code

### Verificación pre/post en módulo 1

El módulo 1 llama `check_nfs_mounts()` (de `lib/k8s.sh`) antes y después de cambiar NFS. Si algún PV estaba Bound antes y deja de estarlo, imprime alerta roja con remediation steps. No bloquea la ejecución pero sí advierte.

### Safety gate de SnapRAID

`/var/lib/nas-setup/scripts/snapraid-sync-safe.sh` corre `snapraid diff` y aborta si el porcentaje de archivos eliminados supera `SNAPRAID_DIFF_THRESHOLD`. El timer systemd llama a este script, no a `snapraid sync` directamente.

### Descarga de binarios ARM64

MergerFS: usa la GitHub releases API para detectar la última versión y descarga el `.deb` correcto para la distribución detectada. Caché en `/var/cache/nas-setup/`.

SnapRAID: intenta apt primero; si no está disponible, descarga el tarball y compila desde fuente.

---

## Archivos clave del sistema modificados

| Archivo | Módulo | Qué hace el script |
|---------|--------|--------------------|
| `/etc/exports.d/nas-setup.exports` | 1 | Sobreescribe (backup .bak.TIMESTAMP antes) |
| `/etc/samba/smb.conf` | 1 | Sobreescribe (backup .bak.TIMESTAMP, valida con testparm) |
| `/etc/fstab` | 2, 4 | Solo append — nunca elimina líneas existentes |
| `/etc/snapraid.conf` | 2 | Sobreescribe (backup .bak.TIMESTAMP antes) |
| `/etc/systemd/system/snapraid-*.{service,timer}` | 2, 5 | 6 unidades — requieren `SNAPRAID_SYNC_ONCALENDAR` exportada |
| `/etc/systemd/system/nfs-sync.{service,timer}` | 4, 5 | 2 unidades — requieren `NFS_SYNC_ONCALENDAR` exportada |
| `/var/lib/nas-setup/scripts/snapraid-sync-safe.sh` | 2, 5 | Script de sync con safety gate (THRESHOLD actualizable con sed) |
| `/var/lib/nas-setup/scripts/nfs-sync.sh` | 4 | Script de sync NFS remoto → local |

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
```

---

## Pitfalls conocidos

1. **Boot disk detection**: `_get_boot_disk()` en `discover.sh` puede fallar en configuraciones con LVM o RAID software como boot. Verificar manualmente si el script excluye discos incorrectos. El módulo 6 (SMART report) sí incluye el boot disk.

2. **NVMe naming**: las particiones NVMe son `nvme0n1p1` (no `nvme0n11`). `format.sh` maneja esto con un condicional `[[ "$dev" =~ nvme ]]`.

3. **MergerFS .deb naming**: el formato del nombre del archivo cambia entre releases. Si la descarga falla, revisar `https://github.com/trapexit/mergerfs/releases` y ajustar la lógica en `mergerfs.sh:install_mergerfs()`.

4. **envsubst y variables Flux**: los manifests K8s generados en módulo 3 deben preservar `${NFS_SERVER}` literal para que Flux los sustituya. No pasar esas variables al entorno antes de llamar envsubst en ese contexto específico.

5. **FORCE_RERUN=1**: limpia todos los sentinels de idempotencia. Si se interrumpe a mitad de una operación, la próxima ejecución con `FORCE_RERUN=1` puede intentar re-formatear discos ya formateados. Confirmar con el usuario antes.

6. **set_env_var y caracteres especiales**: el delimitador `|` en el `sed` de `set_env_var` se rompe si el valor contiene `|`. Cambiar el delimitador en ese caso.

7. **Funciones capturadas con `$()`**: cualquier función que mezcle display y retorno de valor debe redirigir el display a `>&2` y usar `</dev/tty` en el `read`. Ver `_pick_period()` como ejemplo.

8. **SnapRAID con SSDs**: el sync diario escribe en paridad proporcional a los cambios. Con mucha actividad puede agotar el TBW del SSD de paridad en pocos años. Usar periodicidad semanal o mensual, o cambiar a ZFS RAIDZ1 si todos los discos son SSD.
