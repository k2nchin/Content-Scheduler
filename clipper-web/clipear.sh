#!/usr/bin/env bash
# Clipea tus directos en automático (audio + chat), los pasa a 9:16 con la
# cámara redondeada arriba y el juego abajo, los sube a tu Google Drive
# (carpeta "Content Scheduler/<canal>") y borra todo el material grabado del iMac.
#
#   ./clipear.sh https://kick.com/rdjavi https://twitch.tv/otrocanal
#   ./clipear.sh                 # usa los canales de directo/canales.txt
set -euo pipefail

cd "$(dirname "$0")"

for prog in ffmpeg yt-dlp; do
  if ! command -v "$prog" >/dev/null 2>&1; then
    echo "Instalando $prog con Homebrew…"
    brew install "$prog"
  fi
done

if [ ! -f drive/credenciales/usuario.json ]; then
  echo "=== Paso único: autorizar tu cuenta de Google Drive ==="
  python3 drive/autorizar.py
fi

export CAMARA="${CAMARA:-arriba-derecha}"
export DRIVE_SUBIR=true
export DRIVE_BORRAR_LOCAL=true

exec python3 directo/expres.py "$@"
