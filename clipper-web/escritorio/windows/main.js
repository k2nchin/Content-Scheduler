// La ventana de escritorio del Clipper para Windows.
//
// La página es la misma que la de la web y el Mac. Se sirve desde un servidor
// diminuto en 127.0.0.1 en vez de abrirla como archivo suelto: una página
// abierta con file:// no tiene origen, y el motor rechazaría sus llamadas.
// El puerto es fijo para que el motor pueda tenerlo permitido de antemano.

const { app, BrowserWindow, shell, Menu } = require('electron');
const http = require('http');
const fs = require('fs');
const path = require('path');

const PUERTO = 42817;
const WEB = path.join(__dirname, 'web');

const TIPOS = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.json': 'application/json; charset=utf-8',
  '.webmanifest': 'application/manifest+json',
};

function servir() {
  return new Promise((listo, fallo) => {
    const servidor = http.createServer((pet, resp) => {
      // Solo se sirven archivos de dentro de la carpeta, pase lo que pase en la ruta.
      const pedido = decodeURIComponent(new URL(pet.url, 'http://x').pathname);
      const destino = path.join(WEB, pedido === '/' ? 'index.html' : pedido);
      if (!destino.startsWith(WEB)) { resp.writeHead(403).end(); return; }
      fs.readFile(destino, (error, datos) => {
        if (error) { resp.writeHead(404).end('No está'); return; }
        resp.writeHead(200, { 'Content-Type': TIPOS[path.extname(destino)] || 'application/octet-stream' });
        resp.end(datos);
      });
    });
    servidor.on('error', fallo);
    // Solo escucha en el propio equipo: nadie de la red puede abrirlo.
    servidor.listen(PUERTO, '127.0.0.1', () => listo(servidor));
  });
}

async function abrirVentana() {
  try {
    await servir();
  } catch (error) {
    // Puerto ocupado: casi siempre es otra copia de esto ya abierta.
    const { dialog } = require('electron');
    dialog.showErrorBox('No se pudo abrir',
      `El puerto ${PUERTO} está ocupado. Cierra la otra ventana de Content Scheduler y vuelve a intentarlo.`);
    app.quit();
    return;
  }

  const ventana = new BrowserWindow({
    width: 1280, height: 860, minWidth: 900, minHeight: 600,
    backgroundColor: '#070708',
    title: 'Content Scheduler',
    webPreferences: { contextIsolation: true, nodeIntegration: false },
  });
  Menu.setApplicationMenu(null);
  ventana.loadURL(`http://127.0.0.1:${PUERTO}/`);

  // Los enlaces de fuera se abren en el navegador, no dentro de la app.
  ventana.webContents.setWindowOpenHandler(({ url }) => {
    shell.openExternal(url);
    return { action: 'deny' };
  });
}

// Una sola ventana: dos copias se pelearían por el puerto.
if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on('second-instance', () => {
    const [ventana] = BrowserWindow.getAllWindows();
    if (ventana) { if (ventana.isMinimized()) ventana.restore(); ventana.focus(); }
  });
  app.whenReady().then(abrirVentana);
  app.on('window-all-closed', () => app.quit());
}
