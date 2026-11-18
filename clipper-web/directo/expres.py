#!/usr/bin/env python3
"""Directo exprés: clips de tus directos en segundos, en tu Mac.

No espera a que se cierre un trozo de 10 minutos. Mantiene siempre los últimos
3 minutos del directo en trozos de 2 s; cuando el chat explota (o pulsas Enter)
junta los últimos segundos sin recodificar (< 1 s) y saca la versión 9:16 con el
codificador por hardware del Mac (VideoToolbox), en unos segundos.

Usa solo canales tuyos o de creadores que te den permiso.

Instalar (una vez):
    brew install ffmpeg yt-dlp

Usar:
    python3 expres.py https://www.twitch.tv/tucanal https://www.youtube.com/@tucanal
    python3 expres.py            # usa los canales de canales.txt

Mientras corre:  Enter = clip ahora en todos los canales;  nombre + Enter = solo ese.

Chat (para clipear solo):
    Twitch   funciona sin configurar nada.
    YouTube  necesita YOUTUBE_API_KEY (Google Cloud → YouTube Data API v3 → clave de API).
    Kick     no tiene API de chat pública: solo clip manual con Enter.

Variables (todas opcionales):
    CARPETA_CLIPS        dónde guardar (por defecto ~/Desktop/Clips exprés).
                         Pon una carpeta de iCloud Drive y te llegan solos al iPhone.
    DURACION_CLIP        segundos por clip (45)
    SEGUNDOS_DESPUES     cuánto sigue grabando después del pico antes de cortar (8)
    ESPERA_ENTRE_CLIPS   mínimo entre dos clips del mismo canal (40)
    FACTOR_PICO          cuántas veces más rápido que lo normal tiene que ir el chat (3)
    MIN_MENSAJES_SEG     ritmo mínimo para contar como pico (1.0 mensajes/s)
    VERTICAL             0 para sacar solo el clip horizontal (aún más rápido)
    ALTURA_MAXIMA        calidad que se baja del directo (720)
"""

from __future__ import annotations

import calendar
import collections
import json
import os
import random
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import urllib.request
from pathlib import Path

SEG = 2
BUFFER = int(os.getenv("BUFFER_SEGUNDOS", "180"))
DURACION = int(os.getenv("DURACION_CLIP", "45"))
DESPUES = int(os.getenv("SEGUNDOS_DESPUES", "8"))
ESPERA_CLIPS = int(os.getenv("ESPERA_ENTRE_CLIPS", "40"))
FACTOR = float(os.getenv("FACTOR_PICO", "3"))
MINIMO = float(os.getenv("MIN_MENSAJES_SEG", "1.0"))
VERTICAL = os.getenv("VERTICAL", "1") != "0"
ALTURA = os.getenv("ALTURA_MAXIMA", "720")
YT_KEY = os.getenv("YOUTUBE_API_KEY", "").strip()
SALIDA = Path(os.getenv("CARPETA_CLIPS", str(Path.home() / "Desktop" / "Clips exprés"))).expanduser()
CANALES_TXT = Path(__file__).with_name("canales.txt")

# Palabras que delatan un momento: risas, sorpresa, alguien pidiendo clip.
PALABRAS = re.compile(r"\b(clip+|clipp?ea+|ja(ja)+|js(js)+|lol+|kekw|omg|lmao+|pog+\w*|wtf|xd+|noo+)\b", re.I)

if sys.platform == "darwin":
    CODIFICADOR = ["-c:v", "h264_videotoolbox", "-b:v", "6M"]
else:
    CODIFICADOR = ["-c:v", "libx264", "-preset", "veryfast", "-crf", "21"]

manuales: dict[str, threading.Event] = {}


def log(canal: str, msg: str) -> None:
    print(time.strftime("%H:%M:%S"), f"[{canal}]", msg, flush=True)


# ── Canales ──────────────────────────────────────────────────────────────────

def nombre_de(canal: str) -> str:
    partes = [p for p in canal.rstrip("/").split("/") if p and p != "live"]
    return re.sub(r"[^\w.-]", "", partes[-1].lstrip("@"))[:30] or "canal"


