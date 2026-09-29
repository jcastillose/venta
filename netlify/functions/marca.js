// Logo oficial del sitio en una sola dirección: /marca/logo.png
// Devuelve el logo cargado en Administración → Ajustes (site_settings.marca_logo, bucket `fotos`)
// o, si no hay ninguno, el archivo por defecto /src/logo.png. Así el HTML, los correos,
// la vista previa en redes y el favicon apuntan siempre al mismo logo, sin depender del JavaScript.
// Caché: 5 min en el navegador, 1 min en la CDN con revalidación en segundo plano.
import { createClient } from '@supabase/supabase-js';
import { withSentry } from '../lib/sentry.js';

const SITE = process.env.URL || 'https://mobventa.netlify.app';
const sb = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } });

const handler = async (req) => {
  if (req.method !== 'GET' && req.method !== 'HEAD') return new Response('Method not allowed', { status: 405 });
  let origen = `${SITE}/src/logo.png`;
  try {
    const { data } = await sb.from('site_settings').select('value').eq('key', 'marca_logo').maybeSingle();
    const path = typeof data?.value === 'string' ? data.value.trim() : '';
    if (path) origen = sb.storage.from('fotos').getPublicUrl(path).data.publicUrl;
  } catch (e) {
    console.warn('marca: sin ajuste, uso el logo por defecto', e?.message);
  }
  // Reenvía el If-None-Match del navegador: si el origen responde 304, la renovación no baja bytes.
  const inm = req.headers.get('if-none-match');
  const r = await fetch(origen, inm ? { headers: { 'if-none-match': inm } } : undefined);
  if (r.status === 304) return new Response(null, { status: 304, headers: cabeceras(r, origen) });
  if (!r.ok) return new Response('Logo no disponible', { status: 502 });
  const cuerpo = req.method === 'HEAD' ? null : await r.arrayBuffer();
  return new Response(cuerpo, { status: 200, headers: cabeceras(r, origen) });
};

function cabeceras(r, origen) {
  return {
      'content-type': r.headers.get('content-type') || 'image/png',
      ...(r.headers.get('etag') ? { etag: r.headers.get('etag') } : {}),
      'cache-control': 'public, max-age=300',
      // Borde: 5 min fresco y hasta un día sirviendo la copia mientras revalida en segundo plano (≤1 invocación/5 min por región).
      'netlify-cdn-cache-control': 'public, s-maxage=300, stale-while-revalidate=86400',
      'x-marca-origen': origen.includes('/storage/') ? 'ajustes' : 'por-defecto',
  };
}

export default withSentry('marca', handler);
