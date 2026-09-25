# mobventa — contexto para Claude

Plataforma de venta de muebles, electrodomésticos y electrónica por cambio de casa.
Sitio estático (HTML + ES modules) en **Netlify**, datos en **Supabase**. Detalle técnico en `README.md` y `docs/`.

## Accesos directos

| Qué | Cómo |
| --- | --- |
| Panel de administración | `preview_start {name: "mobventa-admin"}` → https://mobventa.netlify.app/admin |
| Catálogo público | `preview_start {name: "mobventa-catalogo"}` → https://mobventa.netlify.app/ |
| Base de datos | MCP de Supabase, proyecto **venta**, ref `bxsldfwlbagvgxxhtfwc` (us-east-1, Postgres 17) |
| Errores en producción | MCP de Sentry, organización `agencements` (región `https://de.sentry.io`), proyectos `mobventa-web` (navegador) y `mobventa-functions` (funciones Netlify) |
| Código | este repo, rama `main`, remoto `github.com/jcastillose/venta`; Netlify despliega en cada push |

La sesión del panel la inicia Jorge en el navegador integrado (correo + contraseña o enlace por correo). Claude nunca escribe credenciales.

## Mapa del sistema

| Pantalla | Archivo | Ruta |
| --- | --- | --- |
| Catálogo | `index.html` | `/` |
| Detalle, interés y oferta | `producto.html` | `/p/<id>` |
| Hilo privado del interesado | `c.html` | `/c/<token>` |
| Recuperar conversaciones | `mis-conversaciones.html` | `/mis-conversaciones` |
| Panel del equipo | `admin.html` | `/admin` (acceso, productos, editor de fotos, interesados, cobros, equipo, ajustes, mi cuenta) |

- `src/supabase.js`: cliente, constantes, utilidades. `src/visitas.js`: registro de visitas.
- `netlify/lib/sentry.js`: `withSentry` y `reportar` para las funciones; `src/sentry.js`: configuración del loader de Sentry en el navegador.
- `netlify/functions/`: `cuentas.js` (cuentas, solo admin), `avisos.js` (correos Resend), `recuperar.js`, `visita.js`.
- `supabase/`: `000-base-completa.sql` crea o repara todo y es re-ejecutable; luego migraciones 008 a 016 en orden y `bootstrap-admin.sql`.
- RPC que usa el panel: `activar_invitacion`, `close_deal`, `confirm_payment`, `delete_category`, `delete_interest`, `delete_product`, `discard_interest`, `reopen_interest`, `set_offers_for_all`, `visits_summary`.

## Revisión de coherencia y funcionamiento

Orden sugerido al revisar:

1. **Panel** (`mobventa-admin`): recorrer cada pestaña, leer consola y red del navegador integrado, anotar errores o datos incoherentes.
2. **Base** (MCP Supabase): `list_tables`, `get_advisors` (seguridad y rendimiento), `query_logs` si hay fallos; comparar con las migraciones del repo.
3. **Código**: contrastar lo que hace `admin.html` con las RPC y políticas RLS definidas en `supabase/`.
4. **Flujo público**: catálogo → detalle → marcar interés → hilo `/c/<token>` → oferta y pago.

## Reglas

- **Solo lectura por defecto.** Ningún cambio en la base de Supabase, en Netlify ni push a `main` sin autorización explícita de Jorge en el chat.
- Consultas SQL de revisión: solo `select`. Migraciones o `apply_migration` requieren autorización y respaldo previo.
- Nada de claves en el chat: la `service_role` vive solo en variables de entorno de Netlify.
- Hallazgos en español, con referencia a archivo y línea.
