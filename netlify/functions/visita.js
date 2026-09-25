// Registro de visitas. Lo llama el navegador (src/visitas.js) con sendBeacon.
// La IP y la ubicación salen de las cabeceras geográficas de Netlify (context.geo):
// país, región, ciudad y coordenadas aproximadas, sin servicio externo. La escritura
// usa la clave service_role: la tabla no se puede insertar ni leer con la clave pública.
import { createClient } from '@supabase/supabase-js';

const EVENTOS = new Set(['catalogo', 'producto', 'interes', 'busqueda', 'categoria']);
const BOT = /(bot|crawler|spider|crawl|slurp|preview|monitor|headless|curl|wget|python-requests|lighthouse|pingdom|facebookexternalhit)/i;
const corto = (s, n) => (s == null ? null : String(s).slice(0, n)) || null;

export default async (req, context) => {
  if (req.method !== 'POST') return new Response('Method not allowed', { status: 405 });
  let b = {};
  try { b = await req.json(); } catch { return new Response(null, { status: 400 }); }
  if (!EVENTOS.has(b.event)) return new Response(null, { status: 400 });

  const ua = req.headers.get('user-agent') || '';
  const geo = context.geo || {};
  const device = /iPad|Tablet/i.test(ua) ? 'tablet' : /Mobi|Android|iPhone/i.test(ua) ? 'móvil' : 'escritorio';
  const uuid = /^[0-9a-f-]{36}$/i.test(b.product_id || '') ? b.product_id : null;

  const sb = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const { error } = await sb.from('visits').insert({
    event: b.event,
    path: corto(b.path, 200),
    product_id: uuid,
    category: corto(b.category, 80),
    query: corto(b.query, 120),
    referrer: corto(b.referrer, 300),
    session_id: corto(b.session_id, 40),
    ip: context.ip || req.headers.get('x-nf-client-connection-ip') || corto((req.headers.get('x-forwarded-for') || '').split(',')[0].trim(), 45),
    country: geo.country?.code || null,
    region: geo.subdivision?.name || null,
    city: geo.city || null,
    lat: geo.latitude ?? null,
    lon: geo.longitude ?? null,
    device,
    agent: corto(ua, 300),
    bot: BOT.test(ua),
  });
  if (error) console.error('visita', error.message);
  return new Response(null, { status: 204 });
};
