# Rendimiento — decisiones y mantenimiento

## Librería de Supabase autoalojada
`src/vendor/supabase-js-<versión>.js` es supabase-js empaquetado en un solo archivo (antes: 10 peticiones en cascada a esm.sh). Se sirve inmutable un año (`netlify.toml`), por eso la versión va en el nombre. Para actualizarla:

```sh
mkdir -p /tmp/sbpack && cd /tmp/sbpack && npm init -y >/dev/null
npm install @supabase/supabase-js@<versión> esbuild
npx esbuild node_modules/@supabase/supabase-js/dist/module/index.js \
  --bundle --format=esm --platform=browser --target=es2022 --minify --legal-comments=none \
  --outfile=<repo>/src/vendor/supabase-js-<versión>.js
```
Luego cambiar el import en `src/supabase.js` y los `modulepreload` de las cinco páginas.

## Fotos
- Al subir, el panel guarda el original (≤1600 px) y una miniatura `-s.jpg` (≤640 px) con caché de un año (`cacheControl`). `product_photos.thumb_path` la referencia; si es nula, las páginas usan el original.
- Ajustes → «Generar miniaturas» crea las que falten (fotos anteriores a esta versión) y reduce el logo a 640 px.
- La vista `catalog` devuelve `cover`, `cover_thumb` y `photo_count`: el catálogo es una sola consulta.

## Base de datos (migraciones 020 y 021)
- `product_stats`: interesados, nº de ofertas y oferta máxima por producto, mantenidos por triggers de sentencia. `catalog`, `thread_by_token` y `place_offer_by_token` leen de ahí.
- Políticas RLS con `(select f())`: se evalúan una vez por consulta, no por fila.
- Realtime publica solo `products`, `categories`, `site_settings`. El catálogo público no abre websocket: se refresca al volver a la pestaña.
- pg_cron: `purgar-visitas` (180 días) y `purgar-net` (7 días de respuestas de webhooks).

## Caché HTTP (netlify.toml)
- `/src/vendor/*`: inmutable un año. `/src/*.png`: un día. HTML, CSS y JS propios: revalidación con ETag (sin versión en la URL no se pueden cachear más sin riesgo de desfase tras un despliegue).
- `/marca/logo.png`: 5 min en navegador, 5 min en el borde con revalidación en segundo plano, ETag reenviado (304).

## Qué se rompe primero al crecer
1. Egreso de Supabase Storage (5 GB/mes en el plan gratuito): mitigado con miniaturas y caché de un año.
2. Invocaciones de funciones de Netlify (125k/mes): `visita.js` recibe un POST por vista. Siguiente paso: un beacon por sesión y muestreo.
3. Conexiones Realtime (200): el catálogo ya no las usa.
4. Peticiones REST del catálogo a 1M visitas: siguiente paso, servirlo como JSON desde una función cacheada en el borde (patrón de `marca.js`).
