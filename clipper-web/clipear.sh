#!/usr/bin/env bash
# Clipea tus directos en automático (audio + chat), los pasa a 9:16 con la
# cámara redondeada arriba y el juego abajo, los sube a tu Google Drive
# (carpeta "Content Scheduler/<canal>") y borra todo el material grabado del iMac.
#
#   ./clipear.sh https://kick.com/rdjavi https://twitch.tv/otrocanal
#   ./clipear.sh --servicio https://kick.com/rdjavi   # queda activo 24/7 en el Mac (LaunchAgent + caffeinate)
#   ./clipear.sh --parar                              # apaga el servicio 24/7
set -euo pipefail

cd "$(dirname "$0")"
RAIZ="$(pwd)"
ETIQUETA="com.contentscheduler.clipear"
PLIST="$HOME/Library/LaunchAgents/$ETIQUETA.plist"
LOG="$HOME/Library/Logs/clipear.log"

if [ "${1:-}" = "--parar" ]; then
  launchctl bootout "gui/$(id -u)/$ETIQUETA" 2>/dev/null || true
  rm -f "$PLIST"
  echo "✓ Servicio 24/7 detenido."
  exit 0
fi

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
mkdir -p "$HOME/.local/bin"

if ! command -v ffmpeg >/dev/null 2>&1 || ! command -v yt-dlp >/dev/null 2>&1; then
  echo "Instalando ffmpeg y yt-dlp precompilados para Mac con pip (5 segundos, sin Homebrew)…"
  [ -d "$HOME/.local/clipear-venv" ] || python3 -m venv "$HOME/.local/clipear-venv"
  "$HOME/.local/clipear-venv/bin/pip" install -q --upgrade imageio-ffmpeg yt-dlp
  FF_BIN="$("$HOME/.local/clipear-venv/bin/python" -c 'import imageio_ffmpeg;print(imageio_ffmpeg.get_ffmpeg_exe())')"
  ln -sf "$FF_BIN" "$HOME/.local/bin/ffmpeg"
  ln -sf "$HOME/.local/clipear-venv/bin/yt-dlp" "$HOME/.local/bin/yt-dlp"
fi

if [ ! -f drive/credenciales/usuario.json ]; then
  echo "=== Paso único: autorizar tu cuenta de Google Drive ==="
  python3 drive/autorizar.py
fi

if [ "${1:-}" = "--servicio" ]; then
  shift
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@" > directo/canales.txt
  fi
  mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$ETIQUETA</string>
  <key>WorkingDirectory</key><string>$RAIZ</string>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    <key>CAMARA</key><string>${CAMARA:-arriba-derecha}</string>
    <key>DRIVE_SUBIR</key><string>true</string>
    <key>DRIVE_BORRAR_LOCAL</key><string>true</string>
  </dict>
  <key>ProgramArguments</key><array>
    <string>/usr/bin/caffeinate</string>
    <string>-dimsu</string>
    <string>/usr/bin/env</string>
    <string>python3</string>
    <string>$RAIZ/directo/expres.py</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict></plist>
EOF
  launchctl bootout "gui/$(id -u)/$ETIQUETA" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  echo "✓ Servidor de clipping activo 24/7 en segundo plano (aunque cierres la Terminal)."
  echo "  • El iMac no se dormirá mientras esté activo (caffeinate)."
  echo "  • Si se cae o reinicias el Mac, arranca solo."
  echo "  • Panel local:  http://localhost:8090"
  echo "  • Ver registro: tail -f $LOG"
  echo "  • Pararlo:      ./clipear.sh --parar"
  exit 0
fi

export CAMARA="${CAMARA:-arriba-derecha}"
export DRIVE_SUBIR=true
export DRIVE_BORRAR_LOCAL=true

# caffeinate evita que el iMac se duerma mientras vigila y clipea
exec caffeinate -dimsu python3 directo/expres.py "$@"