def enlace_directo(canal: str) -> str:
    c = canal.rstrip("/")
    if "youtube.com/" in c and "watch" not in c and not c.endswith("/live"):
        return c + "/live"
    return c


def en_vivo(enlace: str) -> bool:
    try:
        r = subprocess.run(["yt-dlp", "--quiet", "--no-warnings", "--skip-download", "--print", "%(is_live)s", enlace],
                           capture_output=True, text=True, timeout=60)
    except subprocess.TimeoutExpired:
        return False
    return r.returncode == 0 and "True" in r.stdout


# ── Grabación en anillo ──────────────────────────────────────────────────────

class Grabador:
    """Graba el directo en trozos de 2 s y solo guarda los últimos BUFFER segundos."""

    def __init__(self, enlace: str, nombre: str):
        self.enlace = enlace
        self.dir = Path(tempfile.mkdtemp(prefix=f"expres-{nombre}-"))

    def empezar(self) -> None:
        self.bajada = subprocess.Popen(
            ["yt-dlp", "--quiet", "--no-warnings", "--no-part",
             "-f", f"b[height<={ALTURA}]/bv*[height<={ALTURA}]+ba/b", "-o", "-", self.enlace],
            stdout=subprocess.PIPE)
        self.corte = subprocess.Popen(
            ["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", "pipe:0", "-c", "copy",
             "-f", "segment", "-segment_time", str(SEG), "-segment_wrap", str(BUFFER // SEG + 5),
             "-segment_format", "mpegts", str(self.dir / "s%04d.ts")],
            stdin=self.bajada.stdout)
        if self.bajada.stdout:
            self.bajada.stdout.close()

    def vivo(self) -> bool:
        return self.corte.poll() is None

    def ultimos(self, segundos: int) -> list[Path]:
        """Los trozos de los últimos `segundos`, en orden. El que se escribe ahora no entra."""
        trozos = sorted(self.dir.glob("s*.ts"), key=lambda p: p.stat().st_mtime)[:-1]
        if not trozos:
            return []
        fin = trozos[-1].stat().st_mtime
        return [t for t in trozos if t.stat().st_mtime > fin - segundos]

    def parar(self) -> None:
        for p in (self.bajada, self.corte):
            if p.poll() is None:
                p.terminate()
                try:
                    p.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    p.kill()

    def limpiar(self) -> None:
        shutil.rmtree(self.dir, ignore_errors=True)


def ffmpeg(*args: str) -> bool:
    return subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *args]).returncode == 0


def cortar(g: Grabador, canal: str, motivo: str) -> None:
    inicio = time.monotonic()
    trozos = g.ultimos(DURACION)
    if not trozos:
        log(canal, "Todavía no hay video grabado para clipear.")
        return
    destino = SALIDA / canal
    destino.mkdir(parents=True, exist_ok=True)
    marca = time.strftime("%Y%m%d-%H%M%S")

    # Copia los trozos para que el anillo no los pise mientras se juntan.
    tmp = Path(tempfile.mkdtemp(prefix="clip-", dir=g.dir))
    lista = tmp / "lista.txt"
    copias = []
    for i, t in enumerate(trozos):
        c = tmp / f"{i:04d}.ts"
        shutil.copyfile(t, c)
        copias.append(c)
    lista.write_text("".join(f"file '{c}'\n" for c in copias))

    horizontal = destino / f"{marca}_{canal}.mp4"
    base = ["-f", "concat", "-safe", "0", "-i", str(lista), "-c", "copy", "-movflags", "+faststart"]
    if not ffmpeg(*base[:6], "-c", "copy", "-bsf:a", "aac_adtstoasc", "-movflags", "+faststart", str(horizontal)):
        ffmpeg(*base, str(horizontal))
    shutil.rmtree(tmp, ignore_errors=True)
    if not horizontal.exists():
        log(canal, "No se pudo cortar el clip.")
        return
    log(canal, f"✂️  Clip ({motivo}) en {time.monotonic() - inicio:.1f} s → {horizontal.name}")

    if VERTICAL:
        t = time.monotonic()
        vertical = destino / f"{marca}_{canal}_9x16.mp4"
        ok = ffmpeg("-i", str(horizontal), "-vf", "crop=ih*9/16:ih,scale=1080:1920",
                    *CODIFICADOR, "-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart", str(vertical))
        log(canal, f"📱 9:16 en {time.monotonic() - t:.1f} s → {vertical.name}" if ok else "No se pudo hacer el 9:16.")


