# venta.hogar — notas de implementación

Stack: **GitHub** (código) → **Netlify** (hosting estático + deploy por push) → **Supabase** (Postgres, Auth, Storage, Realtime).
El prototipo `Venta Hogar 1c.dc.html` es la referencia visual y de flujos; el esquema está en `docs/supabase/schema.sql`.

## Modelo

- `members` — cuentas del equipo, una por usuario de Auth. Rol `admin` o `editor`, estado `activo` / `invitado` / `suspendido`. **Toda cuenta activa edita todos los productos**; `admin` además gestiona cuentas y datos de cobro.
- `products` — título, categoría, descripción, `price_clp`, `status` disponible / reservado / vendido, lugar, condición, `created_by` y `updated_by` (trazabilidad, no propiedad).
- `product_photos` — archivos en el bucket `fotos` (`<product_id>/<uuid>.jpg`); `position 0` es la portada.
- `interests` — "Me interesa" a precio fijo. Sin cuenta: nombre + contacto y un `token`; el enlace `/c/<token>` da acceso al hilo y a la pantalla de pago.
- `messages` — un hilo por interés (equipo ↔ interesado). Realtime activado.
- `payment_settings` — un registro por medio (`prex`, `mercadopago`, `transferencia`) con `enabled` y `details` (jsonb con los campos que ve quien paga).
- `offers` — una oferta por interés (`amount_clp`); la persona puede mejorarla desde su hilo (`place_offer_by_token`). La vista `offer_summary` expone por producto solo `top_offer_clp` y `offer_count`: la oferta más alta es pública, quién la hizo no. El equipo ve todas las ofertas y decide a quién reservar.
- `payments` — un pago por interés: medio, monto, referencia y estado `porconfirmar` / `pagado` / `anulado`.

## Flujos → consultas

| Pantalla | Lectura | Escritura |
| --- | --- | --- |
| Catálogo | `from('catalog').select()` (vista con `published_by` e `interested_count`) | — |
| Detalle | `catalog` + `product_photos` por `position` + `payment_options` | — |
| Me interesa | — | `insert interests` → devuelve `token`; enviar enlace por correo o WhatsApp |
| Chat interesado (`/c/<token>`) | `rpc('thread_by_token')`, `rpc('messages_by_token')` + Realtime | `rpc('send_message_by_token')` |
| Pagar (`/c/<token>`) | `rpc('payment_options_by_token')` — muestra los datos del medio elegido | `rpc('declare_payment_by_token', { p_token, p_method, p_reference })` |
| Acceso equipo | `auth.signInWithOtp({ email })` (enlace mágico) | — |
| Productos | `products` + `members` (cualquier cuenta activa ve y edita todo) | `update products set status`; `upsert products` |
| Editor | producto + fotos | `storage.from('fotos').upload`; `insert/delete product_photos`; portada = reordenar `position` |
| Interesados | `interests` join `products` join `payments` | `rpc('close_deal', { p_interest, p_status: 'reservado' })` |
| Cobros | `payments` join `interests` join `products`; `payment_settings` | `rpc('confirm_payment', { p_interest })`; `update payment_settings` (solo admin) |
| Equipo | `members` | `invite` (ver abajo); `update members set role / status` (solo admin) |

Formato de precio: `new Intl.NumberFormat('es-CL', { style: 'currency', currency: 'CLP' })` → `$180.000`.

## Pagos

Los tres medios son **declarativos**: la plataforma no cobra, muestra los datos y registra el aviso de pago.

1. La persona reserva → en su hilo aparece "Pagar $X".
2. Elige Prex, MercadoPago o transferencia; se muestran los datos de `payment_settings.details` de ese medio.
3. Paga en su banco o app y avisa con `declare_payment_by_token` (referencia opcional). El pago queda `porconfirmar` y se registra un mensaje automático en el hilo.
4. El equipo lo ve en **Cobros** (o en el hilo) y usa `confirm_payment`: el pago pasa a `pagado`, el producto a `vendido` y se envía el mensaje de confirmación.

