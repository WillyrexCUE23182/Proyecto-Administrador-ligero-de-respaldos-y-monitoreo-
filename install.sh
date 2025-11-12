#!/usr/bin/env bash
# =============================================================================
# install.sh — Instalador de backuptool.sh
# Autor: Willy Cuellar 23182
# Descripción:
#   Instala el sistema de respaldos y monitoreo backuptool:
#     - Verifica dependencias.
#     - Instala en ~/bin o en /usr/local/bin (modo global con sudo).
#     - Añade alias y funciones a ~/.bashrc.
#     - (Opcional) instala un servicio systemd para monitoreo continuo.
#     - Permite desinstalación completa.
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_SRC="$(cd "$(dirname "$0")" && pwd)/backuptool.sh"
USER_BIN="${HOME}/bin"
GLOBAL_BIN="/usr/local/bin"
BASHRC="${HOME}/.bashrc"
SERVICE_NAME="backuptool-monitor.service"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
ALIAS_NAME="btool"

# --------------------------- Funciones auxiliares ----------------------------
msg()  { printf "\033[1;32m[INFO]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
err()  { printf "\033[1;31m[ERR]\033[0m %s\n" "$*" >&2; exit 1; }

require_cmd(){ command -v "$1" >/dev/null 2>&1 || err "Falta dependencia: $1"; }

backup_file(){
  local f="$1"
  [[ -f "$f" ]] && cp -a "$f" "${f}.bak_$(date +%Y%m%d_%H%M%S)" && msg "Respaldo de $f creado."
}

# ----------------------------- Verificación ----------------------------------
check_deps(){
  msg "Verificando dependencias..."
  for dep in bash rsync curl systemctl; do
    require_cmd "$dep"
  done
}

# ------------------------------ Instalación ----------------------------------
install_binary(){
  local mode="$1"
  if [[ "$mode" == "global" ]]; then
    msg "Instalando globalmente en ${GLOBAL_BIN} (requiere sudo)..."
    sudo mkdir -p "$GLOBAL_BIN"
    sudo cp -f "$SCRIPT_SRC" "$GLOBAL_BIN/backuptool"
    sudo chmod 755 "$GLOBAL_BIN/backuptool"
    msg "Instalado: /usr/local/bin/backuptool"
  else
    msg "Instalando en el entorno del usuario..."
    mkdir -p "$USER_BIN"
    cp -f "$SCRIPT_SRC" "$USER_BIN/backuptool"
    chmod 755 "$USER_BIN/backuptool"
    msg "Instalado: ${USER_BIN}/backuptool"
  fi
}

add_alias(){
  msg "Configurando alias en ${BASHRC}..."
  backup_file "$BASHRC"
  grep -q "$ALIAS_NAME" "$BASHRC" 2>/dev/null && { warn "Alias ya existe, omitido."; return; }

  cat >>"$BASHRC" <<EOF

# --- backuptool aliases (instalado por install.sh) ---
alias ${ALIAS_NAME}="backuptool"
backup-monitor(){
  backuptool --monitor --log ~/backup-admin/samples/syslog.sample --dry-run --verbose
}
# --- fin backuptool aliases ---
EOF

  msg "Alias '${ALIAS_NAME}' añadido. Usa: ${ALIAS_NAME} --help"
}

reload_shell(){
  msg "Recargando entorno actual..."
  # shellcheck source=/dev/null
  source "$BASHRC" || warn "No se pudo recargar automáticamente, abre nueva terminal."
}

# ---------------------------- Servicio systemd -------------------------------
create_systemd_service(){
  msg "Creando servicio systemd: ${SERVICE_NAME}"
  local user_home="$HOME"
  local sample_log="${user_home}/backup-admin/samples/syslog.sample"

  cat <<EOF | sudo tee "$SERVICE_FILE" >/dev/null
[Unit]
Description=Monitor automático de logs con backuptool
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/backuptool --monitor --log ${sample_log} --force
Restart=always
RestartSec=10
User=${USER}
WorkingDirectory=${user_home}

[Install]
WantedBy=multi-user.target
EOF

  sudo systemctl daemon-reload
  sudo systemctl enable "$SERVICE_NAME"
  sudo systemctl start "$SERVICE_NAME"
  msg "Servicio ${SERVICE_NAME} instalado y en ejecución."
  msg "Verifica estado con: sudo systemctl status ${SERVICE_NAME}"
}

remove_systemd_service(){
  if [[ -f "$SERVICE_FILE" ]]; then
    msg "Eliminando servicio systemd..."
    sudo systemctl stop "$SERVICE_NAME" || true
    sudo systemctl disable "$SERVICE_NAME" || true
    sudo rm -f "$SERVICE_FILE"
    sudo systemctl daemon-reload
    msg "Servicio eliminado."
  else
    warn "No se encontró servicio systemd instalado."
  fi
}

# ----------------------------- Desinstalación --------------------------------
uninstall(){
  msg "Desinstalando backuptool..."
  rm -f "${USER_BIN}/backuptool"
  sudo rm -f "${GLOBAL_BIN}/backuptool" 2>/dev/null || true
  sed -i '/# --- backuptool aliases/,/# --- fin backuptool aliases ---/d' "$BASHRC"
  remove_systemd_service
  msg "Desinstalación completa. Reinicia la terminal para limpiar entorno."
}

# ------------------------------- Menú CLI ------------------------------------
case "${1:-}" in
  install)
    check_deps
    if [[ "${2:-}" == "--global" ]]; then
      install_binary "global"
    else
      install_binary "user"
    fi
    add_alias
    reload_shell
    msg "Instalación completada. Ejecuta 'btool' o 'backuptool' para comenzar."
    ;;
  service)
    create_systemd_service
    ;;
  uninstall)
    uninstall
    ;;
  *)
    echo "Uso: $0 [install [--global] | service | uninstall]"
    echo
    echo "  install        → Instala localmente (en ~/bin)"
    echo "  install --global → Instala globalmente (en /usr/local/bin, requiere sudo)"
    echo "  service        → Instala servicio systemd (modo monitor automático)"
    echo "  uninstall      → Elimina todo (ejecutable, alias, servicio)"
    ;;
esac
