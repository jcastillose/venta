// Recuperar conversaciones: la persona escribe el correo con que marcó interés y
// recibe por correo la lista de sus enlaces privados. Nunca se muestra nada en
// pantalla ni se revela si el correo tiene o no conversaciones.
//
// Usa las mismas variables de entorno que avisos.js (RESEND_API_KEY, MAIL_FROM,
// SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY).
import { createClient } from '@supabase/supabase-js';
import { withSentry, reportar } from '../lib/sentry.js';

const SITE = process.env.URL || 'https://mobventa.netlify.app';
const ok = () => new Response(JSON.stringify({ ok: true }), { headers: { 'content-type': 'application/json' } });

const handler = async (req) => {
  if (req.method !== 'POST') return new Response('Method not allowed', { status: 405 });
  let email = '';
  try { email = String((await req.json()).email || '').trim().toLowerCase(); } catch { /* cuerpo inválido */ }
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return new Response(JSON.stringify({ error: 'Correo inválido' }), { status: 400 });

  const sb = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } });

  // Tope: 3 envíos por correo cada hora (misma respuesta hacia afuera).
  const { data: permitido, error: errTope } = await sb.rpc('recovery_allowed', { p_email: email });
  if (errTope || permitido !== true) return ok();

  const { data: hilos } = await sb.from('interests')
    .select('token, status, created_at, products(title, price_clp, status)')
    .ilike('buyer_contact', email.replace(/[\\%_]/g, (c) => '\\' + c))  // sin comodines: _ y % son literales
    .neq('status', 'descartado')
    .order('created_at', { ascending: false });
  if (!hilos?.length) return ok();

  const ESTADO = { nuevo: 'Nuevo', conversando: 'En conversación', reservado: 'Reservado', vendido: 'Vendido' };
  const filas = hilos.map((h) => `
    <tr>
      <td style="padding:12px 0;border-top:1px solid #EEECE7">
        <div style="font-weight:600">${esc(h.products?.title || 'Producto')}</div>
        <div style="font-size:12.5px;color:#6B6964">${clp(h.products?.price_clp)} · ${ESTADO[h.status] || h.status}</div>
      </td>
      <td style="padding:12px 0 12px 12px;border-top:1px solid #EEECE7;text-align:right;white-space:nowrap">
        <a href="${SITE}/c/${h.token}" style="display:inline-block;background:#141414;color:#FAFAF8;text-decoration:none;border-radius:8px;padding:9px 14px;font-size:13px;font-weight:600">Abrir</a>
      </td>
    </tr>`).join('');

  await enviar({
    to: email,
    subject: hilos.length === 1 ? 'Tu conversación' : `Tus ${hilos.length} conversaciones`,
    html: plantilla({
      titulo: 'Tus conversaciones',
      cuerpo: `<p>Estos son los hilos que abriste con este correo. Cada enlace es personal.</p>
        <table style="width:100%;border-collapse:collapse;margin-top:8px">${filas}</table>`,
      pie: `Si no pediste este correo, ignóralo. Nadie más lo recibió. Puedes volver a pedirlo en ${SITE}/mis-conversaciones.`,
    }),
  });
  return ok();
};

async function enviar({ to, subject, html }) {
  const r = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: { authorization: `Bearer ${process.env.RESEND_API_KEY}`, 'content-type': 'application/json' },
    body: JSON.stringify({ from: process.env.MAIL_FROM, to: [to], subject, html }),
  });
  if (!r.ok) console.error('Resend', r.status, await r.text());
}

const clp = (n) => '$' + Number(n || 0).toLocaleString('es-CL');
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) =>
  ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

const plantilla = ({ titulo, cuerpo, pie }) => `
<div style="margin:0;padding:32px 16px;background:#FAFAF8;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;color:#141414">
  <div style="max-width:520px;margin:0 auto;background:#FFFFFF;border:1px solid #E4E2DD;border-radius:12px;padding:28px">
    <img src="https://mobventa.netlify.app/src/logo.png" alt="MobVenta" width="150" style="display:block;width:150px;height:auto;margin:0 0 18px">
    <h1 style="margin:0 0 14px;font-size:22px;font-weight:700;letter-spacing:-.02em;line-height:1.2">${titulo}</h1>
    <div style="font-size:14.5px;line-height:1.6;color:#2B2A27">${cuerpo}</div>
    ${pie ? `<p style="margin:22px 0 0;padding-top:18px;border-top:1px solid #EEECE7;font-size:12.5px;color:#6B6964">${pie}</p>` : ''}
  </div>
</div>`;

export default withSentry('recuperar', handler);
