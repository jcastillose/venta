// Gestión de cuentas del equipo: crear, editar y eliminar.
// Solo un administrador activo puede llamarla.
// Requiere en Netlify: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
import { createClient } from '@supabase/supabase-js';

// Si SUPABASE_URL falta o apunta a otro proyecto, el JWT del panel no valida.
// Por eso el frontend manda su URL en x-supabase-url y aquí se compara.
const URL = process.env.SUPABASE_URL;
const SERVICE = process.env.SUPABASE_SERVICE_ROLE_KEY;
const SITE = process.env.URL || 'https://mobventa.netlify.app';

export default async (req) => {
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);

  if (!URL || !SERVICE) {
    return json({ error: 'Faltan SUPABASE_URL o SUPABASE_SERVICE_ROLE_KEY en las variables de entorno de Netlify. Agrégalas y vuelve a desplegar.' }, 500);
  }
  const urlCliente = (req.headers.get('x-supabase-url') || '').replace(/\/$/, '');
  if (urlCliente && urlCliente !== URL.replace(/\/$/, '')) {
    return json({ error: `SUPABASE_URL en Netlify (${URL}) no coincide con el proyecto que usa el sitio (${urlCliente}). Corrige la variable y redespliega.` }, 500);
  }

  const jwt = (req.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
  if (!jwt) return json({ error: 'Falta la sesión. Recarga el panel y vuelve a entrar.' }, 401);

  const admin = createClient(URL, SERVICE, { auth: { persistSession: false } });

  const { data: userData, error: userErr } = await admin.auth.getUser(jwt);
  if (userErr || !userData?.user) {
    console.error('getUser', userErr);
    const motivo = userErr?.message || '';
    const pista = /expired/i.test(motivo) ? 'La sesión expiró: recarga el panel y vuelve a entrar.'
      : /signature|invalid/i.test(motivo) ? 'El token no es de este proyecto o SUPABASE_SERVICE_ROLE_KEY no corresponde a él.'
      : 'Recarga el panel y vuelve a entrar.';
    return json({ error: 'Sesión inválida. ' + pista, detalle: motivo }, 401);
  }
  const yo = userData.user.id;

  const { data: me } = await admin.from('members').select('role,status').eq('id', yo).single();
  if (!me || me.status !== 'activo' || me.role !== 'admin') {
    return json({ error: 'Solo un administrador puede gestionar cuentas' }, 403);
  }

  let body;
  try { body = await req.json(); } catch { return json({ error: 'JSON inválido' }, 400); }
  const accion = body.accion;

  try {
    if (accion === 'crear') return await crear(admin, body);
    if (accion === 'editar') return await editar(admin, body, yo);
    if (accion === 'eliminar') return await eliminar(admin, body, yo);
    if (accion === 'reenviar') return await reenviar(admin, body, req);
    return json({ error: 'Acción desconocida' }, 400);
  } catch (e) {
    console.error(e);
    return json({ error: e.message || 'Error inesperado' }, 400);
  }
};

/* ── crear ──────────────────────────────────────────────────────────────────
   modo 'password': cuenta lista para entrar con una contraseña inicial (sin correo).
   modo 'invitar' : envía la invitación por correo (usa el límite de envíos). */
async function crear(admin, b) {
  const email = String(b.email || '').trim().toLowerCase();
  const name = String(b.name || '').trim();
  const role = b.role === 'admin' ? 'admin' : 'editor';
  const modo = b.modo === 'invitar' ? 'invitar' : 'password';
  if (!email || !name) throw new Error('Nombre y correo son obligatorios');

  let user;
  if (modo === 'password') {
    const password = String(b.password || '');
    if (password.length < 8) throw new Error('La contraseña inicial debe tener al menos 8 caracteres');
    const { data, error } = await admin.auth.admin.createUser({
      email, password, email_confirm: true, user_metadata: { name, role, equipo: true, status: 'activo' },
    });
    if (error) throw traducir(error);
    user = data.user;
  } else {
    // Supabase crea el usuario y envía UN correo (plantilla "Invite user") con el
    // enlace; vuelve a /admin.html, que activa la cuenta al detectar la sesión.
    const { data, error } = await admin.auth.admin.inviteUserByEmail(email, {
      data: { name, role, equipo: true, status: 'invitado' }, redirectTo: SITE + '/admin.html',
    });
    if (error) throw traducir(error);
    user = data.user;
  }

  const { error: mErr } = await admin.from('members').upsert(
    { id: user.id, name, email, role, status: modo === 'password' ? 'activo' : 'invitado' },
    { onConflict: 'id' },
  );
  if (mErr) throw mErr;
  return json({ ok: true, id: user.id, modo });
}

