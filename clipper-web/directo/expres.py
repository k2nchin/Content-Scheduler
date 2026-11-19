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
    Kick     lee el chat en vivo por el WebSocket público de Kick + el audio del streamer.

Variables (todas opcionales):
    CARPETA_CLIPS        dónde guardar (por defecto ~/Desktop/Clips exprés).
                         Pon una carpeta de iCloud Drive y te llegan solos al iPhone.
    DURACION_CLIP        segundos por clip (45)
    SEGUNDOS_DESPUES     cuánto sigue grabando después del pico antes de cortar (8)
    ESPERA_ENTRE_CLIPS   mínimo entre dos clips del mismo canal (40)
    FACTOR_PICO          cuántas veces más rápido que lo normal tiene que ir el chat (3)
    MIN_MENSAJES_SEG     ritmo mínimo para contar como pico (1.0 mensajes/s)
    VERTICAL             0 para sacar solo el clip horizontal (aún más rápido)
    PUERTO_WEB           puerto de la página http://localhost:PUERTO (8090; 0 = sin web)
    CAMARA               dónde está la cámara del streamer en el directo:
                         auto (la busca por la cara; si no, hace 9:16 normal) |
                         arriba-derecha | arriba-izquierda | abajo-derecha |
                         abajo-izquierda | x,y,ancho,alto (en %: ej. 72,3,26,34) |
                         no (sin recuadro arriba: solo 9:16 normal)
    ALTURA_MAXIMA        calidad que se baja del directo (720)
