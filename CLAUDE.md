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
| IP del NAS | 192.168.0.197 |
| Kubernetes | k3s v1.31.4+k3s1 |
| GitOps | Flux CD (reconcilia cada 2 min al hacer push) |
| Dominio | kahunaz.duckdns.org |
| Storage class default | `nfs-csi` (servidor: 192.168.0.197, path: /nfs/kahunaz) |
| Rutas NFS en uso por k8s | `/nfs/kahunaz` (CSI dynamic), `/armhot/Media/downloads`, `/armhot/respaldo-asm`, `/armhot/backups/k8s` |

---

## Arquitectura del código

### Carga de dependencias

Todos los módulos se ejecutan sourced (no como subprocesos). El orden de source es obligatorio:

```
lib/colors.sh → lib/logging.sh → lib/os.sh → lib/env.sh → lib/idempotency.sh → lib/k8s.sh
```

`install.sh` hace este source antes de llamar a cualquier módulo. Los módulos individuales NO deben re-sourcear la lib si ya fueron llamados desde `install.sh`.

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

### Arrays globales del módulo 2

`discover.sh` popula arrays globales que usan todos los scripts del módulo 2:

```bash
ALL_DISKS=()           # devices: /dev/sda, /dev/sdb, ...
DISK_SIZE["$dev"]      # string: "4.0T"
DISK_SIZE_BYTES["$dev"] # bytes para comparación numérica
DISK_MODEL["$dev"]
DISK_SERIAL["$dev"]
DISK_SMART["$dev"]     # PASSED / FAILED / UNKNOWN
DISK_TYPE["$dev"]      # HDD / SSD / NVMe
```

`assign.sh` popula `DATA_DISKS[]` y `PARITY_DISKS[]`.

`format.sh` popula `DISK_MOUNTPOINT["$dev"]` (dev → /mnt/dataN o /mnt/parityN).

Estos arrays deben estar disponibles cuando se llamen los scripts de pasos posteriores — todos son sourced en `modules/02-mergerfs-snapraid/setup.sh`.

---

## Módulo 3 — Estado inactivo

El módulo 3 (`modules/03-k8s-integration/`) tiene `return 0` al inicio de `setup_k8s_integration()`. El código está completo pero no se ejecuta. Para activar: eliminar esa línea.

No activar sin antes verificar que el cluster está sano y los PVs actuales están Bound.

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

| Archivo | Qué hace el script |
|---------|-------------------|
| `/etc/exports.d/nas-setup.exports` | Sobreescribe (backup .bak.TIMESTAMP antes) |
| `/etc/samba/smb.conf` | Sobreescribe (backup .bak.TIMESTAMP, valida con testparm) |
| `/etc/fstab` | Solo append — nunca elimina líneas existentes |
| `/etc/snapraid.conf` | Sobreescribe (backup .bak.TIMESTAMP antes) |
| `/etc/systemd/system/snapraid-*.{service,timer}` | Crea/sobreescribe |

---

## Relación con k8-homelab

El repo hermano es `/home/jgomez/k8-homelab`. Puntos de contacto:

- `lib/k8s.sh:check_nfs_mounts()` — consulta PVs vía kubectl
- `modules/03-k8s-integration/update-cluster-vars.sh` — hace patch de `clusters/kahunaz/cluster-vars.yaml`
- `modules/03-k8s-integration/generate-pvs.sh` — genera manifests que siguen el patrón de `apps/kahunaz/downloader/01-pvc.yaml`
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

# Timers systemd SnapRAID
systemctl list-timers snapraid-*.timer

# Estado de PVs Kubernetes
kubectl get pv -A -o wide

# Logs de sesión de nas-setup
ls -t /home/jgomez/nas-setup/logs/ | head -5
```

---

## Pitfalls conocidos

1. **Boot disk detection**: `_get_boot_disk()` en `discover.sh` puede fallar en configuraciones con LVM o RAID software como boot. Verificar manualmente si el script excluye discos incorrectos.

2. **NVMe naming**: las particiones NVMe son `nvme0n1p1` (no `nvme0n11`). `format.sh` maneja esto con un condicional `[[ "$dev" =~ nvme ]]`.

3. **MergerFS .deb naming**: el formato del nombre del archivo cambia entre releases. Si la descarga falla, revisar `https://github.com/trapexit/mergerfs/releases` y ajustar la lógica en `mergerfs.sh:install_mergerfs()`.

4. **envsubst y variables Flux**: los manifests K8s generados en módulo 3 deben preservar `${NFS_SERVER}` literal para que Flux los sustituya. No pasar esas variables al entorno antes de llamar envsubst en ese contexto específico.

5. **FORCE_RERUN=1**: limpia todos los sentinels de idempotencia. Si se interrumpe a mitad de una operación, la próxima ejecución con `FORCE_RERUN=1` puede intentar re-formatear discos ya formateados. Confirmar con el usuario antes.
