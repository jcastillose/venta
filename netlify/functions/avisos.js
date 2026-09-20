// Avisos por correo con Resend.
// Lo llama un Database Webhook de Supabase cuando entra un interés, un pago,
// cuando una cuenta invitada del equipo se activa (UPDATE en members) o cuando
// el equipo responde en un hilo (INSERT en messages con sender = 'vendedor').
//
// Variables de entorno en Netlify:
//   RESEND_API_KEY            re_...
//   MAIL_FROM                 "venta.hogar <avisos@tudominio.cl>"
//   AVISOS_SECRET             una frase larga inventada (la misma en el webhook)
//   SUPABASE_URL              https://bxsldfwlbagvgxxhtfwc.supabase.co
//   SUPABASE_SERVICE_ROLE_KEY la clave service_role
import { createClient } from '@supabase/supabase-js';

const SITE = process.env.URL || 'https://mobventa.netlify.app';

export default async (req) => {
  if (req.method !== 'POST') return new Response('Method not allowed', { status: 405 });
  if (req.headers.get('x-avisos-secret') !== process.env.AVISOS_SECRET) {
    return new Response('Forbidden', { status: 403 });
  }

  const payload = await req.json();           // { type, table, record, old_record }
  const { table, type, record, old_record } = payload;

  const sb = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false },
  });

  if (table === 'members' && type === 'UPDATE') return await avisoActivacion(sb, record, old_record);
  if (type !== 'INSERT') return ok();
  if (table === 'interests') return await avisoInteres(sb, record);
  if (table === 'payments') return await avisoPago(sb, record);
  if (table === 'messages') return await avisoRespuesta(sb, record);
  return ok();
};

/* ── Respuesta del equipo: aviso al interesado con enlace a su hilo ────────── */
async function avisoRespuesta(sb, m) {
  if (!m || m.sender !== 'vendedor') return ok();
  const { data: i } = await sb.from('interests')
    .select('id, token, buyer_name, buyer_contact, status, products(title)')
    .eq('id', m.interest_id).maybeSingle();
  if (!i || !esCorreo(i.buyer_contact)) return ok();

  // Un solo correo por ráfaga: si el equipo escribió otro mensaje en los 10 minutos
  // anteriores, ya se avisó. Así varias líneas seguidas no generan varios correos.
  const desde = new Date(new Date(m.created_at).getTime() - 10 * 60 * 1000).toISOString();
  const { count } = await sb.from('messages').select('id', { count: 'exact', head: true })
    .eq('interest_id', i.id).eq('sender', 'vendedor').neq('id', m.id)
    .gte('created_at', desde).lt('created_at', m.created_at);
  if (count > 0) return ok();

  const titulo = i.products?.title || 'tu producto';
  const extracto = m.body.length > 280 ? m.body.slice(0, 277).trimEnd() + '…' : m.body;
  await enviar({
    to: i.buyer_contact,
    subject: `Respuesta sobre ${titulo}`,
    html: plantilla({
      titulo: 'El equipo de venta te respondió',
      cuerpo: `<p>Hola ${esc(i.buyer_name.split(' ')[0])}, hay un mensaje nuevo en tu conversación sobre <strong>${esc(titulo)}</strong>:</p>
        <blockquote style="margin:14px 0;padding:12px 16px;border-left:3px solid #C67139;background:#F7F2E9;border-radius:0 8px 8px 0;color:#2B2A27;white-space:pre-wrap">${esc(extracto)}</blockquote>
        <p>Puedes leerlo completo y seguir la conversación desde tu enlace privado.</p>`,
      cta: { url: `${SITE}/c/${i.token}`, label: 'Abrir la conversación' },
      pie: 'Este enlace es personal: no lo compartas. Si ya no te interesa, puedes borrar la conversación desde el mismo enlace.',
    }),
  });
  return ok();
}

/* ── Cuenta activada: la persona invitada abrió su enlace por primera vez ──── */
async function avisoActivacion(sb, m, antes) {
  // El webhook dispara en cada UPDATE de members (p. ej. last_seen); solo interesa invitado → activo.
  if (!m || antes?.status !== 'invitado' || m.status !== 'activo') return ok();

  const { data } = await sb.from('members').select('email')
    .eq('status', 'activo').eq('role', 'admin').neq('id', m.id);
  const admins = (data || []).map((a) => a.email);
  if (!admins.length) return ok();

  const ROLES = { admin: 'Administrador', editor: 'Editor' };
  await enviar({
    to: admins,
    subject: `Cuenta activada: ${m.name || m.email}`,
    html: plantilla({
      titulo: 'Una persona del equipo activó su cuenta',
      cuerpo: `<p><strong>${esc(m.name || '')}</strong> (${esc(m.email)}) abrió su invitación y ya puede entrar al panel.</p>
        <p>Rol: ${esc(ROLES[m.role] || m.role)}.</p>`,
      cta: { url: `${SITE}/admin.html#equipo`, label: 'Ver equipo' },
    }),
  });
  return ok();
}

