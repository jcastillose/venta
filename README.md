# mobventa — venta.hogar

Plataforma de venta de muebles, electrodomésticos y electrónica de hogar.
Sitio estático (HTML + ES modules) desplegado en **Netlify**, datos en **Supabase**.

- Producción: https://mobventa.netlify.app
- Supabase: https://bxsldfwlbagvgxxhtfwc.supabase.co

## Estructura

| Ruta | Pantalla |
| --- | --- |
| `index.html` | catálogo público |
| `producto.html` (`/p/<id>`) | detalle, marcar interés y ofertar |
| `c.html` (`/c/<token>`) | hilo privado del interesado, oferta y pago |
| `admin.html` | acceso, productos, editor de fotos, interesados, cobros, equipo, ajustes, mi cuenta |
| `src/supabase.js` | cliente, constantes y utilidades |
| `src/app.css` | estilos |
| `netlify/functions/cuentas.js` | crear, editar y eliminar cuentas (solo administrador) |
| `netlify/functions/avisos.js` | avisos por correo con Resend (opcional) |
| `supabase/` | migraciones SQL, en orden |

## Base de datos

Ejecutar en el SQL Editor de Supabase, en orden:

1. `supabase/schema.sql`
2. `supabase/002-ofertas.sql`
3. `supabase/003-ajustes.sql`
4. `supabase/004-categorias.sql`
5. `supabase/005-titulo.sql`
6. `supabase/bootstrap-admin.sql` (primera cuenta de administrador; editar correo, nombre y contraseña antes)

Todos son re-ejecutables.

## Sentry (errores en producción)

Organización `agencements` (región EU). Dos proyectos:

| Proyecto | Qué captura | Cómo se activa |
| --- | --- | --- |
| `mobventa-web` | errores JavaScript en las cinco páginas | `src/sentry.js` + loader de Sentry (`js-de.sentry-cdn.com`, región EU) en el `<head>` de cada HTML (solo errores, sin trazas ni replay; los enlaces `/c/<token>` se ocultan antes de enviar) |
| `mobventa-functions` | excepciones en las funciones de Netlify | `netlify/lib/sentry.js`; cada función exporta `withSentry('nombre', handler)`. Lee `SENTRY_DSN_FUNCTIONS` de las variables de entorno de Netlify; sin ella no envía nada |

Panel: https://agencements.sentry.io

## Netlify

Base directory y Publish directory: raíz del repo (`.`); sin build command. `netlify.toml` ya trae las rutas `/p/*` y `/c/*`.

Variables de entorno:

| Variable | Uso |
| --- | --- |
| `SUPABASE_URL` | functions |
| `SUPABASE_SERVICE_ROLE_KEY` | functions (nunca en el cliente) |
| `RESEND_API_KEY`, `MAIL_FROM`, `AVISOS_SECRET` | solo si se activan los avisos por correo |

Guías completas en `docs/`.
