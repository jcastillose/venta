# Avisos por correo — Netlify Function + Resend

La función `site/netlify/functions/avisos.js` envía cinco correos:

| Cuándo | A quién | Contenido |
| --- | --- | --- |
| Alguien marca interés | al interesado (si dejó correo) | su enlace privado `/c/<token>` |
| Alguien marca interés | a todas las cuentas activas del equipo | quién, qué producto, su contacto |
| Alguien avisa un pago | al equipo | monto, medio, referencia y link a Cobros |
| Una persona invitada activa su cuenta | a los administradores activos (menos quien activó) | nombre, correo, rol y link a Equipo |
| El equipo responde en un hilo | al interesado (si dejó correo) | extracto del mensaje y botón «Abrir la conversación» a su enlace privado. Un solo correo por ráfaga: si el equipo ya escribió en los 10 minutos anteriores, no se repite. |

Si la persona dejó un WhatsApp en vez de correo, no se le envía nada (el aviso al equipo lo dice) y el enlace se le pasa desde el hilo.

## 1. Resend

1. Crear cuenta en [resend.com](https://resend.com).
2. **Domains → Add Domain**: agrega tu dominio y copia los registros DNS (SPF, DKIM) donde lo administras. Sin dominio propio puedes probar con el remitente de pruebas `onboarding@resend.dev`, pero solo llega a tu propia dirección registrada.
3. **API Keys → Create API Key** (permiso *Sending access*). Copia la clave `re_...`; se muestra una sola vez.

## 2. Variables de entorno en Netlify

Site configuration → Environment variables:

| Variable | Valor |
| --- | --- |
| `RESEND_API_KEY` | `re_...` |
| `MAIL_FROM` | `Nombre visible <remitente@dominio-verificado>`. Valor en uso: `Contacto Venta <admin@contact.agencements.net>` (dominio `contact.agencements.net` verificado en Resend). Debe coincidir con `CORREO_AVISOS` en `src/supabase.js`, que es la dirección que el sitio muestra a los interesados. Lo que va antes de `<` es el nombre que ve quien recibe el correo. |
| `AVISOS_SECRET` | una frase larga y aleatoria (p. ej. la salida de `openssl rand -hex 24`). No la escribas en ningún archivo del repo. |
| `SUPABASE_URL` | `https://bxsldfwlbagvgxxhtfwc.supabase.co` |
| `SUPABASE_SERVICE_ROLE_KEY` | la clave `service_role` de Supabase |

Vuelve a desplegar después de guardarlas (Deploys → *Trigger deploy → Clear cache and deploy site*): las funciones leen las variables al desplegarse.

## 3. Disparadores en Supabase (por SQL)

La interfaz de webhooks puede fallar («schema supabase_functions does not exist»), así que los avisos se crean por SQL. Abre **SQL Editor** y ejecuta, en este orden: (1) `select vault.create_secret('<valor de AVISOS_SECRET>', 'avisos_secret');` (2) `supabase/014-aviso-respuesta.sql` tal cual, para los triggers; (3) `supabase/018-avisos-vault.sql`, que deja `aviso_webhook()` leyendo el secreto desde Vault. Quedan la función y cuatro triggers:

| Trigger | Tabla | Evento |
| --- | --- | --- |
| `aviso-interes` | `interests` | Insert |
| `aviso-pago` | `payments` | Insert |
| `aviso-cuenta` | `members` | Update |
| `aviso-respuesta` | `messages` | Insert, solo si `sender = 'vendedor'` |

La última consulta del archivo debe devolver esas cuatro filas. Para ver qué respondió Netlify a cada disparo (últimas 6 h):

```sql
select status_code, error_msg, left(content,200), created
from net._http_response order by created desc limit 10;
```

El header secreto es lo que impide que cualquiera dispare correos llamando la URL.

## 4. Probar

1. Entra al catálogo, abre un producto y marca interés con un correo tuyo.
2. Deberías recibir el correo con el enlace, y otro a tu cuenta del equipo.
3. En **Interesados** reserva; desde el enlace del interesado avisa un pago; llega el correo de "Pago por confirmar".
4. En **Equipo** invita a un correo tuyo y abre el enlace: a los administradores les llega "Cuenta activada".
5. En el chat de ese interesado escribe una respuesta: al correo del interesado llega "Respuesta sobre …" con el botón para abrir el hilo.

Si no llega nada:

- Netlify → **Logs → Functions → avisos**: ahí aparece el error exacto de Resend.
- Supabase → SQL Editor → la consulta de `net._http_response` de arriba. Un `403` significa que el secreto del trigger no coincide con `AVISOS_SECRET`; sin filas, el trigger no disparó.
- Resend → **Emails**: lista cada envío con su estado (entregado, rebotado, bloqueado).

## Costos

Resend tiene un plan gratuito de 3.000 correos al mes / 100 por día, suficiente de sobra para este uso. Las funciones de Netlify entran en el plan gratuito (125.000 invocaciones al mes).

## Extra opcional: mejorar el correo de acceso del equipo

El enlace mágico del login lo envía Supabase con su SMTP de pruebas (pocos envíos por hora, a veces cae en spam). Para usar Resend también ahí:

Supabase → **Project Settings → Authentication → SMTP Settings**:

- Host: `smtp.resend.com`
- Port: `465`
- User: `resend`
- Password: tu `RESEND_API_KEY`
- Sender email / name: los mismos de `MAIL_FROM`