# ── Chat ─────────────────────────────────────────────────────────────────────

class Chat:
    def __init__(self):
        self.mensajes: collections.deque[float] = collections.deque()
        self.palabras: collections.deque[float] = collections.deque()
        self.lock = threading.Lock()

    def llega(self, texto: str, cuando: float | None = None) -> None:
        t = cuando or time.time()
        with self.lock:
            self.mensajes.append(t)
            if PALABRAS.search(texto):
                self.palabras.append(t)
            limite = time.time() - 180
            while self.mensajes and self.mensajes[0] < limite:
                self.mensajes.popleft()
            while self.palabras and self.palabras[0] < limite:
                self.palabras.popleft()

    def pico(self) -> str | None:
        """Devuelve el motivo si ahora mismo el chat está explotando."""
        ahora = time.time()
        with self.lock:
            recientes = sum(1 for t in self.mensajes if t > ahora - 5)
            antes = sum(1 for t in self.mensajes if ahora - 125 < t <= ahora - 5)
            risas = sum(1 for t in self.palabras if t > ahora - 5)
        ritmo, normal = recientes / 5, antes / 120
        if ritmo >= MINIMO and ritmo >= normal * FACTOR:
            return f"chat x{ritmo / max(normal, 0.01):.0f}"
        if risas >= 4:
            return "risas/clip en el chat"
        return None


def chat_twitch(canal: str, chat: Chat, parar: threading.Event) -> None:
    while not parar.is_set():
        try:
            s = socket.create_connection(("irc.chat.twitch.tv", 6667), timeout=30)
            s.settimeout(5)
            s.sendall(f"PASS SCHMOOPIIE\r\nNICK justinfan{random.randint(10000, 99999)}\r\nJOIN #{canal.lower()}\r\n".encode())
            buf = ""
            while not parar.is_set():
                try:
                    data = s.recv(65536).decode("utf-8", "ignore")
                except socket.timeout:
                    continue
                if not data:
                    break
                buf += data
                *lineas, buf = buf.split("\r\n")
                for l in lineas:
                    if l.startswith("PING"):
                        s.sendall(l.replace("PING", "PONG", 1).encode() + b"\r\n")
                    elif " PRIVMSG " in l:
                        chat.llega(l.split(" PRIVMSG ", 1)[1].partition(" :")[2])
            s.close()
        except OSError as e:
            log(canal, f"Chat de Twitch caído ({e}); reconecto…")
            time.sleep(5)


def yt_api(ruta: str, **q) -> dict:
    q["key"] = YT_KEY
    url = f"https://www.googleapis.com/youtube/v3/{ruta}?{urllib.parse.urlencode(q)}"
    with urllib.request.urlopen(url, timeout=30) as r:
        return json.load(r)


def iso_a_epoch(s: str) -> float:
    return calendar.timegm(time.strptime(s[:19], "%Y-%m-%dT%H:%M:%S"))


