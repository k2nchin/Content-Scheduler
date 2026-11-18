#!/usr/bin/env bash
# Saca el motor a internet con una dirección fija, por Tailscale.
#
#   cd clipper-web && ./scripts/tailscale.sh
#
# El túnel rápido de Cloudflare cambia de dirección cada vez que se reabre, y
# hay que ir cambiándola en el iPhone. Esto da una dirección que no cambia
# nunca, con certificado de verdad, sin dominio propio y sin abrir ningún
# puerto del router: solo tus aparatos pueden entrar.
#
# Para quitarlo:  ./scripts/tailscale.sh --quitar
set -euo pipefail

cd "$(dirname "$0")/.."
DIRECCION="$HOME/Content-Scheduler-direccion.txt"
TS="/Applications/Tailscale.app/Contents/MacOS/Tailscale"

say() { printf '\n\033[1m%s\033[0m\n' "$1"; }
bad() { printf '\033[31m%s\033[0m\n' "$1" >&2; }
ok()  { printf '\033[32m  ✓ %s\033[0m\n' "$1"; }

[ "$(uname)" = "Darwin" ] || { bad "Esto es solo para macOS."; exit 1; }

# La app de la Mac App Store no trae el comando; la de su web sí.
if [ ! -x "$TS" ]; then
  if command -v tailscale >/dev/null 2>&1; then
    TS="$(command -v tailscale)"
  else
    bad "No encuentro Tailscale."
    echo "   Instálalo con:  brew install --cask tailscale"
    echo "   o bájalo de:    https://tailscale.com/download/mac"
    echo "   Ábrelo una vez, entra con tu cuenta, y vuelve a correr esto."
    exit 1
  fi
fi

if [ "${1:-}" = "--quitar" ]; then
  "$TS" serve --https=443 off 2>/dev/null || true
  say "Quitado. El motor ya no sale por Tailscale."
  echo "Tus aparatos siguen conectados entre sí; para salir del todo: $TS logout"
  exit 0
fi

# ─────────────────────────── Que esté conectado

if ! "$TS" status >/dev/null 2>&1; then
  say "Conectando con tu cuenta de Tailscale…"
  echo "Se abrirá el navegador. Entra con Google, GitHub o lo que uses."
  "$TS" up
fi
ok "Tailscale conectado"

# ─────────────────────────── Que el motor esté encendido

if ! curl -fsS --max-time 5 http://localhost:8000/docs >/dev/null 2>&1; then
  bad "El motor no está encendido. Levántalo primero:  docker compose up -d"
  exit 1
fi
ok "El motor responde"

# ─────────────────────────── Sacarlo con https

say "Dando la dirección fija al motor…"
# --bg lo deja puesto para siempre: sobrevive a reinicios sin dejar ventanas.
if ! "$TS" serve --bg --https=443 http://127.0.0.1:8000 2>/tmp/ts-serve.err; then
  bad "No se pudo. Lo que dijo Tailscale:"
  sed 's/^/   /' /tmp/ts-serve.err >&2
  echo
  echo "Casi siempre es esto: falta encender MagicDNS y HTTPS en tu cuenta."
  echo "   1. Entra en https://login.tailscale.com/admin/dns"
  echo "   2. Enciende «MagicDNS»"
  echo "   3. En «HTTPS Certificates», dale a «Enable HTTPS»"
  echo "   4. Vuelve a correr este script"
  exit 1
fi

URL="$("$TS" serve status --json 2>/dev/null \
  | sed -n 's/.*"\(https:\/\/[a-z0-9.-]*\.ts\.net\)[":].*/\1/p' | head -1)"
if [ -z "$URL" ]; then
  NOMBRE="$("$TS" status --json | sed -n 's/.*"DNSName" *: *"\([^"]*\)".*/\1/p' | head -1)"
  URL="https://${NOMBRE%.}"
fi

printf '%s\n' "$URL" > "$DIRECCION"
ok "Listo"

cat <<FIN

   $(printf '\033[1;35m%s\033[0m' "$URL")

Esa dirección NO cambia nunca. Ponla en el iPhone (Ajustes → Servidor del
motor) y en la app de Windows o del Mac, y olvídate.

Dos cosas que conviene saber:

  · Solo entran tus aparatos. Aunque alguien adivine la dirección, sin estar
    en tu cuenta de Tailscale no llega. El túnel de Cloudflare, en cambio,
    lo abría a cualquiera que supiera la dirección.

  · En el iPhone hace falta la app de Tailscale, con la misma cuenta. Una vez
    puesta, se conecta sola.

Guardada también en:  $DIRECCION
Para quitarlo:        ./scripts/tailscale.sh --quitar
FIN
