// Content Scheduler · Clipper con IA (NVIDIA NIM): recibe la transcripción con tiempos y devuelve los mejores clips,
// con puntaje de viralidad, gancho, títulos por red y hashtags.
// La clave va en Vercel como NVIDIA_API_KEY (también se aceptan NIM_API_KEY o NVIDIA_NIM_API_KEY).
// Modelo opcional: NIM_MODEL. Por defecto nemotron-3-super-120b, con respaldos si no está disponible.

const CLIENT_IDS = [
  '84783551840-mki8tk5nse0mh4idh09f88gi8csf59f1.apps.googleusercontent.com',  // iOS (Content Scheduler)
];
const KEY = process.env.NVIDIA_API_KEY || process.env.NIM_API_KEY || process.env.NVIDIA_NIM_API_KEY;
const MODELS = process.env.NIM_MODEL ? [process.env.NIM_MODEL]
  : ['nvidia/nemotron-3-super-120b-a12b', 'nvidia/llama-3.1-nemotron-70b-instruct', 'mistralai/mistral-large-2-instruct'];
const MODEL = MODELS[0];
const recent = new Map();

function send(res, status, data) {
  res.setHeader('Cache-Control', 'no-store');
  return res.status(status).json(data);
}

async function identify(req) {
  const bearer = /^Bearer (\S+)$/.exec(req.headers.authorization || '');
  if (!bearer) return null;
  const r = await fetch('https://oauth2.googleapis.com/tokeninfo', {
    method: 'POST',
    headers: {'Content-Type': 'application/x-www-form-urlencoded'},
    body: new URLSearchParams({access_token: bearer[1]}),
    signal: AbortSignal.timeout(10_000),
  });
  if (!r.ok) return null;
  const info = await r.json();
  if (![info.audience, info.issued_to, info.azp].some(a => CLIENT_IDS.includes(a))) return null;
  return String(info.user_id || info.sub || info.email || '') || null;
}

