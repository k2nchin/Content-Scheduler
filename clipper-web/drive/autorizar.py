"""Autoriza al Mac a subir a TU Google Drive y YouTube con el MISMO Client ID de
Content Scheduler (ios/Config.xcconfig), sin descargar cliente-oauth.json.

Si ya tienes drive/credenciales/cliente-oauth.json lo usa; si no, usa el
GOOGLE_IOS_CLIENT_ID de Content Scheduler con PKCE: se abre Google en tu
navegador, autorizas y listo.
"""

from __future__ import annotations

import base64
import hashlib
import http.server
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import urllib.request
import webbrowser
from pathlib import Path

AQUI = Path(__file__).resolve().parent
CLIENTE = AQUI / "credenciales" / "cliente-oauth.json"
SALIDA = AQUI / "credenciales" / "usuario.json"
XCCONFIG = AQUI.parent.parent / "ios" / "Config.xcconfig"

SOLO_LO_SUYO = "https://www.googleapis.com/auth/drive.file https://www.googleapis.com/auth/drive.readonly openid email"
TODO_EL_DRIVE = "https://www.googleapis.com/auth/drive"
SCOPE_YOUTUBE = "https://www.googleapis.com/auth/youtube https://www.googleapis.com/auth/youtube.force-ssl"
PUERTO = 8765


def leer_ios_client_id() -> str:
    if XCCONFIG.is_file():
        m = re.search(r"GOOGLE_IOS_CLIENT_ID\s*=\s*(\S+)", XCCONFIG.read_text())
        if m:
            return m.group(1).strip()
    return "84783551840-mki8tk5nse0mh4idh09f88gi8csf59f1.apps.googleusercontent.com"


def alcance() -> tuple[str, bool]:
    env = AQUI.parent / ".env"
    carpeta = ""
    if env.is_file():
        for linea in env.read_text().splitlines():
            if linea.startswith("GOOGLE_DRIVE_FOLDER_ID="):
                carpeta = linea.split("=", 1)[1].strip()
    return (TODO_EL_DRIVE, True) if carpeta else (SOLO_LO_SUYO, False)


class Recogida(http.server.BaseHTTPRequestHandler):
    codigo: str | None = None
    estado: str = ""

    def do_GET(self) -> None:  # noqa: N802
        datos = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        bien = "code" in datos and (not Recogida.estado or datos.get("state", [""])[0] == Recogida.estado)
        if bien:
            Recogida.codigo = datos["code"][0]
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        mensaje = ("Listo. Ya puedes cerrar esta pestaña."
                   if bien else "Algo salió mal. Vuelve a la Terminal.")
        self.wfile.write(f"""<!doctype html><html><head><meta charset="utf-8"></head>
            <body style="margin:0;height:100vh;display:flex;align-items:center;
                         justify-content:center;background:#070708;color:#F5F3EF;
                         font-family:-apple-system,sans-serif">
            <div style="text-align:center">
              <div style="width:46px;height:46px;border-radius:12px;background:#FF0A8A;
                          margin:0 auto 18px"></div>
              <h1 style="font-size:19px;margin:0 0 8px">Content Scheduler</h1>
              <p style="color:#8B8890;font-size:14px;margin:0">{mensaje}</p>
            </div></body></html>""".encode())

    def log_message(self, *_args) -> None:
        pass


def abrir_ventana_oauth_mac(url: str, scheme: str) -> str | None:
    """Abre una ventana nativa de macOS (WKWebView) que captura directamente el
    redirect com.googleusercontent.apps... sin depender de Chrome/Safari ni de
    LaunchServices."""
    if sys.platform != "darwin" or not shutil.which("swiftc"):
        return None
    tmp = Path(tempfile.mkdtemp(prefix="cs-wv-"))
    src = tmp / "wv.swift"
    bin_p = tmp / "wv"
    src.write_text("""import AppKit
import WebKit

let args = CommandLine.arguments
let authURL = URL(string: args[1])!
let targetScheme = args[2]

class Handler: NSObject, NSApplicationDelegate, WKNavigationDelegate, NSWindowDelegate {
    var win: NSWindow!
    var web: WKWebView!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 680),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        win.title = "Conectar cuenta — Content Scheduler"
        win.center()
        win.delegate = self
        let cfg = WKWebViewConfiguration()
        web = WKWebView(frame: win.contentView!.bounds, configuration: cfg)
        web.autoresizingMask = [.width, .height]
        web.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        web.navigationDelegate = self
        win.contentView?.addSubview(web)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        web.load(URLRequest(url: authURL))
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let u = navigationAction.request.url, u.scheme == targetScheme {
            print("REDIRECT_URL=" + u.absoluteString)
            fflush(stdout)
            decisionHandler(.cancel)
            NSApp.terminate(nil)
            return
        }
        decisionHandler(.allow)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let h = Handler()
app.delegate = h
app.run()
""")
    r = subprocess.run(["swiftc", str(src), "-framework", "AppKit", "-framework", "WebKit", "-o", str(bin_p)], capture_output=True)
    if r.returncode != 0:
        shutil.rmtree(tmp, ignore_errors=True)
        return None
    out = subprocess.run([str(bin_p), url, scheme], capture_output=True, text=True)
    shutil.rmtree(tmp, ignore_errors=True)
    m = re.search(r"REDIRECT_URL=(\S+)", out.stdout)
    if not m:
        return None
    q = urllib.parse.parse_qs(urllib.parse.urlparse(m.group(1)).query)
    return (q.get("code") or [None])[0]


