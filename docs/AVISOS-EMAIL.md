# Avisos por correo — Netlify Function + Resend

La función `site/netlify/functions/avisos.js` envía cuatro correos:

| Cuándo | A quién | Contenido |
| --- | --- | --- |
| Alguien marca interés | al interesado (si dejó correo) | su enlace privado `/c/<token>` |
| Alguien marca interés | a todas las cuentas activas del equipo | quién, qué producto, su contacto |
| Alguien avisa un pago | al equipo | monto, medio, referencia y link a Cobros |
| Una persona invitada activa su cuenta | a los administradores activos (menos quien activó) | nombre, correo, rol y link a Equipo |

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
| `MAIL_FROM` | `Nombre visible <avisos@tudominio.cl>`, p. ej. `Oferta de Muebles y Electrodomésticos <admin@contact.agencements.net>` (o `onboarding@resend.dev` para probar). Lo que va antes de `<` es el nombre que ve quien recibe el correo. |
| `AVISOS_SECRET` | una frase larga que inventes, ej. `mv-avisos-9f2c81b07d` |
| `SUPABASE_URL` | `https://bxsldfwlbagvgxxhtfwc.supabase.co` |
| `SUPABASE_SERVICE_ROLE_KEY` | la clave `service_role` de Supabase |

Vuelve a desplegar después de guardarlas (Deploys → *Trigger deploy → Clear cache and deploy site*): las funciones leen las variables al desplegarse.

## 3. Webhooks en Supabase

Supabase → **Database → Webhooks → Create a new hook**. Crea **tres**, idénticos salvo la tabla y el evento:

**Hook 1 — interés nuevo**

- Name: `aviso-interes`
- Table: `public.interests`
- Events: solo **Insert**
- Type: **HTTP Request**
- Method: `POST`
- URL: `https://mobventa.netlify.app/.netlify/functions/avisos`
- HTTP Headers → *Add new header*:
  - `Content-Type` → `application/json`
  - `x-avisos-secret` → el mismo valor de `AVISOS_SECRET`

**Hook 2 — pago declarado**

Igual, pero Name `aviso-pago` y Table `public.payments`.

**Hook 3 — cuenta activada**

Igual, pero Name `aviso-cuenta`, Table `public.members` y Events: solo **Update**. La función solo envía correo cuando el estado pasa de `invitado` a `activo` (el resto de actualizaciones, como `last_seen`, se ignoran).

El header secreto es lo que impide que cualquiera dispare correos llamando la URL.

## 4. Probar

1. Entra al catálogo, abre un producto y marca interés con un correo tuyo.
2. Deberías recibir el correo con el enlace, y otro a tu cuenta del equipo.
3. En **Interesados** reserva; desde el enlace del interesado avisa un pago; llega el correo de "Pago por confirmar".
4. En **Equipo** invita a un correo tuyo y abre el enlace: a los administradores les llega "Cuenta activada".

Si no llega nada:

- Netlify → **Logs → Functions → avisos**: ahí aparece el error exacto de Resend.
- Supabase → **Database → Webhooks → tu hook → Logs**: muestra el código de respuesta. Un `403` significa que el header `x-avisos-secret` no coincide.
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
