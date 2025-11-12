# backuptool.sh — Administrador ligero de respaldos y monitoreo

[![Estado: Stable](https://img.shields.io/badge/status-stable-brightgreen.svg)](https://github.com/WillyrexCUE23182/Proyecto-Administrador-ligero-de-respaldos-y-monitoreo-/tree/main)
[![Licencia: UVG](https://img.shields.io/badge/license-UVG-blue.svg)](LICENSE)
![Bash >= 4.0](https://img.shields.io/badge/Bash-%3E%3D4.0-121011?logo=gnubash)
![Tested on Rocky Linux 8/9](https://img.shields.io/badge/tested-Rocky%20Linux-8%2F9-success)

**Autor:** Willy Cuellar (23182)  
**Correo:** cue23182@uvg.edu.gt  
**Repositorio:** [Proyecto Administrador ligero de respaldos y monitoreo](https://github.com/WillyrexCUE23182/Proyecto-Administrador-ligero-de-respaldos-y-monitoreo-/tree/main)  
**Lenguaje:** Bash  
**SO objetivo:** Linux (probado en **Rocky Linux 8/9**, compatible con RHEL, Fedora, Debian y Ubuntu)

---

## 🧍‍⚖️ Descripción

**backuptool.sh** es una herramienta CLI en **Bash** para ejecutar **respaldos incrementales con `rsync`**, gestionar fuentes y destinos, registrar eventos y **monitorear archivos de log** del sistema con alertas opcionales vía **Telegram**.  
Su objetivo es simplificar la gestión de copias de seguridad en entornos Linux y ofrecer un monitoreo automatizado ante errores.

**Flujo de operación:**
```
[FUENTES] → [rsync incremental] → [DESTINO] → [LOG] → [ALERTA TELEGRAM]
```

---

## 🔧 Características

- Respaldos incrementales automáticos mediante `rsync`.  
- Registro detallado en `~/backups/backup.log`.  
- Detección automática del destino (USB, `/mnt/backup`, etc.).  
- Modo monitor de logs con umbral y ventana temporal configurables.  
- Alertas vía Telegram (`--force` y configuración en `~/.backup_admin.conf`).  
- Instalador `install.sh` con:
  - Alias `btool` y función `backup-monitor`.
  - Instalación local o global (`/usr/local/bin`).
  - Servicio `systemd` automático (`backuptool-monitor.service`).  
- Diseñado con buenas prácticas de Bash (`set -Eeuo pipefail`).

---

## 🛠️ Requisitos Previos

**Dependencias obligatorias:**
- `bash` ≥ 4.0  
- `rsync`  
- `curl`  
- `systemd` (solo para el servicio)

### Instalación en Rocky Linux / RHEL / Fedora
```bash
sudo dnf install -y rsync curl
```

### Instalación en Debian / Ubuntu
```bash
sudo apt update && sudo apt install -y rsync curl
```

Asegura permisos de ejecución:
```bash
chmod +x backuptool.sh install.sh
```

---

## 🛠️ Instalación

### Clonar el repositorio
```bash
git clone https://github.com/WillyrexCUE23182/Proyecto-Administrador-ligero-de-respaldos-y-monitoreo-.git
cd Proyecto-Administrador-ligero-de-respaldos-y-monitoreo-
```

### Instalación local (usuario actual)
```bash
./install.sh install
source ~/.bashrc
```

### Instalación global (requiere sudo)
```bash
sudo ./install.sh install --global
```

### Activar servicio `systemd`
```bash
sudo ./install.sh service
sudo systemctl status backuptool-monitor.service
```

Logs del servicio:
```bash
journalctl -u backuptool-monitor.service -f
```

---

## 🔧 Configuración

Archivo: `~/.backup_admin.conf`
```bash
# Ruta destino por defecto
DEST=/mnt/backup

# Configuración Telegram (opcional)
TELEGRAM_BOT_TOKEN=123456:ABCDEF
TELEGRAM_CHAT_ID=987654321
```

Lista de fuentes: `~/.backup_sources.list`  
Cada línea representa una ruta de respaldo (archivo o carpeta).  
El archivo se crea automáticamente desde el menú interactivo.

Logs: `~/backups/backup.log`

---

## 🖥️ Uso

### Menú interactivo
```bash
btool
```

**Opciones:**
1. Configurar fuentes (agregar/quitar/listar)  
2. Seleccionar destino  
3. Ejecutar respaldo incremental  
4. Ver estado del último respaldo  
5. Activar modo monitor  
6. Demo de lecturas  
7. Diagnóstico  
8. Salir  

### Línea de comandos
```bash
backuptool [--verbose] [--dry-run] [--force] [--monitor] [--log PATH] [--threshold N] [--window MIN]
```

| Opcion | Descripción |
|:--|:--|
| `--verbose` | Muestra detalles de ejecución |
| `--dry-run` | Simula respaldo sin cambios reales |
| `--force` | Permite acciones reales y alertas Telegram |
| `--monitor` | Inicia el modo monitor de logs |
| `--log PATH` | Especifica archivo de log |
| `--threshold N` | Umbral de errores antes de alertar (default: 5) |
| `--window MIN` | Ventana de tiempo en minutos (default: 10) |
| `--help` | Muestra ayuda |

Ejemplo:
```bash
backuptool --monitor --log /var/log/messages --threshold 3 --window 5 --force
```

---

## 🔎 Ejemplos

**1)** Respaldo interactivo:
```bash
btool
```
**2)** Simular respaldo sin modificar archivos:
```bash
backuptool --dry-run --verbose
```
**3)** Monitorear logs del sistema:
```bash
backup-monitor
```
**4)** Revisar estado:
```bash
tail -n 40 ~/backups/backup.log
```

---

## 🗂️ Estructura de archivos

| Archivo / Carpeta | Descripción |
|--------------------|--------------|
| `backuptool.sh` | Script principal |
| `install.sh` | Instalador local/global + systemd |
| `~/.backup_admin.conf` | Configuración del usuario |
| `~/.backup_sources.list` | Rutas a respaldar |
| `~/backups/backup.log` | Registro de respaldos |
| `<DEST>/latest` | Symlink al último respaldo |

---

## 🔒 Permisos y SELinux (Rocky/RHEL)

Si SELinux está activo y el destino es `/mnt/backup` o una unidad externa:
```bash
ls -Z /mnt/backup
sudo chcon -Rt usr_t /mnt/backup
```
Para montajes en `/run/media/$USER/...`, verifica permisos de escritura y propiedad del usuario.

---

## 🚨 Solución de problemas

**1)** `rsync: command not found`
```bash
sudo dnf install -y rsync
```

**2)** `Destino no escribible`
```bash
df -h
ls -ld /mnt/backup
```

**3)** No llegan alertas Telegram
Verifica el archivo `~/.backup_admin.conf` y ejecuta con `--force`.

**4)** El servicio `systemd` no inicia
```bash
sudo systemctl status backuptool-monitor.service
journalctl -u backuptool-monitor.service -xe
```

---

## 🤝 Contribución

1. Haz un Fork del repositorio.  
2. Crea una rama:
```bash
git checkout -b feature/nueva-funcionalidad
```
3. Commit:
```bash
git commit -m "feat: agrega rotación automática de logs"
```
4. Push:
```bash
git push origin feature/nueva-funcionalidad
```
5. Abre un Pull Request.

---

## 📜 Licencia

Este proyecto está protegido bajo la **Licencia UVG**.  
Consulta el archivo `LICENSE` para más detalles.

---

## 📧 Contacto

**Autor:** Willy Cuellar (23182)  
**Correo:** [cue23182@uvg.edu.gt](mailto:cue23182@uvg.edu.gt)  
**Repositorio:** [Proyecto Administrador ligero de respaldos y monitoreo](https://github.com/WillyrexCUE23182/Proyecto-Administrador-ligero-de-respaldos-y-monitoreo-/tree/main)