MercadoPago puede pasar a cobro real sin cambiar el modelo: crear la preferencia con la API de Checkout Pro desde una Netlify Function y usar su webhook para escribir el `payment` como `pagado` en lugar de la confirmación manual. Prex y transferencia se mantienen declarativos.

## Cuentas de usuario

- **Crear**: solo `admin`, vía Netlify Function `cuentas` (`service_role`). Dos modos: `auth.admin.createUser({ email, password, email_confirm: true })` para una cuenta lista con contraseña inicial, o `auth.admin.inviteUserByEmail` para invitación por correo. La función escribe la fila en `members` con nombre, rol y estado.
- **Editar**: nombre, correo, rol, contraseña y estado; correo y contraseña pasan por `auth.admin.updateUserById`. Un admin no puede quitarse el rol ni suspenderse a sí mismo.
- **Suspender**: `update members set status = 'suspendido'`. `is_member()` deja de validarla y toda escritura queda bloqueada por RLS sin borrar su historial.
- **Cambiar rol**: `update members set role = 'admin' | 'editor'` (solo admin).
- **Eliminar**: la función reasigna `products.created_by` al administrador que elimina, limpia `updated_by` / `confirmed_by`, y borra el usuario en Auth (`members` cae en cascada). Bloqueado para la propia cuenta y para el último administrador activo.
- Las políticas se apoyan en `is_member()` e `is_admin()`, así que agregar cuentas no exige tocar ninguna política.

## Estructura sugerida del repo

```
/
├─ index.html            catálogo
├─ p/[id]                detalle
├─ c/[token]             hilo + pantalla de pago del interesado
├─ admin/                acceso, productos, editor, interesados, cobros, equipo
├─ src/supabase.js       createClient(SUPABASE_URL, SUPABASE_ANON_KEY)
├─ netlify/functions/    invitar-usuario.js (service_role), mercadopago-webhook.js
├─ netlify.toml
└─ supabase/migrations/  schema.sql versionado
```

La clave `anon` puede ir en el cliente: la seguridad la dan las políticas RLS. La `service_role` **solo** en variables de entorno de Netlify Functions.

## Netlify

```toml
[build]
  command = "npm run build"   # omitir si es HTML plano
  publish = "dist"            # o "." para HTML plano

[[redirects]]
  from = "/*"
  to = "/index.html"
  status = 200
```

Variables de entorno (Site settings → Environment): `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`, y para las functions `SUPABASE_SERVICE_ROLE_KEY`, `MP_ACCESS_TOKEN`.
Conectar el repo `jcastillose/venta`: cada push a `main` despliega; los PR generan deploy previews.

## Supabase

1. Crear proyecto → SQL Editor → pegar `schema.sql`.
2. Auth → Providers → Email: activar "Magic Link". Añadir el dominio de Netlify a *Redirect URLs*.
3. Crear la primera cuenta y subirla a `admin`: `update public.members set role = 'admin' where email = '…';`
4. Completar `payment_settings.details` con los datos reales de Prex, MercadoPago y la cuenta bancaria.
5. Storage: el bucket `fotos` lo crea el script (lectura pública; escritura para cuentas activas).
6. Opcional: Database Webhook sobre `interests` y `payments` para avisar al equipo por correo.

## Reglas de negocio que replican el prototipo

- Los vendidos siguen visibles en el catálogo con etiqueta; se muestran al 55 % de opacidad y el orden es disponibles → reservados → vendidos.
- Marcar interés no bloquea el producto; el equipo decide a quién reservar. Al reservar, producto e interés pasan a `reservado`; el pago confirmado los pasa a `vendido`.
- Un interesado puede marcar varios productos; cada uno es un hilo independiente con su propio token y su propio pago.
- Edición de fotos: subir varias, quitar, elegir portada. Al eliminar una foto borrar también el objeto en Storage.
- Desactivar un medio de pago lo oculta de la pantalla de pago sin borrar sus datos.
