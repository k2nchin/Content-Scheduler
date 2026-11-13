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

Los datos y los videos se guardan en el iPhone. **YouTube publica de verdad**: el video se sube como privado con hora de publicación y YouTube lo publica solo a esa hora. Facebook, Instagram y TikTok todavía son de prueba.

### Descargar la .ipa

Cada cambio en `ios/` compila la app en GitHub Actions (`.github/workflows/ios.yml`) y deja `ContentScheduler.ipa` en **Releases → ios-latest**. Está **sin firmar**: instálala con [Sideloadly](https://sideloadly.io) o AltStore usando tu Apple ID. Con un Apple ID gratis la app caduca a los 7 días y hay que reinstalarla; con Apple Developer (99 USD/año) dura un año o se puede usar TestFlight.

### Configurar YouTube

1. En Google Cloud (mismo proyecto), activa **YouTube Data API v3**.
2. **Credenciales → Crear → ID de cliente de OAuth → iOS**, con el bundle id `com.contentscheduler.app`.
3. Copia el ID en `ios/Config.xcconfig` (`GOOGLE_IOS_CLIENT_ID`) y súbelo; la .ipa se vuelve a compilar sola. No es una clave secreta.
4. En la pantalla de consentimiento de OAuth agrega los alcances `.../auth/youtube` y `.../auth/youtube.force-ssl` (este último para responder comentarios) y tu correo como usuario de prueba.

Hasta que Google verifique la app y pase la auditoría de la API de YouTube, los videos subidos quedan **privados**; la app lo marca como «YouTube lo dejó privado». La cuota gratuita alcanza para unas 6 subidas al día.

### Configurar Facebook e Instagram

1. En developers.facebook.com, en tu app de Meta: **Agregar producto → Inicio de sesión con Facebook**, y en **Configuración → Básica → Agregar plataforma → iOS** pon el bundle id `com.contentscheduler.app`.
2. Copia el **App ID** (no el secreto) en `ios/Config.xcconfig` (`META_APP_ID`).
3. Permisos que pide la app: `pages_show_list`, `pages_read_engagement`, `pages_manage_posts`, `business_management`, `instagram_basic`, `instagram_content_publish`. En modo desarrollo funcionan para los administradores y testers de la app; para otras cuentas Meta tiene que aprobarlos (App Review).
4. Instagram tiene que ser una cuenta **profesional** vinculada a la página de Facebook.

Límites: sin servidor, la sesión de Facebook dura unas horas y luego hay que tocar «Entrar de nuevo». Facebook programa los Reels él solo; Instagram no permite programar por API, así que se publica a la hora cuando la app está abierta o iOS la despierta en segundo plano.

### Compilar en una Mac

```
brew install xcodegen
cd ios && xcodegen generate && open ContentScheduler.xcodeproj
```
