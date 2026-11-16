# Content Scheduler

## App para iOS (`ios/`)

La ventana de herramientas de Content Scheduler como app nativa para iPhone (SwiftUI, iOS 17+), sin login ni registro:

- **Cola**: publicaciones por día, filtros por estado, editor con título, hashtags, redes, día y hora.
- **Calendario**: la semana con tus horarios y los espacios libres.
- **Stats**: números reales de tu canal de YouTube y de lo subido desde la app; las demás redes con datos de ejemplo.
- **Clips IA**: momentos de ejemplo a partir de un link (el análisis real todavía no está conectado) y reciclar lo publicado.
- **Ajustes**: conectar YouTube, horarios de publicación, avisos y datos de ejemplo.

- **Comentarios**: responder, respuestas rápidas, reglas por palabra clave (`precio, cuánto => …`), filtro de spam y links, ocultar comentarios y **respuesta automática** (al abrir la app y en segundo plano con la actualización en segundo plano de iOS).
- **Notificaciones**: cuando un video se programa, se publica o falla, y cuando llegan comentarios.
- **Grupos de hashtags** guardados en el editor.
- **Estudio**: recortar el video y ponerle subtítulos automáticos en español (reconocimiento de voz del iPhone).
- **Mejor hora**: analiza tus últimos 50 videos de YouTube y propone las horas con más vistas.
- **Texto distinto por red** y **duplicar** un post.
- **Primer comentario** automático al publicarse (YouTube, Facebook, Instagram).
- **Portada** elegida en el Estudio (se sube como miniatura en YouTube) y **convertir a vertical 9:16** con fondo difuminado.
- **Clipping en vivo** (Clipper): graba con la cámara en partes de 3 min y, al cerrar cada parte, convierte en clips los momentos marcados (botón «Clip» o picos de energía del audio) y los manda a la cola mientras sigues grabando.
- **Subtítulos tipo CapCut**: fuentes gruesas incluidas (Anton, Bebas Neue, Archivo Black, Poppins, Bangers, Luckiest Guy; licencias OFL/Apache en `ios/ContentScheduler/Fonts`), la palabra que se dice resaltada en color, borde fuerte y animación «pop».
- **Seguimiento de cámara**: al pasar a 9:16, una cámara virtual sigue la cara de quien habla (Vision del iPhone: caras → cuerpo → lo más llamativo), sin temblores y con movimiento suave.
- **Clipper** (en Contenido): de un video largo saca varios clips —a mano, en partes iguales o en los momentos con más energía del audio— y los manda a la cola, con opción vertical 9:16 y subtítulos.
- **Reporte semanal** los lunes, **bloqueo con Face ID** y **copia de seguridad** (exportar/restaurar).

Los datos y los videos se guardan en el iPhone. **YouTube publica de verdad**: el video se sube como privado con hora de publicación y YouTube lo publica solo a esa hora. Facebook, Instagram y TikTok todavía son de prueba.

### Descargar la .ipa

