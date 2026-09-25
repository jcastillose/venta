import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4';

export const SUPABASE_URL = 'https://bxsldfwlbagvgxxhtfwc.supabase.co';
export const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImJ4c2xkZndsYmFndmd4eGh0ZndjIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODk1MTkxODMsImV4cCI6MjEwNTA5NTE4M30.GkNC5INt8dB7o3t8EH89Jh_SrwaxW4Lp1AIoFnsx_-Y';
export const SITE_URL = 'https://mobventa.netlify.app';

export const sb = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

export const CATEGORIAS_BASE = ['Muebles', 'Electrodomésticos', 'Electrónica'];
export const METODOS = { prex: 'Prex', mercadopago: 'MercadoPago', transferencia: 'Transferencia electrónica' };

export const CONDICIONES = [
  ['nuevo', 'Nuevo, sin uso', 'Sin abrir o sin estrenar; con embalaje o etiquetas.'],
  ['como_nuevo', 'Como nuevo', 'Usado muy poco; sin marcas visibles.'],
  ['impecable', 'Impecable', 'Uso normal, cuidado; sin rayas ni desgaste apreciable.'],
  ['pocos_detalles', 'Pocos detalles de uso', 'Marcas leves que no afectan el funcionamiento.'],
  ['uso_evidente', 'Con uso evidente', 'Desgaste visible; funciona correctamente.'],
  ['a_reparar', 'Necesita reparación', 'Tiene una falla o pieza faltante; se indica en la descripción.'],
  ['repuestos', 'Para repuestos', 'No funciona; se vende por sus partes.'],
];
export const condicionLabel = (v) => (CONDICIONES.find((c) => c[0] === v) || [null, v || '—'])[1];

// Categorías desde la tabla; si la migración 004 aún no corrió, usa las tres base.
export async function cargarCategorias() {
  const { data, error } = await sb.from('categories').select('name,position').order('position').order('name');
  if (error || !data?.length) return CATEGORIAS_BASE;
  return data.map((c) => c.name);
}

// Título del sitio: se edita en Administración → Ajustes (site_settings.titulo_sitio).
export const TITULO_BASE = 'MobVenta';
export async function tituloSitio() {
  const { data } = await sb.from('site_settings').select('value').eq('key', 'titulo_sitio').maybeSingle();
  const v = data?.value;
  return typeof v === 'string' && v.trim() ? v.trim() : TITULO_BASE;
}
// Marca de la barra: se elige en Administración → Ajustes.
//   marca_tipo  'logo' (imagen) | 'texto' (solo el nombre del sitio)
//   marca_logo  ruta en el bucket `fotos` de un logo subido; vacío = /src/logo.png
export const LOGO_BASE = '/src/logo.png';
export async function marca() {
  const { data } = await sb.from('site_settings').select('key, value').in('key', ['titulo_sitio', 'marca_tipo', 'marca_logo']);
  const v = (k) => (data || []).find((r) => r.key === k)?.value;
  const t = typeof v('titulo_sitio') === 'string' && v('titulo_sitio').trim() ? v('titulo_sitio').trim() : TITULO_BASE;
  const path = typeof v('marca_logo') === 'string' ? v('marca_logo').trim() : '';
  return { titulo: t, tipo: v('marca_tipo') === 'texto' ? 'texto' : 'logo', logo: path ? fotoUrl(path) : LOGO_BASE, logoPath: path };
}
// Pinta la marca en la barra (logo o texto) y el título de la pestaña; `sufijo` es el nombre de la página.
export async function aplicarTitulo(sufijo) {
  const m = await marca();
  const t = m.titulo;
  window.__tituloSitio = t; window.__marca = m;
  document.querySelectorAll('.nav .brand').forEach((el) => {
    el.title = t; el.setAttribute('aria-label', `${t}, ir al catálogo`);
    el.classList.toggle('brand-texto', m.tipo === 'texto');
    el.innerHTML = m.tipo === 'texto' ? esc(t) : `<img src="${esc(m.logo)}" alt="${esc(t)}">`;
  });
  if (!document.title.includes(' — ') || document.title.endsWith(TITULO_BASE) || document.title.startsWith(TITULO_BASE)) {
    document.title = sufijo ? `${sufijo} — ${t}` : t;
  }
  return t;
}

