"""El agente que deja al iMac grabar directos pedidos desde el móvil.

Corre siempre junto al motor. Cada pocos segundos pregunta si hay un directo
pedido; cuando lo hay, lo graba por trozos y los va mandando a clipear. Mientras
graba avisa de que sigue vivo, y esa misma respuesta le dice si desde el móvil
han pedido parar.

Si el agente se cae a mitad de una grabación, el directo queda sin señales de
vida y a los dos minutos otro agente (o este al reiniciarse) lo vuelve a coger.

Variables:
  CLIP_API_URL   dónde está el motor (por defecto http://backend:8000)
  CLIP_API_KEY   la clave sk_… del dueño (obligatoria)
  AGENTE_ID      nombre de este agente; por defecto el del contenedor
"""

from __future__ import annotations

import logging
import os
import socket
import time

import requests

import grabar

logging.basicConfig(level=logging.INFO, format="%(asctime)s  %(levelname)s  %(message)s", datefmt="%H:%M:%S")
log = logging.getLogger("agente")

API = os.getenv("CLIP_API_URL", "http://backend:8000").rstrip("/")
CLAVE = os.getenv("CLIP_API_KEY", "").strip()
AGENTE = (os.getenv("AGENTE_ID") or socket.gethostname())[:64]
# Cada cuánto se pregunta si hay algo que grabar.
ESPERA = max(5, int(os.getenv("SEGUNDOS_ENTRE_CONSULTAS", "15")))
# Cada cuánto se avisa de que seguimos vivos mientras grabamos. El motor da por
# muerto a un agente a los dos minutos, así que esto va muy por debajo.
LATIDO = 20

CABECERAS = {"Authorization": f"Bearer {CLAVE}"}


def coger() -> dict | None:
    """Pide el siguiente directo pendiente. Devuelve None si no hay ninguno."""
    r = requests.post(f"{API}/lives/agent/claim", headers=CABECERAS,
                      json={"agent_id": AGENTE}, timeout=30)
    r.raise_for_status()
    return (r.json() or {}).get("live")


def grabar_directo(live: dict) -> None:
    live_id = live["id"]
    log.info("Cogido el directo %s: %s", live_id, live["url"])
    ultimo = 0.0
    parar = False

    def debe_parar(trozos: int) -> bool:
        """Avisa de que seguimos vivos y mira si han pedido parar."""
        nonlocal ultimo, parar
        if time.monotonic() - ultimo < LATIDO:
            return parar
        ultimo = time.monotonic()
        try:
            r = requests.post(f"{API}/lives/{live_id}/agent/heartbeat", headers=CABECERAS,
                              json={"agent_id": AGENTE, "chunks_sent": trozos}, timeout=30)
            if r.status_code == 404:
                # Lo borraron: no tiene sentido seguir grabando.
                parar = True
            elif r.ok:
                parar = (r.json() or {}).get("status") in {"parando", "terminado", "error"}
        except requests.RequestException as e:
            # Un corte de red no tira la grabación: se sigue y se reintenta.
            log.warning("No pude avisar de que sigo vivo: %s", e)
        return parar

    fallo = None
    try:
        grabar.grabar(
            live["url"],
            minutos=int(live.get("chunk_minutes") or 10),
            opciones=live.get("options") or {},
            debe_parar=debe_parar,
        )
    except Exception as e:  # el agente nunca se muere por un directo
        fallo = f"{type(e).__name__}: {e}"[:2000]
        log.exception("El directo %s falló", live_id)
    try:
        requests.post(f"{API}/lives/{live_id}/agent/finish", headers=CABECERAS,
                      json={"agent_id": AGENTE, "error": fallo}, timeout=30)
    except requests.RequestException as e:
        # Sin este aviso el directo se queda sin latidos y otro agente lo recoge.
        log.warning("No pude cerrar el directo %s: %s", live_id, e)
    log.info("Directo %s cerrado%s", live_id, f" con error: {fallo}" if fallo else "")


def main() -> int:
    if not CLAVE:
        log.error("Falta CLIP_API_KEY. Sácala con ./scripts/clave-para-el-iphone.sh")
        return 1
    log.info("Agente %s esperando directos en %s", AGENTE, API)
    while True:
        try:
            live = coger()
        except requests.RequestException as e:
            # El motor puede estar arrancando todavía.
            log.warning("El motor no contesta: %s", e)
            live = None
        if live is None:
            time.sleep(ESPERA)
            continue
        grabar_directo(live)


if __name__ == "__main__":
    raise SystemExit(main())