function cleanClip(c, duration, minLen, maxLen) {
  let start = Number(c?.start), end = Number(c?.end);
  if (!Number.isFinite(start) || !Number.isFinite(end)) return null;
  start = Math.max(0, start);
  end = Math.min(duration, end);
  if (end - start < Math.max(3, minLen * 0.6) || end - start > maxLen * 1.25) return null;
  const s = v => String(v || '').slice(0, 300);
  const tags = Array.isArray(c.hashtags) ? c.hashtags : [];
  return {
    start: Math.round(start * 10) / 10,
    end: Math.round(end * 10) / 10,
    score: Math.max(0, Math.min(100, Math.round(Number(c.score) || 0))),
    hook: s(c.hook),
    reason: s(c.reason),
    titles: {
      youtube: s(c.titles?.youtube).slice(0, 100),
      instagram: s(c.titles?.instagram),
      facebook: s(c.titles?.facebook),
    },
    hashtags: tags.map(t => '#' + String(t).replace(/^#+/, '').replace(/\s+/g, '')).filter(t => t.length > 1).slice(0, 8),
  };
}

module.exports = async function clipAI(req, res) {
  if (req.method === 'GET') return send(res, 200, {configured: Boolean(KEY), models: MODELS});
  if (req.method !== 'POST') return send(res, 405, {error: 'Método no permitido.'});
  if (!KEY) return send(res, 503, {error: 'La IA de NVIDIA no está configurada en este proyecto de Vercel.'});

  let user;
  try { user = await identify(req); } catch { return send(res, 502, {error: 'No se pudo verificar tu sesión de Google.'}); }
  if (!user) return send(res, 401, {error: 'Conecta YouTube o Google Drive en Ajustes para usar la IA.'});
  const now = Date.now();
  const calls = (recent.get(user) || []).filter(t => now - t < 3_600_000);
  if (calls.length >= 20) return send(res, 429, {error: 'Llegaste al límite de análisis por hora. Prueba más tarde.'});
  calls.push(now); recent.set(user, calls);
  if (recent.size > 2000) recent.clear();

  const {segments, duration, count, minLength, maxLength, language} = req.body || {};
  const dur = Number(duration);
  if (!Array.isArray(segments) || !segments.length || !Number.isFinite(dur) || dur <= 0) {
    return send(res, 400, {error: 'Falta la transcripción del video.'});
  }
  const n = Math.max(1, Math.min(15, Number(count) || 5));
  const minL = Math.max(5, Math.min(120, Number(minLength) || 15));
  const maxL = Math.max(minL, Math.min(180, Number(maxLength) || 60));
  // Transcripción compacta: [inicio-fin] texto
  let transcript = segments
    .map(s => ({a: Number(s.start), b: Number(s.end), t: String(s.text || '').trim()}))
    .filter(s => Number.isFinite(s.a) && Number.isFinite(s.b) && s.t)
    .map(s => `[${s.a.toFixed(1)}-${s.b.toFixed(1)}] ${s.t}`)
    .join('\n');
  if (transcript.length > 60_000) transcript = transcript.slice(0, 60_000);

  const system = `Eres un editor experto en clips virales para YouTube Shorts, Instagram Reels y TikTok.
Recibes la transcripción de un video con tiempos en segundos. Elige los ${n} mejores momentos para clips.
Reglas:
- Cada clip dura entre ${minL} y ${maxL} segundos y empieza y termina en límites de frase (no cortes a mitad de idea).
- Prioriza un gancho fuerte en los primeros 3 segundos, emoción, humor, polémica, revelaciones o frases citables.
- Los clips no se enciman.
- Responde SOLO con JSON válido, sin texto extra, en ${language || 'español'}, con esta forma:
{"clips":[{"start":0,"end":0,"score":0,"hook":"frase de gancho","reason":"por qué funciona","titles":{"youtube":"","instagram":"","facebook":""},"hashtags":["",""]}]}
- score es de 0 a 100 según el potencial viral real; no infles los números.`;

  try {
    let data = null, used = null, lastErr = 'Ningún modelo de NVIDIA respondió.';
    for (const model of MODELS) {
      const r = await fetch('https://integrate.api.nvidia.com/v1/chat/completions', {
        method: 'POST',
        headers: {Authorization: `Bearer ${KEY}`, 'Content-Type': 'application/json'},
        body: JSON.stringify({
          model,
          temperature: 0.3,
          max_tokens: 6000,
          messages: [
            {role: 'system', content: system},
            {role: 'user', content: `Duración total: ${dur.toFixed(1)} s\nTranscripción:\n${transcript}`},
          ],
        }),
        signal: AbortSignal.timeout(55_000),
      });
      const body = await r.json().catch(() => ({}));
      if (r.ok) { data = body; used = model; break; }
      lastErr = 'NVIDIA NIM: ' + (body?.detail || body?.error?.message || body?.title || r.status);
      if (![404, 410, 400].includes(r.status)) return send(res, 502, {error: lastErr});
    }
    if (!data) return send(res, 502, {error: lastErr});
    const text = String(data?.choices?.[0]?.message?.content || '').replace(/<think>[\s\S]*?<\/think>/g, '');
    const json = text.slice(text.indexOf('{'), text.lastIndexOf('}') + 1);
    let parsed;
    try { parsed = JSON.parse(json); } catch { return send(res, 502, {error: 'La IA no devolvió un resultado válido. Inténtalo otra vez.'}); }
    const clips = (parsed.clips || [])
      .map(c => cleanClip(c, dur, minL, maxL))
      .filter(Boolean)
      .sort((a, b) => b.score - a.score)
      .filter((c, i, all) => !all.slice(0, i).some(o => c.start < o.end && c.end > o.start))
      .slice(0, n);
    return send(res, 200, {clips, model: used});
  } catch (e) {
    return send(res, 504, {error: 'La IA tardó demasiado. Prueba con un video más corto o menos clips.'});
  }
};