export const clp = (n) => '$' + Number(n || 0).toLocaleString('es-CL');
export const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
export const fecha = (iso) => iso ? new Date(iso).toLocaleString('es-CL', { day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit', hour12: false }) : '—';
export const hora = (iso) => iso ? new Date(iso).toLocaleTimeString('es-CL', { hour: '2-digit', minute: '2-digit', hour12: false }) : '';

export const fotoUrl = (path) => path ? sb.storage.from('fotos').getPublicUrl(path).data.publicUrl : null;

// Foto completa dentro de su cuadro: la imagen entera (object-fit: contain) sobre una
// copia desenfocada de sí misma que rellena el fondo. Usar dentro de .thumb, .gallery .main o .photo.
export const fotoHTML = (url, alt = '', lazy = true) => {
  if (!url) return '';
  const l = lazy ? ' loading="lazy" decoding="async"' : ' decoding="async"';
  return `<img class="fondo" src="${url}" alt="" aria-hidden="true"${l}><img class="obj" src="${url}" alt="${esc(alt)}"${l}>`;
};

export const ESTADO = {
  disponible: { label: 'Disponible', color: 'var(--verde)' },
  reservado: { label: 'Reservado', color: 'var(--ambar)' },
  vendido: { label: 'Vendido', color: 'var(--gris)' },
};
export const ESTADO_INTERES = {
  nuevo: { label: 'Nuevo', color: 'var(--accent)' },
  conversando: { label: 'En conversación', color: 'var(--verde)' },
  reservado: { label: 'Reservado', color: 'var(--ambar)' },
  vendido: { label: 'Vendido', color: 'var(--gris)' },
  descartado: { label: 'Descartado', color: 'var(--gris)' },
};
export const ESTADO_PAGO = {
  pendiente: { label: 'Pago pendiente', color: 'var(--gris)' },
  porconfirmar: { label: 'Pago por confirmar', color: 'var(--ambar)' },
  pagado: { label: 'Pagado', color: 'var(--verde)' },
  anulado: { label: 'Pago anulado', color: 'var(--gris)' },
};

export const ICONOS = {
  'Muebles': 'M20 9V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v3M2 16a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-5a2 2 0 0 0-4 0v1.5a.5.5 0 0 1-.5.5h-11a.5.5 0 0 1-.5-.5V11a2 2 0 0 0-4 0zM4 18v2M20 18v2M12 4v9',
  'Electrodomésticos': 'M5 6a4 4 0 0 1 4-4h6a4 4 0 0 1 4 4v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6ZM5 10h14M15 7v6',
  'Electrónica': 'M4 7h16a2 2 0 0 1 2 2v11a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V9a2 2 0 0 1 2-2zM17 2l-5 5-5-5',
};

export const placeholderSVG = (cat) =>
  `<svg class="ph" viewBox="0 0 24 24" stroke-linecap="round" stroke-linejoin="round"><path d="${ICONOS[cat] || ICONOS.Muebles}"></path></svg>`;

export function estadoHTML(map, key) {
  const e = map[key] || { label: key || '—', color: 'var(--gris)' };
  return `<span class="state"><span class="dot" style="background:${e.color}"></span>${esc(e.label)}</span>`;
}

let toastTimer;
export function toast(msg) {
  document.querySelector('.toast')?.remove();
  const el = document.createElement('div');
  el.className = 'toast';
  el.setAttribute('role', 'status');
  el.textContent = msg;
  document.body.append(el);
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.remove(), 3200);
}

export function fail(e) {
  console.error(e);
  toast(e?.message || 'Algo falló. Intenta de nuevo.');
}

export const ICON = {
  back: '<svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2.25" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M19 12H5"/><path d="m12 19-7-7 7-7"/></svg>',
  heart: '<svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2.25" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M19 14c1.49-1.46 3-3.21 3-5.5A5.5 5.5 0 0 0 16.5 3c-1.76 0-3 .5-4.5 2-1.5-1.5-2.74-2-4.5-2A5.5 5.5 0 0 0 2 8.5c0 2.3 1.5 4.05 3 5.5l7 7Z"/></svg>',
  chat: '<svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2.25" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M7.9 20A9 9 0 1 0 4 16.1L2 22Z"/></svg>',
  card: '<svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2.25" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect width="20" height="14" x="2" y="5" rx="2"/><path d="M2 10h20"/></svg>',
  check: '<svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2.25" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M20 6 9 17l-5-5"/></svg>',
  plus: '<svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2.25" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M5 12h14"/><path d="M12 5v14"/></svg>',
  edit: '<svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2.25" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M21.174 6.812a1 1 0 0 0-3.986-3.987L3.842 16.174a2 2 0 0 0-.5.83l-1.321 4.352a.5.5 0 0 0 .623.622l4.353-1.32a2 2 0 0 0 .83-.497z"/><path d="m15 5 4 4"/></svg>',
  trash: '<svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2.25" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M3 6h18"/><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6"/><path d="M10 11v6"/><path d="M14 11v6"/></svg>',
  send: '<svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2.25" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m22 2-7 20-4-9-9-4Z"/><path d="M22 2 11 13"/></svg>',
  login: '<svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2.25" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M15 3h4a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2h-4"/><path d="m10 17 5-5-5-5"/><path d="M15 12H3"/></svg>',
};

const KEY = 'vh.tokens';
export const misTokens = () => { try { return JSON.parse(localStorage.getItem(KEY)) || []; } catch { return []; } };
export function guardarToken(t, productTitle, productId) {
  const prev = misTokens().find((x) => x.token === t) || {};
  const all = misTokens().filter((x) => x.token !== t);
  all.unshift({ ...prev, token: t, title: productTitle, productId: productId ?? prev.productId, at: Date.now() });
  localStorage.setItem(KEY, JSON.stringify(all.slice(0, 40)));
}
export function olvidarToken(t) {
  localStorage.setItem(KEY, JSON.stringify(misTokens().filter((x) => x.token !== t)));
}
