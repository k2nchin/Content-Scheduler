# Servidor de IA del Clipper (Content Scheduler)

Función `api/clip-ai.js`: recibe la transcripción (hecha en el iPhone) y usa NVIDIA NIM para elegir los mejores clips,
con puntaje de viralidad, gancho, títulos por red y hashtags. Solo acepta llamadas de alguien que entró con Google en la app.

## Publicarla en Vercel (sin tocar tu sitio contentscheduler.vercel.app)

1. Vercel → **Add New → Project** → importa `k2nchin/Content-Scheduler`.
2. En **Root Directory** elige `server`.
3. En **Environment Variables** agrega `NVIDIA_API_KEY` con tu clave de NVIDIA (la misma que ya tienes en el otro proyecto).
   Opcional: `NIM_MODEL` (por defecto `deepseek-ai/deepseek-v4.1-flash`, con respaldos).
4. **Deploy**. La dirección queda como `https://<nombre>.vercel.app/api/clip-ai`.
5. Pon esa dirección en `ios/Config.xcconfig` → `CLIP_AI_URL`.

Comprobar: abrir `https://<nombre>.vercel.app/api/clip-ai` debe responder `{"configured":true,...}`.
