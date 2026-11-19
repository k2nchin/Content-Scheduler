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
import urllib.parse
import urllib.request
import webbrowser
from pathlib import Path

AQUI = Path(__file__).resolve().parent
CLIENTE = AQUI / "credenciales" / "cliente-oauth.json"
SALIDA = AQUI / "credenciales" / "usuario.json"
XCCONFIG = AQUI.parent.parent / "ios" / "Config.xcconfig"

SOLO_LO_SUYO = "https://www.googleapis.com/auth/drive.file https://www.googleapis.com/auth/youtube.upload"
TODO_EL_DRIVE = "https://www.googleapis.com/auth/drive https://www.googleapis.com/auth/youtube.upload"
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


def instalar_receptor_esquema(scheme: str, puerto: int) -> Path | None:
    """En macOS registra una mini-app temporal que captura el redirect del
    Client ID de iOS (com.googleusercontent.apps...:/oauth2redirect) y se lo
    pasa a http://localhost:PUERTO sin que tengas que copiar nada."""
    if sys.platform != "darwin" or not shutil.which("swiftc"):
        return None
    app_dir = Path(tempfile.mkdtemp(prefix="cs-oauth-")) / "CSAuth.app" / "Contents"
    (app_dir / "MacOS").mkdir(parents=True)
    (app_dir / "Info.plist").write_text(f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.contentscheduler.oauthhelper</string>
  <key>CFBundleExecutable</key><string>helper</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>GoogleOAuth</string>
    <key>CFBundleURLSchemes</key><array><string>{scheme}</string></array>
  </dict></array>
</dict></plist>""")
    swift_src = app_dir.parent.parent / "helper.swift"
    swift_src.write_text(f"""import AppKit
class D: NSObject, NSApplicationDelegate {{
    func application(_ application: NSApplication, open urls: [URL]) {{
        if let u = urls.first, let q = u.query {{
            let t = URL(string: "http://localhost:{puerto}/?" + q)!
            let sem = DispatchSemaphore(value: 0)
            URLSession.shared.dataTask(with: t) {{ _,_,_ in sem.signal() }}.resume()
            _ = sem.wait(timeout: .now() + 5)
        }}
        NSApp.terminate(nil)
    }}
}}
let app = NSApplication.shared
let d = D()
app.delegate = d
app.run()
""")
    r = subprocess.run(["swiftc", str(swift_src), "-o", str(app_dir / "MacOS" / "helper")], capture_output=True)
    if r.returncode != 0:
        return None
    lsreg = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    subprocess.run([lsreg, "-f", str(app_dir.parent)], capture_output=True)
    return app_dir.parent.parent


def main() -> int:
    permiso, _ = alcance()
    secreto = ""
    if CLIENTE.is_file():
        datos = json.loads(CLIENTE.read_text())
        conf = datos.get("installed") or datos.get("web") or {}
        cliente, secreto = conf.get("client_id", ""), conf.get("client_secret", "")
        destino = f"http://localhost:{PUERTO}"
        tmp_app = None
    else:
        cliente = leer_ios_client_id()
        scheme = ".".join(reversed(cliente.split(".")))
        destino = f"{scheme}:/oauth2redirect"
        tmp_app = instalar_receptor_esquema(scheme, PUERTO)
        print(f"Usando las mismas credenciales de Content Scheduler ({cliente[:24]}…)")

    verifier = base64.urlsafe_b64encode(os.urandom(40)).decode().rstrip("=")
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
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

    servidor = http.server.HTTPServer(("localhost", PUERTO), Recogida)
    servidor.timeout = 180
    hilo = threading.Thread(target=servidor.handle_request, daemon=True)
    hilo.start()

    print("\nAbriendo Google en el navegador: entra con tu cuenta de Google y dale a Permitir.\n")
    webbrowser.open(url)
    hilo.join(timeout=185)
    if tmp_app:
        shutil.rmtree(tmp_app, ignore_errors=True)

    if not Recogida.codigo:
        print("No llegó la respuesta automática. Si el navegador intentó abrir una dirección, pégala aquí:")
        linea = input("> ").strip()
        m = re.search(r"[?&]code=([^&]+)", linea)
        Recogida.codigo = urllib.parse.unquote(m.group(1)) if m else linea
    if not Recogida.codigo:
        print("Cancelado.")
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

    SALIDA.parent.mkdir(parents=True, exist_ok=True)
    SALIDA.write_text(json.dumps({
        "client_id": cliente,
        "client_secret": secreto,
        "refresh_token": tok["refresh_token"],
        "scope": permiso,
    }, indent=2))
    os.chmod(SALIDA, 0o600)
    print(f"✓ Guardado en {SALIDA} (Drive + YouTube listos con las credenciales de Content Scheduler).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
