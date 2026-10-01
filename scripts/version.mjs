// Se ejecuta en cada despliegue de Netlify (netlify.toml → [build] command). No modifica el repo.
//
// 1) Valida que cada nombre que las páginas importan de /src/*.js exista como export en ese módulo.
//    Si falta alguno, el despliegue se detiene y queda publicada la versión anterior.
// 2) Sella la versión del commit en las URLs de los módulos y estilos propios (?v=<commit>) y en
//    <html data-version>. Así un HTML nuevo nunca se empareja con un JS antiguo en caché
//    (en iOS, al restaurar una pestaña, el navegador puede reutilizar el módulo sin revalidarlo).
import { readFileSync, writeFileSync, readdirSync } from 'node:fs';

const ver = (process.env.COMMIT_REF || '').slice(0, 7) || 'local' + Date.now().toString(36);
const paginas = readdirSync('.').filter((f) => f.endsWith('.html'));
const modulos = readdirSync('src').filter((f) => f.endsWith('.js'));

const exportsDe = (archivo) => {
  const s = readFileSync(archivo, 'utf8');
  const nombres = new Set();
  for (const m of s.matchAll(/export\s+(?:async\s+)?(?:function\*?|const|let|var|class)\s+([A-Za-z_$][\w$]*)/g)) nombres.add(m[1]);
  for (const m of s.matchAll(/export\s*\{([^}]*)\}/g)) {
    m[1].split(',').forEach((x) => { const n = x.trim().split(/\s+as\s+/).pop(); if (n) nombres.add(n); });
  }
  return nombres;
};

const errores = [];
for (const pagina of paginas) {
  const html = readFileSync(pagina, 'utf8');
  for (const m of html.matchAll(/import\s*\{([^}]*)\}\s*from\s*'(\/src\/[\w.-]+\.js)(?:\?v=[\w.-]+)?'/g)) {
    const disponibles = exportsDe('.' + m[2]);
    const pedidos = m[1].split(',').map((x) => x.trim().split(/\s+as\s+/)[0]).filter(Boolean);
    const faltan = pedidos.filter((n) => !disponibles.has(n));
    if (faltan.length) errores.push(`${pagina} importa de ${m[2]} nombres que no existen: ${faltan.join(', ')}`);
  }
}
if (errores.length) {
  console.error('✘ Imports sin export correspondiente:\n  ' + errores.join('\n  '));
  process.exit(1);
}

if (process.argv.includes('--check')) { console.log('✔ Imports validados (sin sellar).'); process.exit(0); }

const PROPIOS = /(\/src\/(?:app\.css|supabase\.js|visitas\.js|sentry\.js))(\?v=[\w.-]+)?/g;
for (const pagina of paginas) {
  const html = readFileSync(pagina, 'utf8');
  const sellado = html.replace(PROPIOS, `$1?v=${ver}`).replace(/data-version="[^"]*"/, `data-version="${ver}"`);
  if (sellado !== html) writeFileSync(pagina, sellado);
}
// Imports relativos entre módulos propios: misma versión, para no crear dos instancias del mismo módulo.
for (const mod of modulos) {
  const ruta = 'src/' + mod;
  const js = readFileSync(ruta, 'utf8');
  const sellado = js.replace(/(from\s*'\.\/(?:supabase|visitas)\.js)(\?v=[\w.-]+)?'/g, `$1?v=${ver}'`);
  if (sellado !== js) writeFileSync(ruta, sellado);
}
console.log(`✔ Versión ${ver} sellada en ${paginas.length} páginas; imports validados.`);
