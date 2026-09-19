// Registro de visitas del sitio público. Envía un aviso mínimo a la función
// Netlify `visita`, que agrega IP y ubicación en el servidor. No se registran
// las visitas del equipo (marca vh.equipo que deja admin.html al entrar).
const KEY = 'vh.sesion';
function sesion() {
  try {
    let s = sessionStorage.getItem(KEY);
    if (!s) { s = crypto.randomUUID(); sessionStorage.setItem(KEY, s); }
    return s;
  } catch { return null; }
}

export function registrar(event, datos = {}) {
  try {
    if (localStorage.getItem('vh.equipo') === '1' || navigator.webdriver) return;
    const body = JSON.stringify({ event, path: location.pathname, referrer: document.referrer || null, session_id: sesion(), ...datos });
    const url = '/.netlify/functions/visita';
    if (navigator.sendBeacon) navigator.sendBeacon(url, new Blob([body], { type: 'application/json' }));
    else fetch(url, { method: 'POST', headers: { 'content-type': 'application/json' }, body, keepalive: true }).catch(() => {});
  } catch { /* nunca interrumpe la página */ }
}