/* ── reenviar: nuevo enlace de acceso a una cuenta existente (invitación caducada) ── */
async function reenviar(admin, b) {
  const id = String(b.id || '');
  const { data: m } = await admin.from('members').select('email').eq('id', id).single();
  if (!m) throw new Error('La cuenta no existe');
  // El correo se confirma para que el enlace sea "Magic Link" y no una segunda invitación.
  await admin.auth.admin.updateUserById(id, { email_confirm: true });
  const { error } = await admin.auth.signInWithOtp({
    email: m.email, options: { emailRedirectTo: SITE + '/admin.html', shouldCreateUser: false },
  });
  if (error) throw traducir(error);
  return json({ ok: true });
}

function traducir(error) {
  const m = error.message || '';
  if (/already|registered|exists/i.test(m)) return new Error('Ese correo ya tiene una cuenta');
  if (/rate|limit/i.test(m)) return new Error('Supabase limitó el envío de correos (plan gratuito: pocos por hora). Crea la cuenta con contraseña inicial o configura SMTP propio.');
  if (/redirect/i.test(m)) return new Error('La URL ' + SITE + '/admin.html no está en Supabase → Authentication → URL Configuration → Redirect URLs.');
  return error;
}

/* ── editar: nombre, correo, rol, estado ──────────────────────────────────── */
async function editar(admin, b, yo) {
  const id = String(b.id || '');
  if (!id) throw new Error('Falta el id');
  const { data: actual } = await admin.from('members').select('*').eq('id', id).single();
  if (!actual) throw new Error('La cuenta no existe');

  const patch = {};
  if (b.name != null) patch.name = String(b.name).trim();
  if (b.role != null) patch.role = b.role === 'admin' ? 'admin' : 'editor';
  if (b.status != null && ['activo', 'invitado', 'suspendido'].includes(b.status)) patch.status = b.status;
  if (b.email != null) patch.email = String(b.email).trim().toLowerCase();

  if (id === yo && patch.role === 'editor') throw new Error('No puedes quitarte a ti mismo el rol de administrador');
  if (id === yo && patch.status === 'suspendido') throw new Error('No puedes suspender tu propia cuenta');

  // Cambios que viven en Auth: correo y contraseña.
  const authPatch = {};
  if (patch.email && patch.email !== actual.email) { authPatch.email = patch.email; authPatch.email_confirm = true; }
  if (b.password) {
    if (String(b.password).length < 8) throw new Error('La contraseña debe tener al menos 8 caracteres');
    authPatch.password = String(b.password);
  }
  if (patch.name) authPatch.user_metadata = { name: patch.name };
  if (Object.keys(authPatch).length) {
    const { error } = await admin.auth.admin.updateUserById(id, authPatch);
    if (error) throw error;
  }

  if (Object.keys(patch).length) {
    const { error } = await admin.from('members').update(patch).eq('id', id);
    if (error) throw error;
  }
  return json({ ok: true });
}

/* ── eliminar: reasigna lo que publicó y borra la cuenta de Auth ──────────── */
async function eliminar(admin, b, yo) {
  const id = String(b.id || '');
  if (!id) throw new Error('Falta el id');
  if (id === yo) throw new Error('No puedes eliminar tu propia cuenta');

  const { count: admins } = await admin.from('members')
    .select('id', { count: 'exact', head: true }).eq('role', 'admin').eq('status', 'activo');
  const { data: objetivo } = await admin.from('members').select('role,status').eq('id', id).single();
  if (objetivo?.role === 'admin' && objetivo.status === 'activo' && (admins || 0) <= 1) {
    throw new Error('Es el único administrador activo; nombra otro antes de eliminarlo');
  }

  // Los productos y registros que creó pasan a quien elimina; así no se pierde historial.
  await admin.from('products').update({ created_by: yo }).eq('created_by', id);
  await admin.from('products').update({ updated_by: null }).eq('updated_by', id);
  await admin.from('payments').update({ confirmed_by: null }).eq('confirmed_by', id);
  await admin.from('payment_settings').update({ updated_by: null }).eq('updated_by', id);

  // Borrar en Auth elimina en cascada la fila de members.
  const { error } = await admin.auth.admin.deleteUser(id);
  if (error) {
    // Si el usuario de Auth ya no existía, limpiar members igualmente.
    if (!/not found/i.test(error.message)) throw error;
    await admin.from('members').delete().eq('id', id);
  }
  return json({ ok: true });
}

const json = (obj, status = 200) =>
  new Response(JSON.stringify(obj), { status, headers: { 'content-type': 'application/json' } });
