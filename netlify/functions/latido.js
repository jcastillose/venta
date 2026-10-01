// Latido programado: cada 6 horas hace una escritura real en Supabase a través de la API,
// para que el proyecto (plan gratuito) no se pause por inactividad. Ver docs/MANTENIMIENTO.md.
// El segundo disparador, independiente de Netlify, es el monitor de disponibilidad de Sentry.
import { createClient } from '@supabase/supabase-js';
import { withSentry } from '../lib/sentry.js';

const sb = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } });

const handler = async () => {
  const { data, error } = await sb.rpc('latido', { p_origen: 'netlify' });
  if (error) throw new Error('latido: ' + error.message);   // withSentry lo reporta
  console.log('latido', JSON.stringify(data));
  return new Response(JSON.stringify(data), { headers: { 'content-type': 'application/json' } });
};

export default withSentry('latido', handler);
export const config = { schedule: '17 */6 * * *' };   // 00:17, 06:17, 12:17 y 18:17 UTC