def chat_youtube(canal: str, enlace: str, chat: Chat, parar: threading.Event) -> None:
    if not YT_KEY:
        log(canal, "Sin YOUTUBE_API_KEY no leo el chat de YouTube: solo clip manual (Enter).")
        return
    try:
        r = subprocess.run(["yt-dlp", "--quiet", "--no-warnings", "--skip-download", "--print", "%(id)s", enlace],
                           capture_output=True, text=True, timeout=60)
        video = r.stdout.strip().splitlines()[-1]
        datos = yt_api("videos", part="liveStreamingDetails", id=video)
        chat_id = datos["items"][0]["liveStreamingDetails"]["activeLiveChatId"]
    except Exception as e:  # noqa: BLE001
        log(canal, f"No pude abrir el chat de YouTube ({e}): solo clip manual.")
        return
    token, primero = None, True
    while not parar.is_set():
        try:
            q = {"liveChatId": chat_id, "part": "snippet", "maxResults": 2000}
            if token:
                q["pageToken"] = token
            r = yt_api("liveChat/messages", **q)
            if not primero:  # la primera página es historial, no cuenta
                for it in r.get("items", []):
                    sn = it.get("snippet", {})
                    chat.llega(sn.get("displayMessage", ""), iso_a_epoch(sn.get("publishedAt", "")) if sn.get("publishedAt") else None)
            primero = False
            token = r.get("nextPageToken")
            # Cada lectura gasta cuota; 10 s da para ~5 h de directo al día.
            parar.wait(max(r.get("pollingIntervalMillis", 10000) / 1000, 10))
        except Exception as e:  # noqa: BLE001
            log(canal, f"Chat de YouTube: {e}")
            parar.wait(30)


# ── Por canal ────────────────────────────────────────────────────────────────

def vigilar_canal(canal_url: str) -> None:
    nombre = nombre_de(canal_url)
    enlace = enlace_directo(canal_url)
    manual = manuales.setdefault(nombre, threading.Event())
    avisado = False
    while True:
        if not en_vivo(enlace):
            if not avisado:
                log(nombre, "No está en vivo; miro cada minuto.")
                avisado = True
            time.sleep(60)
            continue
        avisado = False
        log(nombre, "🔴 En vivo. Grabando buffer de los últimos %d s." % BUFFER)
        g = Grabador(enlace, nombre)
        g.empezar()
        chat, parar = Chat(), threading.Event()
        if "twitch.tv" in canal_url:
            threading.Thread(target=chat_twitch, args=(nombre, chat, parar), daemon=True).start()
        elif "youtube.com" in canal_url or "youtu.be" in canal_url:
            threading.Thread(target=chat_youtube, args=(nombre, enlace, chat, parar), daemon=True).start()
        else:
            log(nombre, "Sin chat para esta plataforma: clip manual con Enter.")
        ultimo = 0.0
        while g.vivo():
            time.sleep(1)
            motivo = "manual" if manual.is_set() else chat.pico()
            manual.clear()
            if motivo and (motivo == "manual" or time.monotonic() - ultimo > ESPERA_CLIPS):
                ultimo = time.monotonic()
                log(nombre, f"⚡ Momento ({motivo}); corto en {DESPUES} s…")
                threading.Thread(target=lambda m=motivo: (time.sleep(DESPUES), cortar(g, nombre, m)), daemon=True).start()
        parar.set()
        g.parar()
        log(nombre, "El directo terminó.")
        time.sleep(DESPUES + 30)  # deja acabar los cortes pendientes
        g.limpiar()


def teclado() -> None:
    for linea in sys.stdin:
        quien = linea.strip().lower()
        for nombre, ev in manuales.items():
            if not quien or quien in nombre.lower():
                ev.set()


def main() -> int:
    for prog in ("ffmpeg", "yt-dlp"):
        if not shutil.which(prog):
            print(f"Falta {prog}. Instálalo con:  brew install ffmpeg yt-dlp")
            return 1
    canales = sys.argv[1:]
    if not canales and CANALES_TXT.exists():
        canales = [l.strip() for l in CANALES_TXT.read_text().splitlines() if l.strip() and not l.startswith("#")]
    if not canales:
        print(__doc__)
        return 1
    SALIDA.mkdir(parents=True, exist_ok=True)
    print(f"Clips en: {SALIDA}\nEnter = clip ahora en todos · nombre + Enter = solo ese · Ctrl+C para salir\n", flush=True)
    for c in canales:
        threading.Thread(target=vigilar_canal, args=(c,), name=nombre_de(c), daemon=True).start()
    threading.Thread(target=teclado, daemon=True).start()
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        print("\nAdiós. Los clips quedan en", SALIDA)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