/* ── Interés nuevo: enlace privado al interesado + aviso al equipo ─────────── */
async function avisoInteres(sb, i) {
  const { data: p } = await sb.from('products')
    .select('title, price_clp, lugar, created_by').eq('id', i.product_id).single();
  if (!p) return ok();

  const enlace = `${SITE}/c/${i.token}`;
  const monto = clp(p.price_clp);

  if (esCorreo(i.buyer_contact)) {
    await enviar({
      to: i.buyer_contact,
      subject: `Tu conversación por ${p.title}`,
      html: plantilla({
        titulo: 'Guarda este enlace',
        cuerpo: `<p>Hola ${esc(i.buyer_name)}, registramos tu interés en <strong>${esc(p.title)}</strong> (${monto}).</p>
          <p>Desde este enlace privado puedes conversar con quien vende y, cuando te reserven el producto, pagar con Prex, MercadoPago o transferencia.</p>`,
        cta: { url: enlace, label: 'Abrir mi conversación' },
        pie: 'Este enlace es personal: cualquiera que lo tenga puede ver la conversación.',
      }),
    });
  }

  const equipo = await correosEquipo(sb);
  if (equipo.length) {
    await enviar({
      to: equipo,
      subject: `Nuevo interesado: ${p.title}`,
      html: plantilla({
        titulo: 'Alguien marcó interés',
        cuerpo: `<p><strong>${esc(i.buyer_name)}</strong> quiere <strong>${esc(p.title)}</strong> (${monto}).</p>
          <p>Contacto: ${esc(i.buyer_contact)}${esCorreo(i.buyer_contact) ? '' : ' — no es un correo, escríbele por ahí o responde en el hilo'}.</p>`,
        cta: { url: `${SITE}/admin.html#interesados`, label: 'Ver interesados' },
      }),
    });
  }
  return ok();
}

/* ── Pago declarado: aviso al equipo para confirmarlo ─────────────────────── */
async function avisoPago(sb, y) {
  const { data: i } = await sb.from('interests')
    .select('buyer_name, buyer_contact, product_id').eq('id', y.interest_id).single();
  if (!i) return ok();
  const { data: p } = await sb.from('products').select('title').eq('id', i.product_id).single();

  const equipo = await correosEquipo(sb);
  if (!equipo.length) return ok();

  const METODOS = { prex: 'Prex', mercadopago: 'MercadoPago', transferencia: 'Transferencia electrónica' };
  await enviar({
    to: equipo,
    subject: `Pago por confirmar: ${p?.title || 'producto'}`,
    html: plantilla({
      titulo: 'Un pago espera confirmación',
      cuerpo: `<p><strong>${esc(i.buyer_name)}</strong> avisó el pago de <strong>${clp(y.amount_clp)}</strong> por ${esc(METODOS[y.method] || y.method)}${y.reference ? ` (ref. ${esc(y.reference)})` : ''}.</p>
        <p>Producto: ${esc(p?.title || '')}. Revisa tu cuenta y confirma para cerrar la venta.</p>`,
      cta: { url: `${SITE}/admin.html#cobros`, label: 'Ir a Cobros' },
    }),
  });
  return ok();
}

/* ── Utilidades ───────────────────────────────────────────────────────────── */
async function correosEquipo(sb) {
  const { data } = await sb.from('members').select('email').eq('status', 'activo');
  return (data || []).map((m) => m.email);
}

async function enviar({ to, subject, html }) {
  const r = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: {
      authorization: `Bearer ${process.env.RESEND_API_KEY}`,
      'content-type': 'application/json',
    },
    body: JSON.stringify({ from: process.env.MAIL_FROM, to: [].concat(to), subject, html }),
  });
  if (!r.ok) console.error('Resend', r.status, await r.text());
}

const esCorreo = (s) => /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(String(s || '').trim());
const clp = (n) => '$' + Number(n || 0).toLocaleString('es-CL');
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const ok = () => new Response(JSON.stringify({ ok: true }), { headers: { 'content-type': 'application/json' } });

const plantilla = ({ titulo, cuerpo, cta, pie }) => `
<div style="margin:0;padding:32px 16px;background:#FAFAF8;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;color:#141414">
  <div style="max-width:520px;margin:0 auto;background:#FFFFFF;border:1px solid #E4E2DD;border-radius:12px;padding:28px">
    <img src="https://mobventa.netlify.app/src/logo.png" alt="MobVenta" width="150" style="display:block;width:150px;height:auto;margin:0 0 18px">
    <h1 style="margin:0 0 14px;font-size:22px;font-weight:700;letter-spacing:-.02em;line-height:1.2">${titulo}</h1>
    <div style="font-size:14.5px;line-height:1.6;color:#2B2A27">${cuerpo}</div>
    ${cta ? `<p style="margin:24px 0 0"><a href="${cta.url}" style="display:inline-block;background:#141414;color:#FAFAF8;text-decoration:none;border-radius:8px;padding:12px 20px;font-size:14px;font-weight:600">${cta.label}</a></p>
    <p style="margin:14px 0 0;font-size:12px;color:#9B9890;word-break:break-all">${cta.url}</p>` : ''}
    ${pie ? `<p style="margin:22px 0 0;padding-top:18px;border-top:1px solid #EEECE7;font-size:12.5px;color:#6B6964">${pie}</p>` : ''}
  </div>
</div>`;