"""

from __future__ import annotations

import base64
import calendar
import collections
import http.server
import json
import os
import random
import ssl
import struct
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
CAMARA = os.getenv("CAMARA", "auto").strip().lower()
ALTURA = os.getenv("ALTURA_MAXIMA", "720")
YT_KEY = os.getenv("YOUTUBE_API_KEY", "").strip()
NIM_KEY = os.getenv("NVIDIA_API_KEY", "").strip()
GOOGLE_KEY = os.getenv("GOOGLE_API_KEY", "").strip()
FACTOR_AUDIO = float(os.getenv("FACTOR_AUDIO", "2.6"))
MIN_DB_PICO = float(os.getenv("MIN_DB_PICO", "-32"))
PUERTO_WEB = int(os.getenv("PUERTO_WEB", "8090"))
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


# Esquinas típicas de la cámara en OBS (en % del video: x, y, ancho, alto).
ESQUINAS_CAM = {
    "arriba-derecha": (0.71, 0.03, 0.27, 0.36),
    "arriba-izquierda": (0.02, 0.03, 0.27, 0.36),
    "abajo-derecha": (0.71, 0.61, 0.27, 0.36),
    "abajo-izquierda": (0.02, 0.61, 0.27, 0.36),
}


def detectar_camara_cara(video: Path) -> tuple[float, float, float, float] | None:
    """Busca una cara fija en una esquina con OpenCV (si está instalado)."""
    try:
        import cv2  # type: ignore
    except ImportError:
        return None
    cap = cv2.VideoCapture(str(video))
    if not cap.isOpened():
        return None
    total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT) or 0)
    w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH) or 0)
    h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT) or 0)
    if not (w and h and total):
        cap.release()
        return None
    det = cv2.CascadeClassifier(cv2.data.haarcascades + "haarcascade_frontalface_default.xml")
    esquinas = []
    for f in (0.15, 0.35, 0.55, 0.75, 0.9):
        cap.set(cv2.CAP_PROP_POS_FRAMES, int(total * f))
        ok, frame = cap.read()
        if not ok:
            continue
        chico = cv2.resize(frame, (640, 360))
        caras = det.detectMultiScale(cv2.cvtColor(chico, cv2.COLOR_BGR2GRAY), 1.15, 4, minSize=(22, 22))
        for (x, y, fw, fh) in caras:
            cx, cy = (x + fw / 2) / 640, (y + fh / 2) / 360
            # Una webcam de streamer vive pegada a una esquina, no en el centro.
            if (cx < 0.35 or cx > 0.65) and (cy < 0.42 or cy > 0.58) and fw / 640 < 0.28:
                esquinas.append((cx, cy, fw / 640, fh / 360))
    cap.release()
    if len(esquinas) < 2:
        return None
    esquinas.sort()
    cx, cy, fw, fh = esquinas[len(esquinas) // 2]
    # De la cara al recuadro de la cámara: cabeza, hombros y un poco de fondo.
    cw = min(0.38, max(0.22, fw * 2.8))
    ch = min(0.45, max(0.28, fh * 3.2))
    x = max(0.0, min(1.0 - cw, cx - cw / 2))
    y = max(0.0, min(1.0 - ch, cy - ch * 0.42))
    return (x, y, cw, ch)


def caja_camara(video: Path) -> tuple[float, float, float, float] | None:
    if CAMARA in ("no", "0", "false", "centro"):
        return None
    if CAMARA in ESQUINAS_CAM:
        return ESQUINAS_CAM[CAMARA]
    if "," in CAMARA:
        try:
            x, y, w, h = [float(v) / 100 for v in CAMARA.split(",")]
            if 0 <= x < 1 and 0 <= y < 1 and 0 < w <= 1 and 0 < h <= 1:
                return (x, y, w, h)
        except ValueError:
            pass
    return detectar_camara_cara(video)


def filtro_vertical(video: Path) -> str:
    """Si hay cámara en una esquina: fondo difuminado + juego grande abajo +
    cámara del streamer arriba con esquinas redondeadas (estilo TikTok/Kick).
    Si no: recorte 9:16 centrado."""
    cam = caja_camara(video)
    if not cam:
        return "crop=ih*9/16:ih,scale=1080:1920"
    x, y, w, h = cam
    r = 38  # radio de las esquinas redondeadas de la cámara
    redondeo = (
        f"if(lt(X,{r})*lt(Y,{r}),if(lte(hypot({r}-X,{r}-Y),{r}),255,0),"
        f"if(gt(X,W-{r})*lt(Y,{r}),if(lte(hypot(X-(W-{r}),{r}-Y),{r}),255,0),"
        f"if(lt(X,{r})*gt(Y,H-{r}),if(lte(hypot({r}-X,Y-(H-{r})),{r}),255,0),"
        f"if(gt(X,W-{r})*gt(Y,H-{r}),if(lte(hypot(X-(W-{r}),Y-(H-{r})),{r}),255,0),255))))"
    )
    return (
        f"[0:v]crop=iw*{w:.4f}:ih*{h:.4f}:iw*{x:.4f}:ih*{y:.4f},split=2[bg][cam];"
        # Fondo de arriba y abajo: la propia cámara del streamer difuminada.
        "[bg]scale=270:480:force_original_aspect_ratio=increase,crop=270:480,"
        "boxblur=22:3,scale=1080:1920[bg2];"
        # El juego grande abajo, un poco desplazado al lado contrario de la webcam
        # para que la cámara no salga repetida en una esquina.
        f"[0:v]crop=ih*1080/1150:ih:iw*{0.18 if x > 0.5 else 0.82:.2f}-(ih*1080/1150)/2:0,"
        "scale=1080:1150[game2];"
        # La cámara del streamer arriba, con esquinas redondeadas.
        "[cam]scale=560:580:force_original_aspect_ratio=increase,crop=560:580,format=yuva420p,"
        f"geq=lum='lum(X,Y)':cb='cb(X,Y)':cr='cr(X,Y)':a='{redondeo}'[cam2];"
        "[bg2][game2]overlay=0:650[tmp];"
        "[tmp][cam2]overlay=(W-w)/2:155,format=yuv420p"
    )


def nivel_audio_db(trozo: Path) -> float:
    """Volumen RMS en dB de un trozo de 2 s (-90 = silencio, 0 = máximo)."""
    r = subprocess.run(
        ["ffmpeg", "-hide_banner", "-nostats", "-i", str(trozo), "-af", "astats=metadata=1:reset=0", "-f", "null", "-"],
        capture_output=True, text=True, timeout=8,
    )
    vals = [float(x) for x in re.findall(r"RMS level dB:\s*(-?\d+(?:\.\d+)?)", r.stderr)]
    return max(vals) if vals else -90.0


class AudioEnergia:
    """Detecta gritos, risas fuertes, golpes o reacciones del streamer en el audio."""

    def __init__(self):
        self.niveles: collections.deque[tuple[float, float]] = collections.deque(maxlen=60)
        self.vistos: set[str] = set()

    def revisar(self, g: Grabador) -> tuple[str | None, int]:
        trozos = sorted(g.dir.glob("s*.ts"), key=lambda p: p.stat().st_mtime)[:-1]
        if not trozos:
            return None, 0
        ultimo = trozos[-1]
        if ultimo.name in self.vistos:
            return None, 0
        self.vistos.add(ultimo.name)
        db = nivel_audio_db(ultimo)
        if db <= -80:
            return None, 0
        ahora = time.time()
        self.niveles.append((ahora, db))
        if len(self.niveles) < 8:
            return None, 0
        recientes = [d for t, d in self.niveles if t > ahora - 4.5]
        historia = sorted(d for t, d in self.niveles if t <= ahora - 4.5)
        if not recientes or len(historia) < 5:
            return None, 0
        pico_db = max(recientes)
        base_db = historia[len(historia) // 2]
        ratio = 10 ** ((pico_db - base_db) / 20.0)
        if pico_db >= MIN_DB_PICO and ratio >= FACTOR_AUDIO:
            pts = min(100, int(60 + min(40, (ratio - FACTOR_AUDIO) * 14)))
            return f"grito/reacción audio x{ratio:.1f}", pts
        return None, 0


def titulo_ia(motivo: str, mensajes_recientes: list[str]) -> str | None:
    """Si hay NVIDIA_API_KEY o GOOGLE_API_KEY, genera un gancho corto a partir del chat."""
    muestra = " | ".join(m.strip() for m in mensajes_recientes[-25:] if m.strip())[:700]
    if not muestra:
        return None
    prompt = (
        f"El directo acaba de tener un momentazo ({motivo}): [{muestra}]. "
        "Escribe UN título viral en español de máximo 7 palabras para el clip. Solo el título, sin comillas."
    )
    try:
        if NIM_KEY:
            req = urllib.request.Request(
                "https://integrate.api.nvidia.com/v1/chat/completions",
                data=json.dumps({
                    "model": "meta/llama-3.1-8b-instruct",
                    "messages": [{"role": "user", "content": prompt}],
                    "max_tokens": 30,
                }).encode(),
                headers={"Authorization": f"Bearer {NIM_KEY}", "Content-Type": "application/json"},
            )
            with urllib.request.urlopen(req, timeout=8) as r:
                return json.load(r)["choices"][0]["message"]["content"].strip().strip('"«»')
        if GOOGLE_KEY:
            req = urllib.request.Request(
                f"https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key={GOOGLE_KEY}",
                data=json.dumps({"contents": [{"parts": [{"text": prompt}]}]}).encode(),
                headers={"Content-Type": "application/json"},
            )
            with urllib.request.urlopen(req, timeout=8) as r:
                return json.load(r)["candidates"][0]["content"]["parts"][0]["text"].strip().strip('"«»')
    except Exception:  # noqa: BLE001
        return None
    return None





META_FILE = Path(__file__).resolve().parent.parent / "drive" / "credenciales" / "meta.json"


def _token_google() -> str | None:
    cred_path = Path(__file__).resolve().parent.parent / "drive" / "credenciales" / "usuario.json"
    if not cred_path.is_file():
        return None
    d = json.loads(cred_path.read_text())
    form = {
        "client_id": d["client_id"],
        "refresh_token": d["refresh_token"],
        "grant_type": "refresh_token",
    }
    if d.get("client_secret"):
        form["client_secret"] = d["client_secret"]
    req = urllib.request.Request(
        "https://oauth2.googleapis.com/token",
        data=urllib.parse.urlencode(form).encode(),
    )
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.load(r)["access_token"]


def publicar_youtube(clip: Path, titulo: str, privacidad: str = "public") -> str:
    """Sube el clip 9:16 como YouTube Short con la misma cuenta autorizada en Google."""
    token = _token_google()
    if not token:
        raise RuntimeError("Falta autorizar Google (python3 drive/autorizar.py)")
    t_short = (titulo if "#shorts" in titulo.lower() else f"{titulo} #Shorts")[:95]
    meta = {
        "snippet": {
            "title": t_short,
            "description": f"{titulo}\n\n#Shorts #clips",
            "categoryId": "20",
        },
        "status": {"privacyStatus": os.getenv("YOUTUBE_PRIVACIDAD", privacidad), "selfDeclaredMadeForKids": False},
    }
    datos = clip.read_bytes()
    init = urllib.request.Request(
        "https://www.googleapis.com/upload/youtube/v3/videos?uploadType=resumable&part=snippet,status",
        data=json.dumps(meta).encode(),
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json; charset=UTF-8",
            "X-Upload-Content-Length": str(len(datos)),
            "X-Upload-Content-Type": "video/mp4",
        },
        method="POST",
    )
    with urllib.request.urlopen(init, timeout=30) as r:
        upload_url = r.headers.get("Location")
    if not upload_url:
        raise RuntimeError("YouTube no devolvió URL de subida (revisa que hayas autorizado con youtube.upload)")
    put = urllib.request.Request(
        upload_url,
        data=datos,
        headers={"Authorization": f"Bearer {token}", "Content-Type": "video/mp4"},
        method="PUT",
    )
    with urllib.request.urlopen(put, timeout=600) as r:
        vid = json.load(r).get("id", "?")
    return vid


def _meta_creds() -> dict:
    """Lee token de página e ig_id desde variables o desde drive/credenciales/meta.json."""
    cfg = {}
    if META_FILE.is_file():
        try:
            cfg = json.loads(META_FILE.read_text())
        except Exception:  # noqa: BLE001
            cfg = {}
    return {
        "page_id": os.getenv("META_PAGE_ID", cfg.get("page_id", "")).strip(),
        "page_token": os.getenv("META_PAGE_TOKEN", cfg.get("page_token", "")).strip(),
        "ig_id": os.getenv("META_IG_ID", cfg.get("ig_id", "")).strip(),
    }


def guardar_meta(user_or_page_token: str) -> dict:
    """Con un token de Facebook descubre automáticamente la Página y la cuenta de Instagram vinculada."""
    url = (
        "https://graph.facebook.com/v21.0/me/accounts"
        "?fields=id,name,access_token,instagram_business_account{id,username}"
        f"&access_token={urllib.parse.quote(user_or_page_token)}"
    )
    with urllib.request.urlopen(url, timeout=20) as r:
        data = (json.load(r) or {}).get("data") or []
    if not data:
        # Quizá ya nos pasaron directamente un Page Access Token
        url_me = (
            "https://graph.facebook.com/v21.0/me"
            "?fields=id,name,instagram_business_account{id,username}"
            f"&access_token={urllib.parse.quote(user_or_page_token)}"
        )
        with urllib.request.urlopen(url_me, timeout=20) as r:
            p = json.load(r)
            p["access_token"] = user_or_page_token
            data = [p]
    p = data[0]
    ig = p.get("instagram_business_account") or {}
    info = {
        "page_id": p["id"],
        "page_name": p.get("name", "Página"),
        "page_token": p.get("access_token", user_or_page_token),
        "ig_id": ig.get("id", ""),
        "ig_username": ig.get("username", ""),
    }
    META_FILE.parent.mkdir(parents=True, exist_ok=True)
    META_FILE.write_text(json.dumps(info, indent=2, ensure_ascii=False))
    return info


def publicar_facebook(clip: Path, descripcion: str) -> str:
    """Sube el clip 9:16 como Reel a la Página de Facebook."""
    c = _meta_creds()
    if not (c["page_id"] and c["page_token"]):
        raise RuntimeError("Conecta Facebook/Instagram arriba pegando tu token de Meta")
    g = "https://graph.facebook.com/v21.0"
    tk = urllib.parse.quote(c["page_token"])
    req1 = urllib.request.Request(f"{g}/{c['page_id']}/video_reels?upload_phase=start&access_token={tk}", method="POST")
    with urllib.request.urlopen(req1, timeout=30) as r:
        st = json.load(r)
    vid, up_url = st["video_id"], st["upload_url"]
    datos = clip.read_bytes()
    req2 = urllib.request.Request(
        up_url,
        data=datos,
        headers={"Authorization": f"OAuth {c['page_token']}", "offset": "0", "file_size": str(len(datos))},
        method="POST",
    )
    with urllib.request.urlopen(req2, timeout=600) as r:
        r.read()
    desc = urllib.parse.quote(f"{descripcion} #Reels #clips")
    req3 = urllib.request.Request(
        f"{g}/{c['page_id']}/video_reels?upload_phase=finish&video_id={vid}&video_state=PUBLISHED&description={desc}&access_token={tk}",
        method="POST",
    )
    with urllib.request.urlopen(req3, timeout=30) as r:
        r.read()
    return vid


def publicar_instagram(clip: Path, descripcion: str) -> str:
    """Sube el clip 9:16 como Reel a la cuenta profesional de Instagram."""
    c = _meta_creds()
    if not (c["ig_id"] and c["page_token"]):
        raise RuntimeError("Tu página de Facebook no tiene cuenta profesional de Instagram vinculada o falta conectar Meta")
    g = "https://graph.facebook.com/v21.0"
    tk = urllib.parse.quote(c["page_token"])
    cap = urllib.parse.quote(f"{descripcion} #Reels #clips")
    req1 = urllib.request.Request(
        f"{g}/{c['ig_id']}/media?media_type=REELS&upload_type=resumable&share_to_feed=true&caption={cap}&access_token={tk}",
        method="POST",
    )
    with urllib.request.urlopen(req1, timeout=30) as r:
        st = json.load(r)
    cid, up_url = st["id"], st["uri"]
    datos = clip.read_bytes()
    req2 = urllib.request.Request(
        up_url,
        data=datos,
        headers={"Authorization": f"OAuth {c['page_token']}", "offset": "0", "file_size": str(len(datos))},
        method="POST",
    )
    with urllib.request.urlopen(req2, timeout=600) as r:
        r.read()
    for _ in range(60):
        time.sleep(4)
        with urllib.request.urlopen(f"{g}/{cid}?fields=status_code,status&access_token={tk}", timeout=20) as r:
            est = json.load(r)
        code = est.get("status_code", "")
        if code == "FINISHED":
            break
        if code in ("ERROR", "EXPIRED"):
            raise RuntimeError(f"Instagram rechazó el video: {est.get('status') or code}")
    req3 = urllib.request.Request(f"{g}/{c['ig_id']}/media_publish?creation_id={cid}&access_token={tk}", method="POST")
    with urllib.request.urlopen(req3, timeout=30) as r:
        return json.load(r).get("id", cid)


_CARPETAS_DRIVE: dict[str, str] = {}


def _drive_carpeta(token: str, nombre: str, padre: str | None = None) -> str:
    clave = f"{padre or 'root'}:{nombre}"
    if clave in _CARPETAS_DRIVE:
        return _CARPETAS_DRIVE[clave]
    cab = {"Authorization": f"Bearer {token}"}
    p_q = f"'{padre}' in parents and " if padre else "'root' in parents and "
    q = urllib.parse.quote(f"name = '{nombre}' and {p_q}mimeType = 'application/vnd.google-apps.folder' and trashed = false")
    req = urllib.request.Request(f"https://www.googleapis.com/drive/v3/files?q={q}&fields=files(id)", headers=cab)
    with urllib.request.urlopen(req, timeout=20) as r:
        files = (json.load(r) or {}).get("files") or []
        if files:
            _CARPETAS_DRIVE[clave] = files[0]["id"]
            return _CARPETAS_DRIVE[clave]
    meta = {"name": nombre, "mimeType": "application/vnd.google-apps.folder"}
    if padre:
        meta["parents"] = [padre]
    req = urllib.request.Request(
        "https://www.googleapis.com/drive/v3/files",
        data=json.dumps(meta).encode(),
        headers={**cab, "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=20) as r:
        _CARPETAS_DRIVE[clave] = json.load(r)["id"]
        return _CARPETAS_DRIVE[clave]


def subir_a_drive_y_borrar(clip: Path, extra_borrar: Path | None, canal: str) -> None:
    """Sube el clip 9:16 a Google Drive (carpeta Content Scheduler/<canal>) y
    borra inmediatamente los archivos grabados del iMac."""
    if os.getenv("DRIVE_SUBIR", "true").lower() == "false":
        return
    cred_path = Path(__file__).resolve().parent.parent / "drive" / "credenciales" / "usuario.json"
    if not cred_path.is_file():
        log(canal, "⚠️ Falta autorizar Drive (python3 drive/autorizar.py). Conservo el clip en el Mac.")
        return
    try:
        token = _token_google()
        if not token:
            return
        raiz = os.getenv("GOOGLE_DRIVE_FOLDER_ID", "").strip() or _drive_carpeta(token, "Content Scheduler")
        carpeta = _drive_carpeta(token, canal, raiz)
        boundary = f"===expres{int(time.time()*1000)}==="
        meta_json = json.dumps({"name": clip.name, "parents": [carpeta]}).encode()
        cuerpo = (
            f"--{boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".encode()
            + meta_json
            + f"\r\n--{boundary}\r\nContent-Type: video/mp4\r\n\r\n".encode()
            + clip.read_bytes()
            + f"\r\n--{boundary}--\r\n".encode()
        )
        up = urllib.request.Request(
            "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart",
            data=cuerpo,
            headers={"Authorization": f"Bearer {token}", "Content-Type": f"multipart/related; boundary={boundary}"},
        )
        with urllib.request.urlopen(up, timeout=300) as r:
            fid = json.load(r).get("id", "?")
        meta_f = clip.with_suffix(".json")
        titulo = (json.loads(meta_f.read_text()).get("titulo") if meta_f.exists() else None) or f"{canal} clip"
        for red, env_k, fn in (
            ("YouTube", "AUTO_YOUTUBE", lambda: publicar_youtube(clip, titulo)),
            ("Facebook", "AUTO_FACEBOOK", lambda: publicar_facebook(clip, titulo)),
            ("Instagram", "AUTO_INSTAGRAM", lambda: publicar_instagram(clip, titulo)),
        ):
            if os.getenv(env_k, "false").lower() == "true":
                try:
                    rid = fn()
                    log(canal, f"🚀 Publicado en {red} ({rid}) ✓")
                except Exception as e_red:  # noqa: BLE001
                    log(canal, f"⚠️ No se pudo autopublicar en {red}: {e_red}")
        if os.getenv("DRIVE_BORRAR_LOCAL", "true").lower() == "false" or os.getenv("CONSERVAR_PARA_WEB", "true").lower() == "true":
            if extra_borrar and extra_borrar.exists():
                extra_borrar.unlink(missing_ok=True)
            log(canal, f"☁️  Subido a Google Drive (Content Scheduler/{canal} · {fid}) ✓")
        else:
            for f in (clip, extra_borrar, clip.with_suffix(".json")):
                if f and f.exists():
                    f.unlink(missing_ok=True)
            log(canal, f"☁️  Subido a Google Drive (Content Scheduler/{canal} · {fid}) y borrado del iMac ✓")
    except Exception as e:  # noqa: BLE001
        log(canal, f"No se pudo subir a Drive ({e}); conservo el clip en el iMac.")

def cortar(g: Grabador, canal: str, motivo: str, puntaje: int = 85, textos_chat: list[str] | None = None) -> None:
    inicio = time.monotonic()
    trozos = g.ultimos(DURACION)
    if not trozos:
        log(canal, "Todavía no hay video grabado para clipear.")
        return
    destino = SALIDA / canal
    destino.mkdir(parents=True, exist_ok=True)
    marca = time.strftime("%Y%m%d-%H%M%S")

    tmp = Path(tempfile.mkdtemp(prefix="clip-", dir=g.dir))
    lista = tmp / "lista.txt"
    copias = []
    for i, t in enumerate(trozos):
        c = tmp / f"{i:04d}.ts"
        shutil.copyfile(t, c)
        copias.append(c)
    lista.write_text("".join(f"file '{c}'\n" for c in copias))

    horizontal = destino / f"{marca}_{canal}_{puntaje}pts.mp4"
    base = ["-f", "concat", "-safe", "0", "-i", str(lista), "-c", "copy", "-movflags", "+faststart"]
    if not ffmpeg(*base[:6], "-c", "copy", "-bsf:a", "aac_adtstoasc", "-movflags", "+faststart", str(horizontal)):
        ffmpeg(*base, str(horizontal))
    shutil.rmtree(tmp, ignore_errors=True)
    if not horizontal.exists():
        log(canal, "No se pudo cortar el clip.")
        return
    log(canal, f"✂️  Clip {puntaje}pts ({motivo}) en {time.monotonic() - inicio:.1f} s → {horizontal.name}")

    gancho = titulo_ia(motivo, textos_chat or [])
    final_path = horizontal
    if VERTICAL:
        t = time.monotonic()
        vertical = destino / f"{marca}_{canal}_{puntaje}pts_9x16.mp4"
        ok = ffmpeg("-i", str(horizontal), "-filter_complex", filtro_vertical(horizontal),
                    *CODIFICADOR, "-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart", str(vertical))
        if ok:
            final_path = vertical
            log(canal, f"📱 9:16 en {time.monotonic() - t:.1f} s → {vertical.name}")
        else:
            log(canal, "No se pudo hacer el 9:16.")
    meta = {"motivo": motivo, "puntaje": puntaje, "titulo": gancho or f"{canal} · {motivo}", "hora": time.strftime("%H:%M:%S")}
    final_path.with_suffix(".json").write_text(json.dumps(meta, ensure_ascii=False))
    subir_a_drive_y_borrar(final_path, horizontal if horizontal != final_path else None, canal)


# ── Chat (Twitch + Kick + YouTube) ───────────────────────────────────────────

class Chat:
    def __init__(self):
        self.mensajes: collections.deque[float] = collections.deque()
        self.palabras: collections.deque[float] = collections.deque()
        self.ultimos_textos: collections.deque[str] = collections.deque(maxlen=40)
        self.lock = threading.Lock()

    def llega(self, texto: str, cuando: float | None = None) -> None:
        t = cuando or time.time()
        with self.lock:
            self.mensajes.append(t)
            self.ultimos_textos.append(texto)
            if PALABRAS.search(texto):
                self.palabras.append(t)
            limite = time.time() - 180
            while self.mensajes and self.mensajes[0] < limite:
                self.mensajes.popleft()
            while self.palabras and self.palabras[0] < limite:
                self.palabras.popleft()

    def textos(self) -> list[str]:
        with self.lock:
            return list(self.ultimos_textos)

    def pico(self) -> str | None:
        motivo, _ = self.pico_con_puntaje()
        return motivo

    def pico_con_puntaje(self) -> tuple[str | None, int]:
        """Devuelve (motivo, puntaje 0-100) si ahora mismo el chat está explotando."""
        ahora = time.time()
        with self.lock:
            recientes = sum(1 for t in self.mensajes if t > ahora - 5)
            antes = sum(1 for t in self.mensajes if ahora - 125 < t <= ahora - 5)
            risas = sum(1 for t in self.palabras if t > ahora - 5)
        ritmo, normal = recientes / 5, antes / 120
        mult = ritmo / max(normal, 0.12)
        if ritmo >= MINIMO and ritmo >= normal * FACTOR:
            pts = min(100, int(62 + min(30, (mult - FACTOR) * 6) + min(10, risas * 2)))
            return f"chat x{ritmo / max(normal, 0.01):.0f}", pts
        if risas >= 4:
            pts = min(98, 65 + risas * 4)
            return "risas/clip en el chat", pts
        return None, 0


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


def _ws_send(sock: ssl.SSLSocket, payload: str, opcode: int = 1) -> None:
    raw = payload.encode("utf-8")
    mask = os.urandom(4)
    header = bytearray([0x80 | opcode])
    n = len(raw)
    if n < 126:
        header.append(0x80 | n)
    elif n < 65536:
        header.append(0x80 | 126)
        header.extend(struct.pack("!H", n))
    else:
        header.append(0x80 | 127)
        header.extend(struct.pack("!Q", n))
    header.extend(mask)
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(raw))
    sock.sendall(bytes(header) + masked)


def _ws_recv(sock: ssl.SSLSocket) -> tuple[int, bytes] | None:
    def leer(k: int) -> bytes:
        b = b""
        while len(b) < k:
            trozo = sock.recv(k - len(b))
            if not trozo:
                raise EOFError
            b += trozo
        return b

    b0, b1 = leer(2)
    op = b0 & 0x0F
    masked = b1 & 0x80
    n = b1 & 0x7F
    if n == 126:
        n = struct.unpack("!H", leer(2))[0]
    elif n == 127:
        n = struct.unpack("!Q", leer(8))[0]
    mask = leer(4) if masked else b""
    datos = leer(n)
    if masked:
        datos = bytes(b ^ mask[i % 4] for i, b in enumerate(datos))
    return op, datos


def _kick_chatroom_id(canal: str) -> int | None:
    req = urllib.request.Request(
        f"https://kick.com/api/v2/channels/{canal}",
        headers={"User-Agent": "Mozilla/5.0", "Accept": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return int(json.load(r)["chatroom"]["id"])
    except Exception:  # noqa: BLE001
        r = subprocess.run(
            ["yt-dlp", "--quiet", "--no-warnings", "--dump-single-json", f"https://kick.com/{canal}"],
            capture_output=True, text=True, timeout=30,
        )
        m = re.search(r'"chatroom_id"\s*:\s*(\d+)', r.stdout)
        return int(m.group(1)) if m else None


def chat_kick(canal: str, chat: Chat, parar: threading.Event) -> None:
    """Lee el chat público de Kick en tiempo real por su WebSocket Pusher (sin clave)."""
    room = _kick_chatroom_id(canal)
    if not room:
        log(canal, "Chat de Kick bloqueado por Cloudflare; detecto los mejores momentos por el AUDIO del streamer.")
        return
    log(canal, f"Chat de Kick conectado en vivo (sala {room}) + detector de audio activo.")
    host = "ws-us2.pusher.com"
    ruta = "/app/32cbd69e4b950bf97679?protocol=7&client=js&version=8.4.0-rc2&flash=false"
    while not parar.is_set():
        try:
            raw_sock = socket.create_connection((host, 443), timeout=20)
            s = ssl.create_default_context().wrap_socket(raw_sock, server_hostname=host)
            key = base64.b64encode(os.urandom(16)).decode()
            s.sendall(
                f"GET {ruta} HTTP/1.1\r\nHost: {host}\r\nUpgrade: websocket\r\n"
                f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n".encode()
            )
            resp = b""
            while b"\r\n\r\n" not in resp:
                resp += s.recv(1024)
            _ws_send(s, json.dumps({"event": "pusher:subscribe", "data": {"auth": "", "channel": f"chatrooms.{room}.v2"}}))
            s.settimeout(25)
            while not parar.is_set():
                try:
                    rec = _ws_recv(s)
                except socket.timeout:
                    _ws_send(s, json.dumps({"event": "pusher:ping", "data": {}}))
                    continue
                if not rec:
                    break
                op, payload = rec
                if op == 8:
                    break
                if op == 9:
                    _ws_send(s, payload.decode("utf-8", "ignore"), opcode=10)
                    continue
                ev = json.loads(payload.decode("utf-8", "ignore") or "{}")
                if "ChatMessageEvent" in str(ev.get("event", "")):
                    data = ev.get("data")
                    if isinstance(data, str):
                        data = json.loads(data)
                    if isinstance(data, dict) and data.get("content"):
                        chat.llega(str(data["content"]))
            s.close()
        except Exception as e:  # noqa: BLE001
            log(canal, f"Reconectando chat de Kick ({e})…")
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
        log(canal, "Sin YOUTUBE_API_KEY: detecto los mejores momentos por el AUDIO del directo.")
        return
    try:
        r = subprocess.run(["yt-dlp", "--quiet", "--no-warnings", "--skip-download", "--print", "%(id)s", enlace],
                           capture_output=True, text=True, timeout=60)
        video = r.stdout.strip().splitlines()[-1]
        datos = yt_api("videos", part="liveStreamingDetails", id=video)
        chat_id = datos["items"][0]["liveStreamingDetails"]["activeLiveChatId"]
    except Exception as e:  # noqa: BLE001
        log(canal, f"Sin chat de YouTube ({e}): detecto momentos por el AUDIO.")
        return
    token, primero = None, True
    while not parar.is_set():
        try:
            q = {"liveChatId": chat_id, "part": "snippet", "maxResults": 2000}
            if token:
                q["pageToken"] = token
            r = yt_api("liveChat/messages", **q)
            if not primero:
                for it in r.get("items", []):
                    sn = it.get("snippet", {})
                    chat.llega(sn.get("displayMessage", ""), iso_a_epoch(sn.get("publishedAt", "")) if sn.get("publishedAt") else None)
            primero = False
            token = r.get("nextPageToken")
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
        log(nombre, "🔴 En vivo. Analizando AUDIO + CHAT para cazar los mejores momentos (buffer %d s)." % BUFFER)
        g = Grabador(enlace, nombre)
        g.empezar()
        chat, audio, parar = Chat(), AudioEnergia(), threading.Event()
        if "twitch.tv" in canal_url:
            threading.Thread(target=chat_twitch, args=(nombre, chat, parar), daemon=True).start()
        elif "kick.com" in canal_url:
            threading.Thread(target=chat_kick, args=(nombre, chat, parar), daemon=True).start()
        elif "youtube.com" in canal_url or "youtu.be" in canal_url:
            threading.Thread(target=chat_youtube, args=(nombre, enlace, chat, parar), daemon=True).start()
        ultimo = 0.0
        while g.vivo():
            time.sleep(1)
            if manual.is_set():
                manual.clear()
                motivo, pts = "manual", 95
            else:
                m_chat, p_chat = chat.pico_con_puntaje()
                m_aud, p_aud = audio.revisar(g)
                if m_chat and m_aud:
                    motivo, pts = f"{m_chat} + {m_aud}", min(100, max(p_chat, p_aud) + 15)
                elif m_chat:
                    motivo, pts = m_chat, p_chat
                else:
                    motivo, pts = m_aud, p_aud
            if motivo and (motivo == "manual" or time.monotonic() - ultimo > ESPERA_CLIPS):
                ultimo = time.monotonic()
                textos = chat.textos()
                log(nombre, f"🔥 Momentazo {pts}pts ({motivo}); corto en {DESPUES} s…")
                threading.Thread(
                    target=lambda m=motivo, p=pts, tx=textos: (time.sleep(DESPUES), cortar(g, nombre, m, p, tx)),
                    daemon=True,
                ).start()
        parar.set()
        g.parar()
        log(nombre, "El directo terminó.")
        time.sleep(DESPUES + 30)
        g.limpiar()


def teclado() -> None:
    for linea in sys.stdin:
        quien = linea.strip().lower()
        for nombre, ev in manuales.items():
            if not quien or quien in nombre.lower():
                ev.set()


# ── Página en http://localhost:8090 ──────────────────────────────────────────

HTML = """<!doctype html><html lang="es"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Directo exprés — Content Scheduler</title>
<style>
:root{--bg:#070708;--bg2:#101012;--fg:#F5F3EF;--muted:#8B8890;--accent:#FF0A8A;--ok:#5EE6A8;--line:#222126}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.5 -apple-system,BlinkMacSystemFont,sans-serif;padding:24px}
header{display:flex;flex-wrap:wrap;gap:12px;align-items:center;justify-content:space-between;max-width:1280px;margin:0 auto 18px}
h1{font-size:22px;margin:0}button{background:var(--accent);color:#fff;border:0;border-radius:11px;padding:10px 16px;font-weight:700;cursor:pointer}
button.sec{background:var(--bg2);border:1px solid var(--line)}
.add{display:flex;gap:8px;max-width:1280px;margin:0 auto 22px}
.add input{flex:1;background:var(--bg2);border:1px solid var(--line);border-radius:11px;padding:10px 14px;color:var(--fg);font-size:14px}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(240px,1fr));gap:16px;max-width:1280px;margin:0 auto}
.card{background:var(--bg2);border:1px solid var(--line);border-radius:14px;overflow:hidden;position:relative}
.card video{width:100%;aspect-ratio:9/16;background:#000;display:block}
.badge{position:absolute;top:10px;left:10px;background:rgba(7,7,8,.82);border:1px solid var(--ok);color:var(--ok);font-weight:800;font-size:12px;padding:3px 9px;border-radius:99px}
.meta{padding:10px 12px;font-size:13px;display:flex;flex-direction:column;gap:4px}
.meta .top{display:flex;justify-content:space-between;align-items:center;gap:8px}
.meta a{color:var(--accent);text-decoration:none;font-weight:700}p.vacio{color:var(--muted);max-width:1280px;margin:40px auto}
</style>
<header>
  <div><h1>🔥 Directo exprés · Cazador de momentos (Audio + Chat)</h1><small id="sub" style="color:var(--muted)"></small></div>
  <div id="btns" style="display:flex;gap:8px;flex-wrap:wrap"><button onclick="clipear('')">⚡ Clip ahora (todos)</button></div>
</header>
<form class="add" onsubmit="agregar(event)">
  <input id="url" placeholder="Pega un directo o canal en vivo (https://kick.com/..., https://twitch.tv/..., https://youtube.com/@...)" required>
  <button type="submit">+ Vigilar directo</button>
  <button type="button" class="sec" onclick="conectarMeta()">🔗 Conectar FB / IG</button>
</form>
<div id="lista" class="grid"></div>
<script>
let vistos = "";
async function clipear(c){await fetch('/api/clip?canal='+encodeURIComponent(c),{method:'POST'});}
async function pub(btn,red,ruta){
  const txt = btn.textContent; btn.disabled = true; btn.textContent = 'Subiendo…';
  const r = await fetch(`/api/publicar?red=${red}&ruta=${encodeURIComponent(decodeURI(ruta))}`,{method:'POST'});
  const d = await r.json();
  btn.disabled = false; btn.textContent = d.ok ? '✓ Subido' : txt;
  if(!d.ok) alert(d.error || 'No se pudo subir');
}
async function borrar(ruta){
  await fetch('/api/borrar?ruta='+encodeURIComponent(decodeURI(ruta)),{method:'POST'});
  vistos=''; cargar();
}
async function conectarMeta(){
  const scope = 'pages_show_list,pages_read_engagement,pages_manage_posts,business_management,instagram_basic,instagram_content_publish,pages_read_user_content,pages_manage_engagement,instagram_manage_comments';
  window.open('https://www.facebook.com/v21.0/dialog/oauth?client_id=1611404507348655&redirect_uri=https://www.facebook.com/connect/login_success.html&response_type=token&scope='+scope,'_blank');
  const t = prompt('Se abrió Facebook con la app de Content Scheduler (1611404507348655). Autoriza y pega aquí la URL final (o el access_token):');
  if(!t) return;
  const m = t.match(/access_token=([^&]+)/);
  const tk = m ? decodeURIComponent(m[1]) : t.trim();
  const r = await fetch('/api/meta?token='+encodeURIComponent(tk),{method:'POST'});
  const d = await r.json();
  alert(d.ok ? `Conectado: ${d.info.page_name}` + (d.info.ig_username ? ` + @${d.info.ig_username}` : '') : ('Error: '+d.error));
}
async function agregar(e){
  e.preventDefault();
  const u = document.getElementById('url');
  await fetch('/api/canal?url='+encodeURIComponent(u.value),{method:'POST'});
  u.value = ''; cargar();
}
async function cargar(){
  const r = await (await fetch('/api/estado')).json();
  document.getElementById('sub').textContent = 'Vigilando (Audio + Chat): ' + (r.canales.join(', ') || 'ninguno') + ' · Ordenados por puntaje viral';
  const b = document.getElementById('btns');
  b.innerHTML = '<button onclick="clipear(\'\')">⚡ Clip ahora</button>' +
    r.canales.map(c => `<button class="sec" onclick="clipear('${c}')">✂️ ${c}</button>`).join('');
  const clave = r.clips.map(x => x.ruta + x.puntaje).join('|');
  if (clave === vistos) return;
  vistos = clave;
  const el = document.getElementById('lista');
  if (!r.clips.length){ el.innerHTML = '<p class="vacio">Escuchando el audio del streamer y el chat en vivo… En cuanto haya gritos, risas o explote el chat, el clip 9:16 sale aquí solo.</p>'; return; }
  el.innerHTML = r.clips.map(c => `<div class="card"><span class="badge">🔥 ${c.puntaje} pts</span><video controls preload="metadata" src="/video/${encodeURI(c.ruta)}"></video>
    <div class="meta"><div class="top"><strong style="color:var(--fg)">${c.titulo}</strong><a download href="/video/${encodeURI(c.ruta)}">⬇</a></div>
    <small style="color:var(--muted)">${c.motivo}</small>
    <div style="display:flex;gap:5px;flex-wrap:wrap;margin-top:6px">
      <button style="flex:1;padding:6px 8px;font-size:11px;background:#ff0033" onclick="pub(this,'youtube','${encodeURI(c.ruta)}')">▶ YouTube</button>
      <button style="flex:1;padding:6px 8px;font-size:11px;background:#1877f2" onclick="pub(this,'facebook','${encodeURI(c.ruta)}')">f Facebook</button>
      <button style="flex:1;padding:6px 8px;font-size:11px;background:#d62976" onclick="pub(this,'instagram','${encodeURI(c.ruta)}')">📸 Instagram</button>
      <button class="sec" style="padding:6px 8px;font-size:11px" title="Borrar del Mac" onclick="borrar('${encodeURI(c.ruta)}')">🗑</button>
    </div></div></div>`).join('');
}
cargar(); setInterval(cargar, 3000);
</script></html>"""


class Web(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_a):
        pass

    def do_POST(self):
        if self.path.startswith("/api/clip"):
            q = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query).get("canal", [""])[0].lower()
            for nombre, ev in manuales.items():
                if not q or q == nombre.lower():
                    ev.set()
            self.send_response(204)
            self.end_headers()
            return
        if self.path.startswith("/api/canal"):
            u = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query).get("url", [""])[0].strip()
            if u.startswith(("http://", "https://")) and nombre_de(u) not in manuales:
                with CANALES_TXT.open("a", encoding="utf-8") as f:
                    f.write(u + "\n")
                threading.Thread(target=vigilar_canal, args=(u,), name=nombre_de(u), daemon=True).start()
            self.send_response(204)
            self.end_headers()
            return
        if self.path.startswith("/api/credenciales-ios"):
            n = int(self.headers.get("Content-Length", "0"))
            body = json.loads(self.rfile.read(n).decode() or "{}")
            cred_dir = Path(__file__).resolve().parent.parent / "drive" / "credenciales"
            cred_dir.mkdir(parents=True, exist_ok=True)
            if body.get("google_refresh_token") and body.get("google_client_id"):
                (cred_dir / "usuario.json").write_text(json.dumps({
                    "client_id": body["google_client_id"],
                    "client_secret": "",
                    "refresh_token": body["google_refresh_token"],
                    "scope": "https://www.googleapis.com/auth/drive.file https://www.googleapis.com/auth/youtube.upload",
                }, indent=2))
            if body.get("meta_page_id") and body.get("meta_page_token"):
                META_FILE.write_text(json.dumps({
                    "page_id": body["meta_page_id"],
                    "page_name": body.get("meta_page_name", "Página"),
                    "page_token": body["meta_page_token"],
                    "ig_id": body.get("meta_ig_id", ""),
                    "ig_username": body.get("meta_ig_username", ""),
                }, indent=2, ensure_ascii=False))
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"ok":true}')
            return
        if self.path.startswith("/api/meta"):
            tk = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query).get("token", [""])[0].strip()
            try:
                info = guardar_meta(tk)
                resp = {"ok": True, "info": info}
            except Exception as e:  # noqa: BLE001
                resp = {"ok": False, "error": str(e)}
            cuerpo = json.dumps(resp).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.end_headers()
            self.wfile.write(cuerpo)
            return
        if self.path.startswith("/api/borrar"):
            rel = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query).get("ruta", [""])[0]
            archivo = (SALIDA / rel).resolve()
            if SALIDA.resolve() in archivo.parents and archivo.is_file():
                archivo.unlink(missing_ok=True)
                archivo.with_suffix(".json").unlink(missing_ok=True)
            self.send_response(204)
            self.end_headers()
            return
        if self.path.startswith("/api/publicar"):
            qs = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
            red = qs.get("red", [""])[0]
            rel = qs.get("ruta", [""])[0]
            archivo = (SALIDA / rel).resolve()
            try:
                if not (SALIDA.resolve() in archivo.parents and archivo.is_file()):
                    raise RuntimeError("El archivo ya no está en el Mac")
                meta_f = archivo.with_suffix(".json")
                titulo = (json.loads(meta_f.read_text()).get("titulo") if meta_f.exists() else None) or archivo.stem
                if red == "youtube":
                    rid = publicar_youtube(archivo, titulo)
                elif red == "facebook":
                    rid = publicar_facebook(archivo, titulo)
                elif red == "instagram":
                    rid = publicar_instagram(archivo, titulo)
                else:
                    raise RuntimeError("Red desconocida")
                if os.getenv("BORRAR_TRAS_PUBLICAR", "false").lower() == "true":
                    archivo.unlink(missing_ok=True)
                    meta_f.unlink(missing_ok=True)
                resp = {"ok": True, "id": rid}
            except Exception as e:  # noqa: BLE001
                resp = {"ok": False, "error": str(e)}
            cuerpo = json.dumps(resp).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.end_headers()
            self.wfile.write(cuerpo)

    def do_GET(self):
        if self.path == "/api/estado":
            archivos = sorted(SALIDA.glob("*/*.mp4"), key=lambda p: p.stat().st_mtime, reverse=True)
            prefer = [p for p in archivos if p.name.endswith("_9x16.mp4")] or archivos
            clips = []
            for p in prefer[:60]:
                meta_f = p.with_suffix(".json")
                meta = json.loads(meta_f.read_text()) if meta_f.exists() else {}
                m_pts = re.search(r"_(\d+)pts", p.name)
                pts = int(meta.get("puntaje") or (m_pts.group(1) if m_pts else 80))
                clips.append({
                    "nombre": p.name,
                    "ruta": str(p.relative_to(SALIDA)),
                    "puntaje": pts,
                    "titulo": meta.get("titulo") or p.stem,
                    "motivo": meta.get("motivo") or "momento destacado",
                })
            clips.sort(key=lambda c: (c["puntaje"], c["nombre"]), reverse=True)
            datos = {"canales": list(manuales.keys()), "carpeta": str(SALIDA), "clips": clips}
            cuerpo = json.dumps(datos).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.end_headers()
            self.wfile.write(cuerpo)
            return
        if self.path.startswith("/video/"):
            rel = urllib.parse.unquote(self.path.removeprefix("/video/"))
            archivo = (SALIDA / rel).resolve()
            if SALIDA.resolve() in archivo.parents and archivo.is_file():
                self.send_response(200)
                self.send_header("Content-Type", "video/mp4")
                self.send_header("Content-Length", str(archivo.stat().st_size))
                self.end_headers()
                with archivo.open("rb") as f:
                    shutil.copyfileobj(f, self.wfile)
                return
        cuerpo = HTML.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(cuerpo)


def main() -> int:
    for prog in ("ffmpeg", "yt-dlp"):
        if not shutil.which(prog):
            print(f"Falta {prog}. Instálalo con:  brew install ffmpeg yt-dlp")
            return 1
    canales = sys.argv[1:]
    if not canales and CANALES_TXT.exists():
        canales = [l.strip() for l in CANALES_TXT.read_text().splitlines() if l.strip() and not l.startswith("#")]
    SALIDA.mkdir(parents=True, exist_ok=True)
    print(f"Clips en: {SALIDA}\nEnter = clip ahora en todos · nombre + Enter = solo ese · Ctrl+C para salir\n", flush=True)
    for c in canales:
        threading.Thread(target=vigilar_canal, args=(c,), name=nombre_de(c), daemon=True).start()
    if PUERTO_WEB:
        srv = http.server.ThreadingHTTPServer(("127.0.0.1", PUERTO_WEB), Web)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        print(f"🌐 Abre el panel en:  http://localhost:{PUERTO_WEB}\n", flush=True)
    threading.Thread(target=teclado, daemon=True).start()
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        print("\nAdiós. Los clips quedan en", SALIDA)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