def autorizar_uno(permiso: str, salida: Path, etiqueta: str) -> int:
    secreto = ""
    cliente = leer_ios_client_id()
    scheme = ".".join(reversed(cliente.split(".")))
    destino = f"{scheme}:/oauth2redirect"
    if CLIENTE.is_file():
        datos = json.loads(CLIENTE.read_text())
        conf = datos.get("installed") or datos.get("web") or {}
        if conf.get("client_id") and conf.get("client_secret"):
            cliente, secreto = conf["client_id"], conf["client_secret"]
            destino = f"http://localhost:{PUERTO}"

    verifier = base64.urlsafe_b64encode(os.urandom(40)).decode().rstrip("=")
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
    Recogida.codigo = None
    Recogida.estado = secrets.token_urlsafe(16)
    url = "https://accounts.google.com/o/oauth2/v2/auth?" + urllib.parse.urlencode({
        "client_id": cliente,
        "redirect_uri": destino,
        "response_type": "code",
        "scope": permiso,
        "access_type": "offline",
        "prompt": "select_account consent",
        "code_challenge": challenge,
        "code_challenge_method": "S256",
        "state": Recogida.estado,
    })

    if not secreto and sys.platform == "darwin":
        print(f"[{etiqueta}] Abriendo ventana de Content Scheduler para conectar tu cuenta…")
        Recogida.codigo = abrir_ventana_oauth_mac(url, scheme)

    if not Recogida.codigo:
        servidor = http.server.HTTPServer(("127.0.0.1", PUERTO), Recogida)
        servidor.timeout = 180
        hilo = threading.Thread(target=servidor.handle_request, daemon=True)
        hilo.start()
        webbrowser.open(url)
        hilo.join(timeout=180)
        servidor.server_close()

    if not Recogida.codigo:
        print(f"No se completó {etiqueta}.")
        return 1

    form = {
        "client_id": cliente,
        "code": Recogida.codigo,
        "code_verifier": verifier,
        "grant_type": "authorization_code",
        "redirect_uri": destino,
    }
    if secreto:
        form["client_secret"] = secreto
    req = urllib.request.Request(
        "https://oauth2.googleapis.com/token",
        data=urllib.parse.urlencode(form).encode(),
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            tok = json.load(r)
    except urllib.error.HTTPError as e:
        print("Google rechazó el código:", e.read().decode())
        return 1

    salida.parent.mkdir(parents=True, exist_ok=True)
    salida.write_text(json.dumps({
        "client_id": cliente,
        "client_secret": secreto,
        "refresh_token": tok["refresh_token"],
        "scope": permiso,
    }, indent=2))
    os.chmod(salida, 0o600)
    print(f"✓ {etiqueta} conectado y guardado en {salida}")
    return 0


def main() -> int:
    yt_salida = AQUI / "credenciales" / "youtube.json"
    if "--youtube" in sys.argv:
        return autorizar_uno(SCOPE_YOUTUBE, yt_salida, "YouTube")
    permiso, _ = alcance()
    rc = autorizar_uno(permiso, SALIDA, "Google Drive")
    if rc != 0:
        return rc
    if not yt_salida.is_file():
        print("\nAhora autoriza tu canal de YouTube (Google exige pedirlo en una segunda ventana):")
        autorizar_uno(SCOPE_YOUTUBE, yt_salida, "YouTube")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
