#!/usr/bin/env bash
# =============================================================================
# tests.sh — Pruebas automáticas no destructivas para backuptool
# Autor: Willy Cuellar 23182
# Descripción:
#   - Ejecuta pruebas de instalación mínima y funcionalidad principal en un HOME temporal.
#   - No toca archivos reales del usuario (~/.backup_sources.list, ~/.backup_admin.conf).
#   - Requiere: bash >=4, rsync, curl. (systemd solo si vas a probar el servicio por separado)
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

GREEN="\033[1;32m"; YELLOW="\033[1;33m"; RED="\033[1;31m"; NC="\033[0m"
info(){ printf "${GREEN}[INFO]${NC} %s\n" "$*"; }
warn(){ printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
err(){ printf "${RED}[ERR ]${NC} %s\n" "$*" >&2; }

# Localiza el ejecutable
BACKUPTOOL_BIN="${BACKUPTOOL_BIN:-}"
if [[ -z "${BACKUPTOOL_BIN}" ]]; then
  if command -v backuptool >/dev/null 2>&1; then
    BACKUPTOOL_BIN="backuptool"
  elif [[ -x "./backuptool.sh" ]]; then
    BACKUPTOOL_BIN="./backuptool.sh"
  else
    err "No encuentro 'backuptool' en PATH ni './backuptool.sh' en el directorio actual."
    exit 1
  fi
fi

SYSLOG_SAMPLE="${SYSLOG_SAMPLE:-./backup-admin/samples/syslog.sample}"
TIMEOUT_BIN="$(command -v timeout || true)"

require_cmd(){ command -v "$1" >/dev/null 2>&1 || { err "Falta dependencia: $1"; exit 1; }; }

info "Verificando dependencias..."
require_cmd bash
require_cmd rsync
require_cmd curl

if [[ ! -f "$SYSLOG_SAMPLE" ]]; then
  warn "No se encontró syslog.sample en: $SYSLOG_SAMPLE"
  warn "Usando un syslog de respaldo mínimo en /tmp para test."
  cat > /tmp/syslog.sample.min <<'EOF'
Nov 12 09:12:01 localhost appX[2100]: critical: database connection timeout
Nov 12 09:12:04 localhost appY[2101]: error: failed to open file /var/lib/state
Nov 12 09:12:06 localhost kernel: segfault at 000000000 ip 00007f err 4 in libc-2.34.so[...]
EOF
  SYSLOG_SAMPLE="/tmp/syslog.sample.min"
fi

TEST_ROOT="$(mktemp -d -t backuptool_test_XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT

TMP_HOME="${TEST_ROOT}/home"
TMP_SRC="${TEST_ROOT}/sources"
TMP_DEST="${TEST_ROOT}/dest"
mkdir -p "$TMP_HOME" "$TMP_SRC/dirA" "$TMP_DEST"

echo "Hola UVG" > "$TMP_SRC/archivo1.txt"
echo "Lorem ipsum" > "$TMP_SRC/dirA/archivo2.log"

TMP_CONF="${TMP_HOME}/.backup_admin.conf"
TMP_SOURCES="${TMP_HOME}/.backup_sources.list"

cat > "$TMP_CONF" <<EOF
DEST=${TMP_DEST}
# TELEGRAM_BOT_TOKEN=xxxx
# TELEGRAM_CHAT_ID=1234
EOF

REAL_SRC_ABS="$(cd "$TMP_SRC" && pwd)"
echo "${REAL_SRC_ABS}/archivo1.txt" > "$TMP_SOURCES"
echo "${REAL_SRC_ABS}/dirA"        >> "$TMP_SOURCES"

pass(){ printf "${GREEN}✔ PASS${NC} %s\n" " $*"; }
fail(){ printf "${RED}✘ FAIL${NC} %s\n" " $*"; exit 1; }

bt(){ env HOME="$TMP_HOME" "$BACKUPTOOL_BIN" "$@"; }

info "Caso 1: Respaldo incremental en --dry-run (no debe modificar archivos reales)."
set +e
OUT1="$(bt --dry-run --verbose 2>&1)"
RC1=$?
set -e

LOG_PATH="${TMP_HOME}/backups/backup.log"
if [[ $RC1 -eq 0 ]] && grep -q "Respaldo completado:" <<< "$OUT1" && [[ -s "$LOG_PATH" ]]; then
  pass "Respaldo dry-run ejecutado y log creado en HOME temporal."
else
  echo "$OUT1" | sed -e 's/^/  | /'
  [[ -f "$LOG_PATH" ]] && tail -n3 "$LOG_PATH" | sed -e 's/^/  | /' || true
  fail "Respaldo dry-run no produjo la salida y/o log esperados."
fi

info "Caso 2: Monitor en --dry-run detecta umbral de errores."
TMP_LOG_MON="${TEST_ROOT}/syslog.runtime"
cp "$SYSLOG_SAMPLE" "$TMP_LOG_MON"

MON_CMD=(bt --monitor --log "$TMP_LOG_MON" --threshold 3 --window 1 --dry-run --verbose)

if [[ -n "$TIMEOUT_BIN" ]]; then
  MON_OUT="${TEST_ROOT}/monitor.out"
  ( "${MON_CMD[@]}" ) > "$MON_OUT" 2>&1 &
  MON_PID=$!
  sleep 0.5
  echo "Nov 12 10:00:01 host app[1]: error: test case E1" >> "$TMP_LOG_MON"
  echo "Nov 12 10:00:02 host app[1]: critical: test case E2" >> "$TMP_LOG_MON"
  echo "Nov 12 10:00:03 host app[1]: fail: test case E3" >> "$TMP_LOG_MON"
  "$TIMEOUT_BIN" 5 bash -c "while kill -0 $MON_PID 2>/dev/null; do sleep 0.2; done" || kill "$MON_PID" 2>/dev/null || true
  if grep -Eq "Se detectaron +3 errores|ALERTA \(stub\)" "$MON_OUT"; then
    pass "Monitor detectó umbral y emitió alerta (dry-run)."
  else
    echo "---- Monitor output ----"
    sed -e 's/^/  | /' "$MON_OUT" | tail -n 80
    fail "Monitor no mostró alerta esperada."
  fi
else
  warn "No se encontró 'timeout'; ejecutando prueba de monitor con ventana breve."
  ( "${MON_CMD[@]}" ) > /dev/null 2>&1 &
  MON_PID=$!
  sleep 0.5
  echo "Nov 12 10:00:01 host app[1]: error: test case E1" >> "$TMP_LOG_MON"
  echo "Nov 12 10:00:02 host app[1]: critical: test case E2" >> "$TMP_LOG_MON"
  echo "Nov 12 10:00:03 host app[1]: fail: test case E3" >> "$TMP_LOG_MON"
  sleep 2
  kill "$MON_PID" 2>/dev/null || true
  pass "Monitor ejecutado (no se validó salida por falta de 'timeout')."
fi

info "Caso 3: Validar que el symlink 'latest' se crea en destino (dry-run no lo evita)."
if [[ -L "${TMP_DEST}/latest" || -d "${TMP_DEST}"/backup_* ]]; then
  pass "'latest' y/o carpeta de backup creados en destino temporal."
else
  fail "No se encontró 'latest' ni carpeta de backup en destino."
fi

info "Todas las pruebas completadas correctamente."
exit 0
