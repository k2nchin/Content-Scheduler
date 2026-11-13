# Content Scheduler

## App para iOS (`ios/`)

La ventana de herramientas de Content Scheduler como app nativa para iPhone (SwiftUI, iOS 17+), sin login ni registro:

- **Cola**: publicaciones por día, filtros por estado, editor con título, hashtags, redes, día y hora.
- **Calendario**: la semana con tus horarios y los espacios libres.
- **Stats**: números reales de tu canal de YouTube y de lo subido desde la app; las demás redes con datos de ejemplo.
- **Clips IA**: momentos de ejemplo a partir de un link (el análisis real todavía no está conectado) y reciclar lo publicado.
- **Ajustes**: conectar YouTube, horarios de publicación, avisos y datos de ejemplo.

Los datos y los videos se guardan en el iPhone. **YouTube publica de verdad**: el video se sube como privado con hora de publicación y YouTube lo publica solo a esa hora. Facebook, Instagram y TikTok todavía son de prueba.

### Descargar la .ipa

Cada cambio en `ios/` compila la app en GitHub Actions (`.github/workflows/ios.yml`) y deja `ContentScheduler.ipa` en **Releases → ios-latest**. Está **sin firmar**: instálala con [Sideloadly](https://sideloadly.io) o AltStore usando tu Apple ID. Con un Apple ID gratis la app caduca a los 7 días y hay que reinstalarla; con Apple Developer (99 USD/año) dura un año o se puede usar TestFlight.

### Configurar YouTube

1. En Google Cloud (mismo proyecto), activa **YouTube Data API v3**.
2. **Credenciales → Crear → ID de cliente de OAuth → iOS**, con el bundle id `com.contentscheduler.app`.
3. Copia el ID en `ios/Config.xcconfig` (`GOOGLE_IOS_CLIENT_ID`) y súbelo; la .ipa se vuelve a compilar sola. No es una clave secreta.
4. En la pantalla de consentimiento de OAuth agrega los alcances `.../auth/youtube` y `.../auth/youtube.force-ssl` (este último para responder comentarios) y tu correo como usuario de prueba.

Hasta que Google verifique la app y pase la auditoría de la API de YouTube, los videos subidos quedan **privados**; la app lo marca como «YouTube lo dejó privado». La cuota gratuita alcanza para unas 6 subidas al día.

### Compilar en una Mac

```
brew install xcodegen
cd ios && xcodegen generate && open ContentScheduler.xcodeproj
```