Cada cambio en `ios/` compila la app en GitHub Actions (`.github/workflows/ios.yml`) y deja `ContentScheduler.ipa` en **Releases → ios-latest**. Está **sin firmar**: instálala con [Sideloadly](https://sideloadly.io) o AltStore usando tu Apple ID. Con un Apple ID gratis la app caduca a los 7 días y hay que reinstalarla; con Apple Developer (99 USD/año) dura un año o se puede usar TestFlight.

### Configurar YouTube

1. En Google Cloud (mismo proyecto), activa **YouTube Data API v3**.
2. **Credenciales → Crear → ID de cliente de OAuth → iOS**, con el bundle id `com.contentscheduler.app`.
3. Copia el ID en `ios/Config.xcconfig` (`GOOGLE_IOS_CLIENT_ID`) y súbelo; la .ipa se vuelve a compilar sola. No es una clave secreta.
4. En la pantalla de consentimiento de OAuth agrega los alcances `.../auth/youtube` y `.../auth/youtube.force-ssl` (este último para responder comentarios) y tu correo como usuario de prueba.

Hasta que Google verifique la app y pase la auditoría de la API de YouTube, los videos subidos quedan **privados**; la app lo marca como «YouTube lo dejó privado». La cuota gratuita alcanza para unas 6 subidas al día.

### IA (NVIDIA NIM)

En Ajustes → **IA (NVIDIA NIM)** pegas tu clave de build.nvidia.com; se guarda en el Llavero del iPhone (no va en la `.ipa`). Con eso:
- **Clipper → IA**: el iPhone transcribe el video y NIM elige los mejores momentos con puntaje de viralidad, gancho, títulos por red y hashtags.
- **Comentarios**: «✨ Responder con IA» y respuesta automática con IA (las reglas por palabra van primero; spam e insultos no se responden).
Más IA: portada elegida con visión, gancho en pantalla (3 s), subtítulos corregidos, «✨ Escribir con IA» (título, texto por red y hashtags) en el editor, consejo de horarios, ideas de contenido, clasificación de comentarios (preguntas, críticas y colaboraciones van a «Para ti» y no se responden solas), resumen de comentarios y estilo aprendido de tus respuestas a mano.
Modelos automáticos por tarea: clipping rápido con `deepseek-ai/deepseek-v4.1-flash`, comentarios orgánicos con `writer/palmyra-creative-122b` y hashtags con `z-ai/glm-5.3-flash`, cada uno con respaldos (se puede fijar otro en Ajustes). Alternativa con servidor: carpeta `server/`.

### YouTube en vivo (momentos de directos)

Clipper → **YouTube en vivo**. Lee el chat de un directo con la API oficial (`liveChat/messages`) y marca los momentos en que explota o hay muchas reacciones. YouTube **no tiene API para crear clips**, así que la app guarda el momento con su tiempo exacto y un link directo a ese punto: tú tocas «Clip» en YouTube, o usas esos tiempos para cortar el VOD en el Clipper. Cuota: en «Tiempo real» lee el chat cada ~5 s (~2,5 h de directo al día); apagado, cada 20 s (~11 h).

### Twitch (clips de directos)

Clipper → **Clips de Twitch**. Vigila el chat de un directo y crea clips en Twitch cuando el chat explota o hay muchas reacciones (API oficial, máx. 1 por minuto). Los clips de **tu canal** se bajan y pasan a 9:16 con seguimiento de cara y subtítulos directo a la cola (Twitch no permite bajar clips de otros canales). Kick no tiene API pública de clips.

Configurar: en dev.twitch.tv → Applications → Register: tipo **Public**, OAuth Redirect `http://localhost`, activa **Device Code Flow**. Copia el **Client ID** a `ios/Config.xcconfig` → `TWITCH_CLIENT_ID`.

### Google Drive (almacenamiento de clips)

En Ajustes → **Conectar Google Drive**. Los clips del Clipper se guardan en la carpeta «Content Scheduler» de tu Drive y no en el iPhone; se bajan un momento solo al publicarse. Permiso `drive.file`: la app solo ve los archivos que ella misma crea. En Google Cloud: activa **Google Drive API** y agrega el alcance `.../auth/drive.file` en la pantalla de consentimiento.

### Configurar Facebook e Instagram

1. En developers.facebook.com, en tu app de Meta: **Agregar producto → Inicio de sesión con Facebook**, y en **Configuración → Básica → Agregar plataforma → iOS** pon el bundle id `com.contentscheduler.app`.
2. Copia el **App ID** (no el secreto) en `ios/Config.xcconfig` (`META_APP_ID`).
3. Permisos que pide la app: `pages_show_list`, `pages_read_engagement`, `pages_manage_posts`, `business_management`, `instagram_basic`, `instagram_content_publish`, `pages_read_user_content`, `pages_manage_engagement`, `instagram_manage_comments` (los tres últimos para los comentarios). En modo desarrollo funcionan para los administradores y testers de la app; para otras cuentas Meta tiene que aprobarlos (App Review).
4. Instagram tiene que ser una cuenta **profesional** vinculada a la página de Facebook.

Límites: sin servidor, la sesión de Facebook dura unas horas y luego hay que tocar «Entrar de nuevo». Facebook programa los Reels él solo; Instagram no permite programar por API, así que se publica a la hora cuando la app está abierta o iOS la despierta en segundo plano.

### Compilar en una Mac

```
brew install xcodegen
cd ios && xcodegen generate && open ContentScheduler.xcodeproj
```
