# Despliegue — mobventa

Datos ya configurados en el código:

- Supabase: `https://bxsldfwlbagvgxxhtfwc.supabase.co` (URL + clave `anon` en `site/src/supabase.js`)
- Netlify: `https://mobventa.netlify.app`

## 1. Base de datos

Supabase → SQL Editor → pegar completo `docs/supabase/schema.sql` → Run.
Crea tablas, vistas, políticas RLS, funciones RPC, el bucket `fotos` y los permisos de `anon`.

### Migración 002 — ofertas

Después de `schema.sql`, correr también `docs/supabase/002-ofertas.sql`: crea la tabla `offers`, la vista pública `offer_summary` (solo monto máximo y cantidad, sin nombres) y actualiza `catalog`, `create_interest` y `thread_by_token`.

### Migración 003 — ajustes

Correr `docs/supabase/003-ajustes.sql`: crea `site_settings` con dos interruptores que el administrador maneja desde **Ajustes**: `ofertas_habilitadas` (los interesados pueden ofertar) y `ofertas_publicas` (la oferta más alta se muestra en catálogo, detalle e hilos). La vista `catalog` y las RPC respetan ambos.

## 2. Auth

**Authentication → Sign In / Providers → Email**:

- **Enable email provider** → encendido (habilita el enlace por correo).
- **Enable email + password** / *Allow password sign in* → **encendido**: permite el ingreso con contraseña.
- **Minimum password length** → 8.
- **Confirm email** → encendido. *Save*.

No existe un interruptor llamado "Magic Link": viene incluido en el proveedor Email.

**Authentication → URL Configuration**:

- Site URL: `https://mobventa.netlify.app`
- Redirect URLs: `https://mobventa.netlify.app/admin.html` y `https://mobventa.netlify.app/**`

### Los dos modos de ingreso

`/admin.html` ofrece **Contraseña** y **Enlace por correo**. La contraseña la crea cada persona desde **Mi cuenta** (mínimo 8 caracteres); nadie se la asigna. Como el correo gratuito de Supabase permite pocos envíos por hora, la primera entrada usa el enlace y desde ahí conviene crear la contraseña de inmediato.

*Olvidé mi contraseña* envía un correo de recuperación que vuelve a `/admin.html` y muestra la pantalla para elegir una nueva.

## 3. Primera cuenta de administrador

1. Entrar a `https://mobventa.netlify.app/admin.html` → pestaña *Enlace por correo* → abrir el enlace del mail.
2. En SQL Editor, subir esa cuenta a admin:

```sql
update public.members set role = 'admin', status = 'activo'
 where email = 'TU-CORREO@dominio.cl';
```

Si el correo no aparece en `members` (usuario creado antes del trigger), insértalo:

```sql
insert into public.members (id, name, email, role, status)
select u.id, coalesce(u.raw_user_meta_data->>'name', split_part(u.email,'@',1)),
       u.email, 'admin', 'activo'
from auth.users u where u.email = 'TU-CORREO@dominio.cl'
on conflict (id) do update set role = 'admin', status = 'activo';
```

3. Ya dentro, ir a **Mi cuenta** y crear la contraseña: los ingresos siguientes no dependen del correo.

Desde ahí las demás cuentas se crean en la pantalla **Equipo** → *Nueva cuenta*, de dos formas:

- **Con contraseña inicial** (recomendada mientras no haya SMTP propio): la cuenta queda activa al instante; le comunicas la contraseña y la persona la cambia en **Mi cuenta**.
- **Invitación por correo**: recibe un enlace; consume el límite de correos de Supabase.

El administrador también puede **editar** (nombre, correo, rol, contraseña), **suspender/reactivar** y **eliminar** cualquier cuenta. Al eliminar, los productos que publicó esa persona pasan al administrador que la elimina. No se puede eliminar al único administrador activo ni la propia cuenta.

## 4. Datos de cobro

Pantalla **Cobros → Datos de cobro** (como administrador): completar Prex, MercadoPago y transferencia.
Lo que se escriba ahí es exactamente lo que ve quien va a pagar. Un medio sin datos conviene dejarlo *Desactivado*.

## 5. Netlify

Site configuration → Build & deploy:

- Repository: `jcastillose/venta`, branch `main`
- Base directory: `site`
- Publish directory: `site`
- Build command: vacío (es HTML estático)

Environment variables (necesarias para crear, editar y eliminar cuentas desde la pantalla Equipo):

| Variable | Valor |
| --- | --- |
| `SUPABASE_URL` | `https://bxsldfwlbagvgxxhtfwc.supabase.co` |
| `SUPABASE_SERVICE_ROLE_KEY` | la clave `service_role` de Supabase (Settings → API) |

La `service_role` **solo** vive aquí: nunca en el repo ni en el navegador.
Para que la función `cuentas` instale su dependencia, Netlify usa `site/package.json`.

## 6. Verificación

1. `/` muestra el catálogo (vacío al principio).
2. `/admin.html` → Productos → Publicar producto → guardar → subir fotos.
3. `/` muestra el producto; abrirlo y marcar interés → redirige a `/c/<token>`.
4. En `/admin.html` → Interesados: responder, Reservar.
5. En `/c/<token>`: Pagar → elegir medio → "Ya pagué, avisar".
6. En `/admin.html` → Cobros: Confirmar → el producto queda **vendido**.

## Rutas

| Ruta | Pantalla |
| --- | --- |
| `/` | catálogo público |
| `/p/<id>` | detalle del producto + marcar interés |
| `/c/<token>` | hilo privado del interesado + pago |
| `/admin.html` | acceso, productos, editor, interesados, cobros, equipo, ajustes, mi cuenta |
| `/.netlify/functions/cuentas` | crear, editar y eliminar cuentas (solo admin) |

## 7. Avisos por correo (opcional)

Enlace privado al interesado y avisos al equipo cuando entra un interés o un pago: ver `docs/AVISOS-EMAIL.md` (Netlify Function + Resend + dos webhooks de Supabase).

## Pendiente opcional

- Cobro real con MercadoPago Checkout Pro: crear la preferencia en una function y marcar el pago como `pagado` desde el webhook en lugar de la confirmación manual. Prex y transferencia se mantienen declarativos.
