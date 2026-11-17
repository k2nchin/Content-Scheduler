# Publicar el Clipper en contentscheduler.vercel.app

El Clipper web **es** la web de Content Scheduler: el proyecto de Vercel `contentscheduler` sirve
`clipper-web/frontend` (Next.js) en lugar de la página estática de `docs/`.
Las páginas legales y la verificación de TikTok se copiaron a `frontend/public/`, así que estas
direcciones siguen igual (Google, Meta y TikTok las tienen registradas):
- `/legal/privacidad.html`, `/legal/terminos.html`, `/tiktok…txt`, `/icono.svg`

## 1. Base de datos y Redis
- **Postgres**: Neon o Supabase (gratis). Ejecuta `init.sql` y luego, en `frontend/`,
  `DATABASE_URL=... npx prisma migrate deploy`.
- **Redis**: Upstash (gratis) o el Redis de Railway.

## 2. Backend (Python + procesamiento de video) — Railway o Render
Vercel no puede procesar video (FFmpeg, Whisper, tareas de minutos), por eso va aparte.
1. Nuevo proyecto → desde GitHub → `k2nchin/Content-Scheduler`, **Root Directory** `clipper-web/backend`
   (usa su Dockerfile).
2. Crea dos servicios con la misma imagen: la **API** y el **worker** (ejemplo en `deploy/render-worker/`).
3. Variables: copia las de `clipper-web/.env.example` (DATABASE_URL, REDIS_*, claves de IA,
   `BACKEND_CPU_ONLY=true`, etc.).
4. Anota la URL pública de la API.

## 3. Frontend — tu proyecto actual de Vercel
1. Vercel → proyecto **contentscheduler** → **Settings → General → Root Directory** →
   `clipper-web/frontend` (Framework: Next.js). Guarda.
2. **Settings → Environment Variables**: `DATABASE_URL`, la URL del backend, `BETTER_AUTH_SECRET`
   y demás de auth, y las `NEXT_PUBLIC_*` que uses (ver `.env.example`).
3. **Deployments → Redeploy**. Comprueba que abren `/`, `/sign-in` y `/legal/privacidad.html`.

Para volver atrás: Root Directory → `docs` y Redeploy.

## Obligación de la AGPL (no la quites)
- Mantén `clipper-web/LICENSE`.
- El pie de la web enlaza al código fuente (`frontend/src/lib/site.ts → GITHUB_URL`).
- El repo público https://github.com/k2nchin/contentscheduler-clipper debe estar al día con lo que
  corre en producción (lo hace solo `.github/workflows/clipper-public.yml`).
