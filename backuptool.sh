#!/usr/bin/env bash
# =============================================================================
# backuptool.sh — Administrador ligero de respaldos y monitoreo
# Autor: Willy Cuellar 23182
# Descripción:
#   Script en Bash para:
#     - Configurar fuentes de respaldo (archivos/carpetas).
#     - Seleccionar destino (auto / manual).
#     - Ejecutar respaldo incremental con rsync.
#     - Registrar acciones en ~/backups/backup.log.
#     - Modo monitor de logs con alertas (Telegram).
#   Soporta: --verbose, --dry-run (simulación), --force (acciones reales/alertas),
#            --monitor, --log, --threshold, --window.
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

# ------------------------------ Rutas y archivos -----------------------------
SCRIPT_NAME="$(basename "$0")"
CONFIG_FILE="${HOME}/.backup_admin.conf"        # Variables: DEST, TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID
BACKUP_BASE="${HOME}/backups"                   # Carpeta base de respaldos
LOG_FILE="${BACKUP_BASE}/backup.log"            # Log de acciones
SOURCES_FILE="${HOME}/.backup_sources.list"     # Lista de fuentes (una por línea)
LATEST_LINK="latest"                            # Symlink al último respaldo
DEFAULT_MONITOR_LOG="${HOME}/backup-admin/samples/syslog.sample"  # Log por defecto para monitor

# ------------------------------ Flags y defaults -----------------------------
VERBOSE=0; DRYRUN=0; FORCE=0; MONITOR_MODE=0
MON_THRESHOLD=5; MON_WINDOW_MIN=10; MON_LOG="${DEFAULT_MONITOR_LOG}"
MON_PATTERNS="error|fail|critical|segfault|panic"  # Palabras clave para detectar errores

# ------------------------------ Utilidades base ------------------------------
ts()  { date +"%Y-%m-%d %H:%M:%S"; }
elog(){ printf '[%s] %s %s\n' "$SCRIPT_NAME" "$(ts)" "$*" >&2; }
info(){ (( VERBOSE )) && elog "INFO: $*"; }
warn(){ elog "WARN: $*"; }
die() { elog "ERROR: $*"; exit 1; }
log(){ mkdir -p "$(dirname "$LOG_FILE")"; printf '[%s] %s %s\n' "$SCRIPT_NAME" "$(ts)" "$*" >>"$LOG_FILE"; }

# Garantiza estructura mínima del proyecto
ensure_base(){
  mkdir -p "$BACKUP_BASE"
  touch "$LOG_FILE"
  [[ -f "$SOURCES_FILE" ]] || : > "$SOURCES_FILE"
}

# Carga configuración si existe (~/.backup_admin.conf)
load_conf(){ [[ -f "$CONFIG_FILE" ]] && . "$CONFIG_FILE" || true; }

# Mensaje de ayuda
usage(){
  cat <<'EOF'
Uso:
  backuptool.sh [opciones]                  # Menú interactivo
  backuptool.sh --monitor [--log PATH] [--threshold N] [--window M] [--force]

Opciones:
  --verbose        Salida detallada
  --dry-run        Simulación (no ejecuta cambios)
  --force          Permite acciones reales (alerta Telegram)
  --monitor        Activa modo monitor de logs
  --log PATH       Archivo de log a observar (por defecto: samples/syslog.sample)
  --threshold N    Nº de errores en ventana para alertar (default 5)
  --window M       Ventana en minutos (default 10)
  -h, --help       Mostrar ayuda

Config (~/.backup_admin.conf):
  DEST=/ruta/destino
  TELEGRAM_BOT_TOKEN=xxxxx
  TELEGRAM_CHAT_ID=123456789
EOF
}

# ----------------------------- Gestión de fuentes ----------------------------
list_sources(){
  [[ -s "$SOURCES_FILE" ]] || { echo "No hay fuentes."; return 1; }
  nl -ba "$SOURCES_FILE"
}

