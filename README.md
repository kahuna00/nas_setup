# NAS Setup Suite

Suite de scripts Bash para configurar almacenamiento en red en un servidor NAS ARM64 (CM3588) corriendo k3s Kubernetes con Flux GitOps.

**Cubre:** NFS · Samba/CIFS · MergerFS · SnapRAID · NFS Sync · Integración Kubernetes

---

## Tabla de contenidos

- [Requisitos](#requisitos)
- [Inicio rápido](#inicio-rápido)
- [Módulos](#módulos)
  - [Módulo 1 — NFS + Samba](#módulo-1--nfs--samba)
  - [Módulo 2 — MergerFS + SnapRAID](#módulo-2--mergerfs--snapraid)
  - [Módulo 3 — Integración Kubernetes](#módulo-3--integración-kubernetes)
  - [Módulo 4 — NFS Sync](#módulo-4--nfs-sync)
- [Configuración (.env)](#configuración-env)
- [Tests de verificación](#tests-de-verificación)
- [GUIs recomendadas](#guis-recomendadas)
- [Referencia de archivos del sistema](#referencia-de-archivos-del-sistema)
- [Solución de problemas](#solución-de-problemas)

---

## Requisitos

| Requisito | Detalle |
|-----------|---------|
| OS | Debian 11/12 o Ubuntu 22.04/24.04 |
| Arquitectura | ARM64 (aarch64) — probado en CM3588 |
| Privilegios | root (`sudo bash install.sh`) |
| Dependencias | `bash`, `python3`, `curl` — el script instala el resto |

---

## Inicio rápido

```bash
# 1. Clona o copia el repo al servidor NAS
cd /home/jgomez/nas-setup

# 2. Crea tu configuración
cp .env.example .env
nano .env          # configura al menos: NFS_SHARE_DIR, SAMBA_USER, SAMBA_PASSWORD

# 3. Ejecuta el instalador
sudo bash install.sh
```

El menú principal te guiará por cada módulo.

---

## Módulos

### Módulo 1 — NFS + Samba

Configura shares de red desde las variables del `.env`. Idempotente: re-ejecutar actualiza la configuración sin romper nada.

**Qué hace:**

1. Instala `nfs-kernel-server` y `samba` (solo si no están instalados)
2. Genera `/etc/exports.d/nas-setup.exports` con la share principal y extras opcionales
3. Genera y valida `/etc/samba/smb.conf` con `testparm` antes de aplicar
4. Crea el usuario Samba (usuario de sistema sin login) y establece su contraseña
5. Verifica pre/post que los PersistentVolumes Kubernetes NFS sigan en estado `Bound`
6. Ejecuta smoke tests: `exportfs -v` y `smbclient`

**Variables clave en `.env`:**

```bash
NFS_SHARE_DIR=/nfs/kahunaz             # share principal (usada por k8s CSI)
NFS_EXTRA_DIRS=/armhot:/mergerfs/pool  # shares adicionales (opcional)
NFS_POOL_LINK=/srv/nfs                 # symlink del pool MergerFS para NFS
SMB_POOL_LINK=/srv/smb                 # symlink del pool MergerFS para Samba
NFS_ALLOWED_NETWORK=192.168.0.0/24
SAMBA_USER=nasuser
SAMBA_PASSWORD=tu-password-seguro
SAMBA_SHARE_NAME=NAS
```

**Acceso desde clientes:**

```bash
# Linux — NFS
mount -t nfs -o nfsvers=4.1 <IP_NAS>:/nfs/kahunaz /mnt/nas

# Windows/macOS — Samba
# Explorador: \\<IP_NAS>\NAS
# macOS Finder: smb://<IP_NAS>/NAS

# Kubernetes (ya configurado vía CSI driver)
# storageClassName: nfs-csi
```

> Sustituye `<IP_NAS>` por la IP de tu servidor (detectable con `hostname -I | awk '{print $1}'`).

---

### Módulo 2 — MergerFS + SnapRAID

Setup guiado e interactivo para crear un pool de almacenamiento unificado con protección ante fallos de disco.

**Concepto:**

```
  /dev/sda (4TB data)  ─┐
  /dev/sdb (4TB data)  ─┼──→ MergerFS pool → /mergerfs/pool  (12TB útil)
  /dev/sdc (4TB data)  ─┘
  /dev/sdd (4TB parity)   ──→ SnapRAID parity  (tolerancia: 1 disco)
```

- **MergerFS** une múltiples discos en un único directorio. No es RAID — cada archivo vive íntegro en un solo disco.
- **SnapRAID** calcula paridad periódicamente. No es paridad en tiempo real (como RAID5), sino por lotes. Esto es ideal para almacenamiento de medios donde los datos no cambian constantemente.

**Flujo interactivo (7 pasos):**

```
Paso 1 — Descubrimiento de discos
  → tabla: dispositivo, tamaño, modelo, serial, salud SMART, tipo (HDD/SSD)
  → excluye automáticamente el disco de boot

Paso 2 — Asignación de roles
  → por cada disco: [d]ata / [p]arity / [s]kip
  → valida que disco parity >= disco data más grande
  → advierte si asignas un SSD como parity

Paso 3 — Estimación de espacio
  → espacio útil = suma de discos DATA
  → overhead = suma de discos PARITY
  → MergerFS no añade overhead

Paso 4 — Formateo (opcional)
  → GPT + ext4 con etiqueta (data1, data2, parity1, ...)
  → UUID en /etc/fstab con nofail (el sistema arranca aunque falte un disco)
  → confirmación obligatoria por tipo (DATA / PARITY)

Paso 5 — MergerFS
  → descarga .deb ARM64 desde GitHub releases (con caché local)
  → configura fstab: política mfs, allow_other, cache.files=off
  → compatible con SnapRAID: dropcacheonclose=true

Paso 6 — SnapRAID
  → genera /etc/snapraid.conf con los discos asignados
  → content files en cada disco DATA + uno en el OS
  → excluye archivos temporales (.tmp, .DS_Store, .Trash-*, etc.)

Paso 7 — Scheduling automático
  → systemd timers (o cron si prefieres)
  → sync diario con safety gate (aborta si >20% archivos eliminados)
  → scrub semanal (verifica integridad del 5% de datos)
  → SMART mensual (salud de discos)
```

**Recomendaciones de distribución de discos:**

| Escenario | Configuración | Tolerancia |
|-----------|---------------|------------|
| 2 discos | 1 DATA + 1 PARITY | 1 disco |
| 3 discos | 2 DATA + 1 PARITY | 1 disco |
| 4 discos | 3 DATA + 1 PARITY | 1 disco |
| 5 discos | 3 DATA + 2 PARITY | 2 discos |
| Todos HDD | Recomendado para SnapRAID | — |
| SSD como DATA | OK | — |
| SSD como PARITY | No recomendado (desgaste por syncs frecuentes) | — |

**Tras configurar el módulo 2, ejecuta manualmente el primer sync:**

```bash
# Inicializa la paridad por primera vez (puede tardar horas según tamaño)
snapraid sync

# Verifica el estado
snapraid status

# Ver próximas ejecuciones programadas
systemctl list-timers snapraid-*.timer
```

**Exponer el pool vía NFS/Samba (después del módulo 2):**

```bash
# Edita .env y añade el pool a NFS_EXTRA_DIRS:
NFS_EXTRA_DIRS=/mergerfs/pool

# Re-ejecuta el módulo 1 para añadir la nueva share
sudo bash install.sh  # → opción 1
```

**Variables clave en `.env`:**

```bash
MERGERFS_POOL_PATH=/mergerfs/pool
MERGERFS_CREATE_POLICY=mfs       # distribuye escrituras al disco con más espacio
DISK_MOUNT_PREFIX=/mnt           # /mnt/data1, /mnt/data2, /mnt/parity1...
SNAPRAID_SYNC_HOUR=3             # sync diario a las 3:00 AM
SNAPRAID_SCRUB_DAY=Sun           # scrub semanal el domingo
SNAPRAID_DIFF_THRESHOLD=20       # aborta sync si >20% archivos eliminados
SCHEDULE_TYPE=systemd            # systemd (recomendado) o cron
```

---

### Módulo 3 — Integración Kubernetes

Integra el NAS con el cluster k3s. Permite cambiar el modo de storage entre NFS y acceso local directo, y generar los manifests PV/PVC correspondientes.

**Modos de storage:**

| Modo | Mecanismo | Cuándo usarlo |
|------|-----------|---------------|
| `nfs` | PVs con spec `nfs:` vía nfs-csi | Multi-nodo · acceso remoto · `ReadWriteMany` |
| `local` | PVs con `hostPath` + `nodeAffinity` | Single-node · NAS = nodo k8s · sin overhead de red |

**Opciones del módulo:**

1. **Cambiar modo de storage** — actualiza `cluster-vars.yaml` y hace push para que Flux reconcilie
2. **Generar manifests PV/PVC** — crea YAMLs en `./generated/k8s/` listos para `kubectl apply`
3. **Actualizar NFS_PATH** — cambia solo la ruta del share sin cambiar de modo
4. **Guía Longhorn** — instrucciones para instalar Longhorn vía Helm/GitOps

**Variables clave en `.env`:**

```bash
K8S_HOMELAB_PATH=/home/jgomez/k8-homelab
K8S_PV_NAMESPACE=file-share
K8S_MANIFESTS_OUTPUT=./generated/k8s
K8S_STORAGE_MODE=nfs   # nfs | local
```

**Requisito:** `yq` instalado (`apt install yq` o `snap install yq`) para el patch de `cluster-vars.yaml`.

---

### Módulo 4 — NFS Sync

Copia periódica desde un servidor NFS remoto al almacenamiento local usando `rsync`. Útil para replicar contenido de otro NAS o servidor de archivos hacia el pool local.

**Qué hace:**

1. Instala `nfs-common` y `rsync`
2. Crea el punto de montaje local y añade entrada `noauto` en `/etc/fstab`
3. Genera el script de runtime `/var/lib/nas-setup/scripts/nfs-sync.sh`
4. Programa un systemd timer (o cron) para sync diario

**Comportamiento del script de sync:**

- Monta el NFS remoto si no está montado — lo desmonta al terminar
- Ejecuta `rsync` del origen al destino local
- rsync exit 24 (archivos desaparecidos en tránsito) se trata como éxito — es normal en NFS
- Log completo en el journal: `journalctl -t nfs-sync -f`

**Variables clave en `.env`:**

```bash
NFS_SYNC_REMOTE_HOST=192.168.0.x        # IP del servidor NFS remoto
NFS_SYNC_REMOTE_PATH=/shared             # path exportado en el remoto
NFS_SYNC_MOUNT_POINT=/mnt/nfs-remote    # dónde se monta localmente
NFS_SYNC_DEST_DIR=/mergerfs/pool/backup # destino local de la copia
NFS_SYNC_HOUR=2                          # hora del sync diario (0-23)
NFS_SYNC_RSYNC_OPTS="--archive --delete --hard-links --numeric-ids"
NFS_SYNC_MOUNT_OPTIONS="ro,hard,timeo=30,retrans=3,nfsvers=4"
NFS_SYNC_BW_LIMIT=0                      # límite KB/s (0 = sin límite)
NFS_SYNC_EXCLUDES=.Trash*:*.tmp          # patrones a excluir, separados por ":"
```

**Uso manual:**

```bash
# Ejecutar sync ahora
sudo bash /var/lib/nas-setup/scripts/nfs-sync.sh

# Ver logs en tiempo real
journalctl -t nfs-sync -f

# Ver próxima ejecución programada
systemctl list-timers nfs-sync.timer
```

---

## Configuración (.env)

Copia `.env.example` a `.env` y ajusta los valores. El archivo `.env` está en `.gitignore` — nunca se sube al repositorio.

```bash
cp .env.example .env
```

### Variables completas

| Variable | Default | Módulo | Descripción |
|----------|---------|--------|-------------|
| `NFS_SHARE_DIR` | `/nfs/kahunaz` | 1 | Share NFS principal (usada por k8s CSI) |
| `NFS_EXTRA_DIRS` | _(vacío)_ | 1 | Shares adicionales separadas por `:` |
| `NFS_POOL_LINK` | _(vacío)_ | 1 | Symlink del pool MergerFS para NFS |
| `SMB_POOL_LINK` | _(vacío)_ | 1 | Symlink del pool MergerFS para Samba |
| `NFS_ALLOWED_NETWORK` | `192.168.0.0/24` | 1 | Red autorizada para montar NFS |
| `NFS_EXPORT_OPTIONS` | `rw,sync,no_subtree_check,no_root_squash` | 1 | Opciones de export |
| `SAMBA_WORKGROUP` | `WORKGROUP` | 1 | Nombre del grupo de trabajo |
| `SAMBA_USER` | `nasuser` | 1 | Usuario Samba (sin login de shell) |
| `SAMBA_PASSWORD` | `changeme` | 1 | **Cambiar en producción** |
| `SAMBA_SHARE_NAME` | `NAS` | 1 | Nombre visible de la share |
| `SAMBA_LOG_LEVEL` | `1` | 1 | Verbosidad: 0=mínimo, 3=máximo |
| `MERGERFS_POOL_PATH` | `/mergerfs/pool` | 2 | Punto de montaje del pool |
| `MERGERFS_CREATE_POLICY` | `mfs` | 2 | Política de escritura (`mfs`/`lfs`/`ff`) |
| `DISK_MOUNT_PREFIX` | `/mnt` | 2 | Prefijo para montajes individuales |
| `SNAPRAID_SYNC_HOUR` | `3` | 2 | Hora del sync diario (0-23) |
| `SNAPRAID_SCRUB_DAY` | `Sun` | 2 | Día del scrub semanal |
| `SNAPRAID_SCRUB_PERCENT` | `5` | 2 | % de datos a verificar por scrub |
| `SNAPRAID_DIFF_THRESHOLD` | `20` | 2 | % máx. eliminados antes de abortar sync |
| `SCHEDULE_TYPE` | `systemd` | 2 | Backend: `systemd` o `cron` |
| `K8S_HOMELAB_PATH` | `/home/jgomez/k8-homelab` | 3 | Ruta al repo k8-homelab |
| `K8S_PV_NAMESPACE` | `file-share` | 3 | Namespace para PVCs generados |
| `K8S_MANIFESTS_OUTPUT` | `./generated/k8s` | 3 | Destino de manifests YAML |
| `K8S_STORAGE_MODE` | `nfs` | 3 | Modo de storage: `nfs` o `local` |
| `NFS_SYNC_REMOTE_HOST` | _(requerido)_ | 4 | IP del servidor NFS remoto |
| `NFS_SYNC_REMOTE_PATH` | _(requerido)_ | 4 | Path exportado en el remoto |
| `NFS_SYNC_MOUNT_POINT` | `/mnt/nfs-remote` | 4 | Punto de montaje local del remoto |
| `NFS_SYNC_DEST_DIR` | _(requerido)_ | 4 | Directorio local destino del sync |
| `NFS_SYNC_HOUR` | `2` | 4 | Hora del sync diario (0-23) |
| `NFS_SYNC_RSYNC_OPTS` | `--archive --delete --hard-links --numeric-ids` | 4 | Flags rsync |
| `NFS_SYNC_MOUNT_OPTIONS` | `ro,hard,timeo=30,retrans=3,nfsvers=4` | 4 | Opciones de montaje NFS |
| `NFS_SYNC_BW_LIMIT` | `0` | 4 | Límite de ancho de banda en KB/s (0 = sin límite) |
| `NFS_SYNC_EXCLUDES` | _(vacío)_ | 4 | Patrones a excluir del sync, separados por `:` |
| `LOG_LEVEL` | `INFO` | todos | `INFO` o `DEBUG` |
| `FORCE_RERUN` | `0` | todos | `1` para ignorar estado y re-ejecutar todo |

---

## Tests de verificación

Cada módulo tiene su test independiente en `tests/`. También se ejecutan desde el menú principal (opción 5).

```bash
# Test individual
sudo bash tests/test-nfs.sh
sudo bash tests/test-samba.sh
sudo bash tests/test-mergerfs.sh
sudo bash tests/test-snapraid.sh
```

| Test | Verifica |
|------|----------|
| `test-nfs.sh` | nfs-server activo · share exportada · mount/write/read/umount · PVs Kubernetes Bound |
| `test-samba.sh` | smbd activo · share visible en listing · write/delete vía smbclient · testparm OK |
| `test-mergerfs.sh` | pool montado · espacio disponible · escritura en pool aparece en disco subyacente · fstab |
| `test-snapraid.sh` | binario instalado · conf válido · snapraid diff · timers systemd activos |

---

## GUIs recomendadas

Para gestión del NAS y el almacenamiento Kubernetes, ordenadas por relevancia:

### Cockpit — Gestión del OS del NAS

La opción más ligera para administrar el sistema operativo del servidor directamente.

```bash
# Instalar en el servidor NAS
apt install cockpit cockpit-storaged

# Acceder en el navegador (sustituye <IP_NAS> por la IP de tu servidor)
http://<IP_NAS>:9090
```

- No conflicta con k3s ni con los servicios existentes
- Plugin `cockpit-storaged` para gestión de discos, RAID, LVM
- Terminal web integrada
- Monitoreo de CPU, RAM, disco, red en tiempo real

---

### Longhorn — Storage dashboard nativo Kubernetes

El mejor complemento para tu setup k3s. Es un proyecto CNCF (Cloud Native Computing Foundation) que corre como pods y provee:

- Dashboard web en `longhorn.kahunaz.duckdns.org`
- Snapshots y backups a S3/NFS
- Replicación entre nodos (útil si escalas a multi-nodo)
- Métricas en Prometheus/Grafana (ya tienes ambos desplegados)

**Instalación vía GitOps Flux:**

Añade a `k8-homelab/infrastructure/controllers/longhorn.yaml`:

```yaml
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: longhorn
  namespace: flux-system
spec:
  interval: 24h
  url: https://charts.longhorn.io
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: longhorn
  namespace: longhorn-system
spec:
  interval: 30m
  chart:
    spec:
      chart: longhorn
      version: ">=1.7.0 <2.0.0"
      sourceRef:
        kind: HelmRepository
        name: longhorn
        namespace: flux-system
  values:
    defaultSettings:
      defaultReplicaCount: 1    # single-node cluster
    ingress:
      enabled: true
      host: longhorn.${DOMAIN}
```

**Prerrequisito:**
```bash
apt install open-iscsi nfs-common
```

> **Nota:** Longhorn provee almacenamiento de **bloque** (`ReadWriteOnce`). Tu NFS-CSI actual provee `ReadWriteMany`. Son complementarios — usa Longhorn para apps que necesiten I/O intensivo, snapshots frecuentes o backups a S3.

---

### Filebrowser — Ya desplegado

Ya tienes Filebrowser corriendo en `files.kahunaz.duckdns.org`. Para que muestre el pool MergerFS, añade el path al PV correspondiente en tu GitOps.

---

### CasaOS — Dashboard homelab ARM-friendly

Alternativa ligera para workloads que no van en Kubernetes.

```bash
curl -fsSL https://get.casaos.io | bash
# Acceso: http://<IP_NAS> (puerto 80)
```

Corre en Docker y no conflicta con k3s (usan diferentes runtimes de contenedor).

---

## Referencia de archivos del sistema

Archivos que los scripts crean o modifican:

| Archivo | Módulo | Descripción |
|---------|--------|-------------|
| `/etc/exports.d/nas-setup.exports` | 1 | Exports NFS (no toca `/etc/exports` del sistema) |
| `/etc/samba/smb.conf` | 1 | Configuración Samba (backup automático en `.bak.*`) |
| `/etc/fstab` | 2, 4 | Solo se añaden líneas (nunca se elimina nada) |
| `/etc/snapraid.conf` | 2 | Configuración SnapRAID (backup automático) |
| `/etc/systemd/system/snapraid-*.{service,timer}` | 2 | 6 unidades systemd para SnapRAID |
| `/etc/systemd/system/nfs-sync.{service,timer}` | 4 | 2 unidades systemd para NFS Sync |
| `/var/lib/nas-setup/state/` | todos | Sentinels de idempotencia |
| `/var/lib/nas-setup/scripts/snapraid-sync-safe.sh` | 2 | Script de sync con safety gate |
| `/var/lib/nas-setup/scripts/nfs-sync.sh` | 4 | Script de sync NFS remoto → local |
| `/var/cache/nas-setup/` | 2 | Caché de binarios descargados (.deb) |
| `./generated/k8s/` | 3 | Manifests PV/PVC generados |
| `./logs/nas-setup-YYYYMMDD-HHMMSS.log` | todos | Log de sesión |

---

## Solución de problemas

### NFS: los PVs de Kubernetes cayeron después de reconfigurar

```bash
# Verificar estado
kubectl get pv -A
exportfs -v

# Si un PV está en Released (claim eliminado pero PV sigue):
kubectl patch pv <nombre> -p '{"spec":{"claimRef":null}}'

# Recargar exports
exportfs -ra
systemctl restart nfs-server
```

### Samba: error de autenticación

```bash
# Verificar usuario
pdbedit -L -v | grep SAMBA_USER

# Resetear contraseña
smbpasswd -a nasuser

# Probar conexión
smbclient //localhost/NAS -U nasuser
```

### MergerFS: pool no monta al arrancar

```bash
# Verificar fstab
grep mergerfs /etc/fstab

# Montar manualmente
mount /mergerfs/pool

# Ver errores detallados
dmesg | grep mergerfs
journalctl -u systemd-remount-fs
```

### SnapRAID: sync abortado por umbral de diff

```bash
# Ver cuántos archivos cambiaron
snapraid diff

# Si el cambio es intencional (borrado masivo legítimo):
snapraid sync   # ejecutar manualmente — ignora el threshold

# Si fue accidental: NO ejecutar sync; recuperar desde backup
```

### SnapRAID: fallo de disco detectado

```bash
# Ver estado
snapraid status

# Recuperar datos del disco fallido a un nuevo disco (montado en el mismo punto):
snapraid fix -d dN   # donde N es el número del disco DATA fallido
```

### NFS Sync: el montaje remoto falla

```bash
# Verificar que el host remoto es accesible
ping <NFS_SYNC_REMOTE_HOST>
showmount -e <NFS_SYNC_REMOTE_HOST>

# Montar manualmente para diagnosticar
mount -t nfs -o ro,nfsvers=4 <NFS_SYNC_REMOTE_HOST>:<NFS_SYNC_REMOTE_PATH> /mnt/nfs-remote

# Ver logs del último sync
journalctl -t nfs-sync --since "1 hour ago"
```

### Re-ejecutar un módulo desde cero

```bash
# Opción 1: desde el menú
sudo bash install.sh  # → opción 6 (Resetear estado)

# Opción 2: variable de entorno
FORCE_RERUN=1 sudo bash install.sh

# Opción 3: limpiar estado de un módulo específico
rm /var/lib/nas-setup/state/nfs_configured
rm /var/lib/nas-setup/state/samba_configured
rm /var/lib/nas-setup/state/nfs_sync_mount
rm /var/lib/nas-setup/state/nfs_sync_script
rm /var/lib/nas-setup/state/nfs_sync_schedule
```

### Logs

```bash
# Ver log de la última sesión
ls -t logs/ | head -1 | xargs -I{} cat logs/{}

# Logs del sistema para SnapRAID
journalctl -u snapraid-sync -f
journalctl -u snapraid-scrub --since "7 days ago"

# Logs del NFS Sync
journalctl -t nfs-sync -f
```
