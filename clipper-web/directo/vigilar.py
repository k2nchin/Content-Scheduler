"""Vigila varios canales y graba solo los que entran en directo, todos a la vez.

Cada pocos minutos mira si alguno de tus canales está en vivo. Cuando uno
empieza, lanza su grabación por trozos (grabar.py) y cada trozo se manda a
clipear. Cuando el directo acaba, vuelve a vigilar ese canal.

Usa solo canales tuyos o de creadores que te den permiso: bajar directos de
otros sin permiso va contra las normas de YouTube, Twitch y Kick.

Canales: uno por línea en canales.txt (o en la variable CANALES, separados por
comas). Valen enlaces de canal:
  https://www.youtube.com/@tucanal
  https://www.twitch.tv/tucanal
  https://kick.com/tucanal

Variables:
  CLIP_API_URL, CLIP_API_KEY   como en grabar.py
  CANALES                      lista separada por comas (si no, canales.txt)
  ARCHIVO_CANALES              ruta del archivo (por defecto /app/canales.txt)
  MAX_DIRECTOS                 cuántos graba a la vez (por defecto 3)
  MINUTOS_ENTRE_REVISIONES     cada cuánto mira si están en vivo (por defecto 2)
"""

from __future__ import annotations

import logging
import os
import subprocess
import threading
import time
from pathlib import Path

import grabar

logging.basicConfig(level=logging.INFO, format="%(asctime)s  %(levelname)s  [%(threadName)s] %(message)s",
                    datefmt="%H:%M:%S")
log = logging.getLogger("vigilar")

MAX_DIRECTOS = max(1, int(os.getenv("MAX_DIRECTOS", "3")))
ESPERA = max(1, int(os.getenv("MINUTOS_ENTRE_REVISIONES", "2"))) * 60
ARCHIVO = Path(os.getenv("ARCHIVO_CANALES", "/app/canales.txt"))


def canales() -> list[str]:
    """Se relee en cada vuelta: puedes añadir o quitar canales sin reiniciar."""
    texto = os.getenv("CANALES", "")
    if not texto and ARCHIVO.exists():
        texto = ARCHIVO.read_text(encoding="utf-8")
    lista = [c.strip() for c in texto.replace(",", "\n").splitlines()]
    return [c for c in lista if c and not c.startswith("#")]


def enlace_directo(canal: str) -> str:
    """En YouTube el directo de un canal está en /live; Twitch y Kick ya lo son."""
    c = canal.rstrip("/")
    if ("youtube.com/@" in c or "youtube.com/channel/" in c or "youtube.com/c/" in c) and not c.endswith("/live"):
        return c + "/live"
    return c


def en_vivo(enlace: str) -> bool:
    """Pregunta a yt-dlp si ahora mismo hay directo, sin bajar nada."""
    try:
        r = subprocess.run(["yt-dlp", "--quiet", "--no-warnings", "--skip-download",
                            "--print", "%(is_live)s", enlace],
                           capture_output=True, text=True, timeout=60)
    except subprocess.TimeoutExpired:
        return False
    return r.returncode == 0 and "True" in r.stdout


def main() -> int:
    if not grabar.CLAVE:
        log.error("Falta CLIP_API_KEY. Sácala con ./scripts/clave-para-el-iphone.sh")
        return 1
    grabando: dict[str, threading.Thread] = {}
    log.info("Vigilando canales (hasta %d directos a la vez, revisión cada %d min)", MAX_DIRECTOS, ESPERA // 60)
    while True:
        grabando = {c: h for c, h in grabando.items() if h.is_alive()}
        lista = canales()
        if not lista:
            log.warning("No hay canales. Ponlos en %s o en CANALES.", ARCHIVO)
        for canal in lista:
            if canal in grabando:
                continue
            if len(grabando) >= MAX_DIRECTOS:
                log.info("Ya hay %d directos grabándose; el resto espera.", len(grabando))
                break
            enlace = enlace_directo(canal)
            if en_vivo(enlace):
                log.info("¡%s está en vivo! Empiezo a grabar.", canal)
                hilo = threading.Thread(target=grabar.grabar, args=(enlace,), name=canal.rstrip("/").rsplit("/", 1)[-1][:30],
                                        daemon=True)
                hilo.start()
                grabando[canal] = hilo
        time.sleep(ESPERA)


if __name__ == "__main__":
    raise SystemExit(main())
