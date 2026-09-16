// Invitar una cuenta al equipo. Solo una administradora puede llamarla.
// Requiere en Netlify: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
import { createClient } from '@supabase/supabase-js';

const URL = process.env.SUPABASE_URL;
const SERVICE = process.env.SUPABASE_SERVICE_ROLE_KEY;

export default async (req) => {
  if (req.method !== 'POST') return new Response('Method not allowed', { status: 405 });

  const jwt = (req.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
  if (!jwt) return json({ error: 'Falta la sesión' }, 401);

  const admin = createClient(URL, SERVICE, { auth: { persistSession: false } });

  // ¿Quién llama? Debe ser una cuenta activa con rol admin.
  const { data: userData, error: userErr } = await admin.auth.getUser(jwt);
  if (userErr || !userData?.user) return json({ error: 'Sesión inválida' }, 401);

  const { data: me } = await admin
    .from('members').select('role,status').eq('id', userData.user.id).single();
  if (!me || me.status !== 'activo' || me.role !== 'admin') {
    return json({ error: 'Solo una administradora puede invitar cuentas' }, 403);
  }

  let body;
  try { body = await req.json(); } catch { return json({ error: 'JSON inválido' }, 400); }
  const email = String(body.email || '').trim().toLowerCase();
  const name = String(body.name || '').trim();
  const role = body.role === 'admin' ? 'admin' : 'editor';
  if (!email || !name) return json({ error: 'Nombre y correo son obligatorios' }, 400);

  const redirectTo = (process.env.URL || 'https://mobventa.netlify.app') + '/admin.html';
  const { data, error } = await admin.auth.admin.inviteUserByEmail(email, {
    data: { name, role },
    redirectTo,
  });
  if (error) return json({ error: error.message }, 400);

  // Fila pendiente en members para que aparezca en la pantalla Equipo.
  await admin.from('members').upsert(
    { id: data.user.id, name, email, role, status: 'invitado' },
    { onConflict: 'id' }
  );

  return json({ ok: true, email });
};

const json = (obj, status = 200) =>
  new Response(JSON.stringify(obj), { status, headers: { 'content-type': 'application/json' } });
