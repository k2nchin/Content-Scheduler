#!/usr/bin/env bash
# Clipea tus directos en automático (audio + chat), los pasa a 9:16 con la
# cámara redondeada arriba y el juego abajo, los sube a tu Google Drive
# (carpeta "Content Scheduler/<canal>") y borra todo el material grabado del iMac.
#
#   ./clipear.sh https://kick.com/rdjavi
#   ./clipear.sh --servicio https://kick.com/rdjavi
#   ./clipear.sh --parar
set -euo pipefail

cd "$(dirname "$0")"
RAIZ="$(pwd)"
LOG="$HOME/Library/Logs/clipear.log"
PIDFILE="$HOME/.local/clipear.pid"

if [ "${1:-}" = "--parar" ]; then
  launchctl bootout "gui/$(id -u)/com.contentscheduler.clipear" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/com.contentscheduler.clipear.plist"
  if [ -f "$PIDFILE" ]; then
    kill "$(cat "$PIDFILE")" 2>/dev/null || true
    rm -f "$PIDFILE"
  fi
  pkill -f "directo/expres.py" 2>/dev/null || true
  echo "✓ Servidor 24/7 detenido."
  exit 0
fi

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
mkdir -p "$HOME/.local/bin" "$HOME/Library/Logs"

if ! command -v ffmpeg >/dev/null 2>&1 || ! command -v yt-dlp >/dev/null 2>&1; then
  echo "Instalando ffmpeg y yt-dlp precompilados para Mac con pip (5 segundos, sin Homebrew)…"
  [ -d "$HOME/.local/clipear-venv" ] || python3 -m venv "$HOME/.local/clipear-venv"
  "$HOME/.local/clipear-venv/bin/pip" install -q --upgrade imageio-ffmpeg yt-dlp
  FF_BIN="$("$HOME/.local/clipear-venv/bin/python" -c 'import imageio_ffmpeg;print(imageio_ffmpeg.get_ffmpeg_exe())')"
  ln -sf "$FF_BIN" "$HOME/.local/bin/ffmpeg"
  ln -sf "$HOME/.local/clipear-venv/bin/yt-dlp" "$HOME/.local/bin/yt-dlp"
fi

export CAMARA="${CAMARA:-arriba-derecha}"
export DRIVE_SUBIR=true
export DRIVE_BORRAR_LOCAL=true

if [ "${1:-}" = "--servicio" ]; then
  shift
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@" > directo/canales.txt
  fi
  # Quitar LaunchAgent viejo (macOS TCC bloquea ~/Desktop en LaunchAgents)
  launchctl bootout "gui/$(id -u)/com.contentscheduler.clipear" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/com.contentscheduler.clipear.plist"
  pkill -f "directo/expres.py" 2>/dev/null || true

  # Bucle en segundo plano con nohup + caffeinate (hereda el permiso de Terminal sobre ~/Desktop)
  nohup /usr/bin/caffeinate -dimsu bash -c '
    while true; do
      python3 "'"$RAIZ"'/directo/expres.py" >> "'"$LOG"'" 2>&1 || true
      sleep 2
    done
  ' >/dev/null 2>&1 &
  echo $! > "$PIDFILE"

  for _ in $(seq 1 15); do
    if curl -fsS http://127.0.0.1:8090/api/estado >/dev/null 2>&1; then break; fi
    sleep 1
  done

  echo "✓ Servidor de clipping activo 24/7 en segundo plano."
  echo "  • Panel local:  http://localhost:8090"
  echo "  • Ver registro: tail -f $LOG"
  echo "  • Pararlo:      ./clipear.sh --parar"
  open "http://localhost:8090" 2>/dev/null || true
  exit 0
fi

exec caffeinate -dimsu python3 directo/expres.py "$@"