add_source(){
  local p="${1:-}"
  [[ -z "$p" ]] && die "Ruta vacía"
  [[ -e "$p" ]] || { warn "No existe: $p"; return 1; }
  [[ "$p" == /* ]] || p="$(cd "$(dirname "$p")" && pwd)/$(basename "$p")"   # Absolutiza
  grep -Fxq "$p" "$SOURCES_FILE" && { warn "Ya estaba: $p"; return 0; }
  echo "$p" >> "$SOURCES_FILE"
  elog "Añadida fuente: $p"
}

remove_source_by_number(){
  local n="${1:-}"
  [[ "$n" =~ ^[0-9]+$ ]] || die "Índice inválido"
  local t; t=$(wc -l < "$SOURCES_FILE")
  (( t>0 && n>=1 && n<=t )) || die "Fuera de rango (1..$t)"
  local r; r=$(sed -n "${n}p" "$SOURCES_FILE")
  sed -i.bak "${n}d" "$SOURCES_FILE"
  elog "Eliminada fuente: $r"
}

# ----------------------------- Selección de destino --------------------------
autodetect_dest(){
  mount | grep -qE ' on /mnt/backup ' && { echo /mnt/backup; return; }
  mount | grep -qE ' on /media/usb '   && { echo /media/usb; return; }
  echo "${BACKUP_BASE}"
}

config_set_dest(){
  local d="$1"
  mkdir -p "$(dirname "$CONFIG_FILE")"
  if grep -q '^DEST=' "$CONFIG_FILE" 2>/dev/null; then
    sed -i.bak "s|^DEST=.*$|DEST=$d|" "$CONFIG_FILE"
  else
    echo "DEST=$d" >> "$CONFIG_FILE"
  fi
}

config_get_dest(){
  if grep -q '^DEST=' "$CONFIG_FILE" 2>/dev/null; then
    grep '^DEST=' "$CONFIG_FILE" | head -n1 | cut -d= -f2-
  else
    echo ""
  fi
}

# ------------------------------- Validaciones --------------------------------
check_readable_sources(){
  local ok=1 s
  while IFS= read -r s; do
    [[ -z "$s" ]] && continue
    [[ -r "$s" ]] || { warn "Sin permiso de lectura: $s"; ok=0; }
  done < "$SOURCES_FILE"
  (( ok==1 ))
}

total_sources_size_kb(){
  local tot=0 s size
  while IFS= read -r s; do
    [[ -z "$s" ]] && continue
    if [[ -e "$s" ]]; then
      size=$(du -sk --apparent-size "$s" 2>/dev/null | awk '{sum+=$1} END{print sum+0}')
      tot=$((tot+size))
    fi
  done < "$SOURCES_FILE"
  echo "$tot"
}

check_space(){
  local d="$1"
  [[ -d "$d" ]] || mkdir -p "$d"
  local a; a=$(df -Pk "$d" | awk 'NR==2{print $4}')
  local n; n=$(total_sources_size_kb)
  info "Espacio destino=${a}KB | Necesario≈${n}KB"
  (( a>n ))
}

check_writable_dest(){
  local d="$1"
  [[ -d "$d" ]] || mkdir -p "$d"
  [[ -w "$d" ]]
}

# ------------------------------ Respaldos (rsync) ----------------------------
have_rsync(){ command -v rsync >/dev/null 2>&1; }

# Ejecuta un comando con soporte de --dry-run y logging
run_cmd() {
  info "cmd: $*"
  if (( DRYRUN )); then
    echo "[dry-run] $*"
    return 0
  fi
  command "$@"
}

backup_incremental(){
  ensure_base
  [[ -s "$SOURCES_FILE" ]] || die "No hay fuentes configuradas."
  check_readable_sources || die "Fuentes no legibles."
  have_rsync || die "rsync no disponible. Instálalo: sudo dnf -y install rsync"

  local dest; dest="$(config_get_dest)"; [[ -n "$dest" ]] || dest="$(autodetect_dest)"
  check_writable_dest "$dest" || die "Destino no escribible."
  check_space "$dest" || die "Espacio insuficiente."

  local stamp subdir
  stamp="$(date +'%Y-%m-%d_%H%M%S')"
  subdir="${dest}/backup_${stamp}"
  mkdir -p "$subdir"
  log "INICIO respaldo -> $subdir (dry-run=$DRYRUN)"

  local rs_opts=(-a --human-readable --stats --delete --ignore-errors --update)
  (( VERBOSE )) && rs_opts+=(-v)
  (( DRYRUN )) && rs_opts+=(--dry-run)

  # Recorre cada fuente y ejecuta rsync
  while IFS= read -r src; do
    [[ -z "$src" ]] && continue
    if [[ -d "$src" ]]; then
      run_cmd rsync "${rs_opts[@]}" "${src}/" "$subdir/$(basename "$src")/"
    else
      mkdir -p "$subdir/files"
      run_cmd rsync "${rs_opts[@]}" "$src" "$subdir/files/"
    fi
  done < "$SOURCES_FILE"

  # Actualiza symlink "latest"
  ( cd "$dest" && { rm -f "$LATEST_LINK"; ln -s "backup_${stamp}" "$LATEST_LINK"; } ) || true
  log "FIN respaldo -> $subdir"
  echo "Respaldo completado: $subdir"
}

show_last_status(){
  ensure_base
  echo "Últimas 40 líneas del log:"
  tail -n 40 "$LOG_FILE" || true
}

# ------------------------------ Alertas (Telegram) ---------------------------
# Requiere TELEGRAM_BOT_TOKEN y TELEGRAM_CHAT_ID en ~/.backup_admin.conf
send_telegram(){
  local text="$1"
  if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
    curl -fsS -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -d "chat_id=${TELEGRAM_CHAT_ID}" --data-urlencode "text=${text}" >/dev/null \
      || warn "Fallo Telegram"
  else
    info "Telegram no configurado; omito envío real"
  fi
}

alert_notify(){
  local msg="$1"
  log "ALERT $msg"
  if (( FORCE )) && (( ! DRYRUN )); then
    send_telegram "$msg" || true
  else
    elog "ALERTA (stub): $msg (usa --force para enviar Telegram)"
  fi
}

# ------------------------------ Monitor de logs ------------------------------
# Extrae epoch de una línea con formato 'Mon DD HH:MM:SS' o devuelve 'now' si no hay timestamp.
syslog_line_epoch_or_now(){
  local line="$1" mdhms year
  mdhms="$(grep -oE '^[A-Z][a-z]{2} +[0-9]{1,2} [0-9]{2}:[0-9]{2}:[0-9]{2}' <<<"$line" || true)"
  [[ -z "$mdhms" ]] && { date +%s; return; }
  year="$(date +%Y)"
  date -d "$mdhms $year" +%s 2>/dev/null || date +%s
}

monitor_loop(){
  local logsrc="$1" threshold="$2" window_min="$3"
  ensure_base
  [[ -r "$logsrc" ]] || die "No se puede leer $logsrc"

  local win=$((window_min*60))
  elog "Monitor iniciado: src=$logsrc threshold=$threshold window=${window_min}min patterns=/${MON_PATTERNS}/"
  log "MONITOR start src=$logsrc thr=$threshold win=${window_min}m"

  declare -a ERR_TIMES=()
  # -F para seguir; -n0 arranca sin leer historial
  tail -Fn0 "$logsrc" | while IFS= read -r line; do
    if [[ "$line" =~ $MON_PATTERNS ]]; then
      local t now
      t="$(syslog_line_epoch_or_now "$line")"
      now="$(date +%s)"
      ERR_TIMES+=("$t")
      # Filtra por ventana móvil
      local f=(); for e in "${ERR_TIMES[@]}"; do (( now - e <= win )) && f+=("$e"); done
      ERR_TIMES=("${f[@]}"); local c="${#ERR_TIMES[@]}"
      elog "Monitor: error detectado (count ventana=${c}) — $(printf '%.160s' "$line")"
      log  "MONITOR error count=${c} line=$(printf '%.120s' "$line")"

      if (( c>=threshold )); then
        local msg="Se detectaron ${c} errores en los últimos ${window_min} minutos. Acción: reinicio simulado."
        elog "$msg"; log "ALERT $msg"
        if (( DRYRUN )); then
          elog "[dry-run] systemctl restart servicio_simulado"
        else
          elog "[stub] Reinicio de servicio_simulado (simulado)"
        fi
        alert_notify "$msg"
        ERR_TIMES=()    # resetea contador tras alertar
      fi
    fi
  done
}

# ------------------------------ Demos didácticas -----------------------------
demo_lecturas(){
  echo "== Demo de read y select =="
  if read -r -t 5 -p "Confirma en 5s (s/N): " ans; then echo "Ingresaste: ${ans}"; else echo "Timeout sin respuesta."; fi
  read -r -s -p "Clave (oculta): " secret; echo; echo "Len clave: ${#secret}"
  read -r -n 1 -p "Pulsa una tecla (1 char): " k; echo; echo "Tecla: $k"
  PS3="Elige una fruta: "
  select fruta in Manzana Pera Uva "Volver"; do
    case "$REPLY" in
      1|2|3) echo "Elegiste: $fruta";;
      4) echo "Volver."; break;;
      *) echo "Opción inválida";;
    esac
  done
}

diag_tee(){
  echo "== Diagnóstico (tee + exit status) =="
  list_sources 2>&1 | tee -a "$LOG_FILE"
  local ec=$?
  elog "Exit code de list_sources = $ec"
}

# ------------------------------ Menú interactivo -----------------------------
menu_config_fuentes(){
  while true; do
    echo; echo "=== Fuentes a respaldar ==="
    list_sources || true
    echo; echo "1) Agregar ruta"; echo "2) Eliminar por número"; echo "3) Volver"
    read -r -p "Opción: " o || true
    case "$o" in
      1) read -r -p "Ruta (archivo o carpeta): " r || true; [[ -z "$r" ]] && { warn "Vacío."; continue; }; add_source "$r" ;;
      2) read -r -p "Número a eliminar: " n || true; remove_source_by_number "$n" || true ;;
      3) break ;;
      *) warn "Opción inválida" ;;
    esac
  done
}

select_destination_interactive(){
  echo "Seleccionar destino:"
  local a; a="$(autodetect_dest)"
  echo "1) Automático (detectado): ${a}"
  echo "2) Ingresar ruta manualmente"
  local opt; read -r -p "Elija [1/2]: " opt || true
  case "${opt}" in
    1) config_set_dest "$a"; elog "Destino: $a" ;;
    2) read -r -p "Ruta destino: " m || true; [[ -z "$m" ]] && { warn "Vacío. Conservo anterior."; return 1; }; config_set_dest "$m"; elog "Destino: $m" ;;
    *) warn "Opción inválida." ;;
  esac
}

menu_principal(){
  ensure_base
  while true; do
    echo
    echo "========== ${SCRIPT_NAME} =========="
    echo "1) Configurar FUENTES (agregar/quitar/listar)"
    echo "2) Seleccionar DESTINO"
    echo "3) Ejecutar respaldo incremental"
    echo "4) Ver estado del último respaldo"
    echo "5) Activar modo monitor (rápido)"
    echo "6) Demo de lecturas (read/select)"
    echo "7) Diagnóstico (tee + exit codes)"
    echo "8) Salir"
    read -r -p "Elija una opción: " opt || true
    case "$opt" in
      1) menu_config_fuentes ;;
      2) select_destination_interactive ;;
      3) backup_incremental ;;
      4) show_last_status ;;
      5) echo "Iniciando monitor (Ctrl+C para salir)..." ; monitor_loop "$MON_LOG" "$MON_THRESHOLD" "$MON_WINDOW_MIN" ;;
      6) demo_lecturas ;;
      7) diag_tee ;;
      8) echo "Saliendo." ; exit 0 ;;
      *) warn "Opción inválida." ;;
    esac
    read -r -p "Presione ENTER para continuar..." _ || true
  done
}

# ------------------------------- Parseo de args ------------------------------
parse_args(){
  while (( "$#" )); do
    case "$1" in
      --verbose) VERBOSE=1; shift ;;
      --dry-run) DRYRUN=1; shift ;;
      --force)   FORCE=1; shift ;;
      --monitor) MONITOR_MODE=1; shift ;;
      --log)     MON_LOG="${2:-}"; shift 2 ;;
      --threshold) MON_THRESHOLD="${2:-}"; shift 2 ;;
      --window)  MON_WINDOW_MIN="${2:-}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "Opción no reconocida: $1" ;;
    esac
  done
}

# ------------------------------------ MAIN -----------------------------------
main(){
  ensure_base
  load_conf
  parse_args "$@"
  if (( MONITOR_MODE )); then
    monitor_loop "$MON_LOG" "$MON_THRESHOLD" "$MON_WINDOW_MIN"
  else
    menu_principal
  fi
}

main "$@"
