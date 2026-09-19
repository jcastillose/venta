# Despliegue — mobventa

Datos ya configurados en el código:

- Supabase: `https://bxsldfwlbagvgxxhtfwc.supabase.co` (URL + clave `anon` en `site/src/supabase.js`)
- Netlify: `https://mobventa.netlify.app`

## 1. Base de datos

Supabase → SQL Editor → pegar completo `docs/supabase/schema.sql` → Run.
Crea tablas, vistas, políticas RLS, funciones RPC, el bucket `fotos` y los permisos de `anon`.

### Migración 002 — ofertas

**Camino corto (recomendado):** correr `supabase/000-base-completa.sql` una sola vez. Crea o repara todo (tablas, RLS, RPC, vistas, bucket, semillas, realtime) e imprime un informe ok / FALTA. Equivale a `schema.sql` + 002…007 y es re-ejecutable sobre una base con datos. Luego `bootstrap-admin.sql`.

**Camino por pasos** (histórico): después de `schema.sql`, correr también `docs/supabase/002-ofertas.sql`: crea la tabla `offers`, la vista pública `offer_summary` (solo monto máximo y cantidad, sin nombres) y actualiza `catalog`, `create_interest` y `thread_by_token`.

### Migración 003 — ajustes

Correr `docs/supabase/003-ajustes.sql`: crea `site_settings` con dos interruptores que el administrador maneja desde **Ajustes**: `ofertas_habilitadas` (los interesados pueden ofertar) y `ofertas_publicas` (la oferta más alta se muestra en catálogo, detalle e hilos). La vista `catalog` y las RPC respetan ambos.

### Migración 004 — categorías y condición

Correr `supabase/004-categorias.sql`: pasa las categorías a la tabla `categories` (el administrador las crea, renombra y elimina desde **Ajustes**; renombrar actualiza los productos en cascada; eliminar solo si no tiene productos) y cierra el campo `condicion` a siete valores que el editor muestra como desplegable.

### Migración 005 — título del sitio

Correr `supabase/005-titulo.sql`: agrega la clave `titulo_sitio` en `site_settings`. El administrador lo edita en **Ajustes → Nombre del sitio** y se aplica a la barra y a la pestaña de todas las páginas.

### Migración 006 — ofertas por producto

Correr `supabase/006-ofertas-por-producto.sql`: agrega `products.accepts_offers` (por defecto activo). Lo que rige en cada producto es este campo: se cambia desde **Productos** (columna Ofertas) o en el editor. El interruptor **Ajustes → Permitir ofertas en todos los productos** pasa a ser masivo: la RPC `set_offers_for_all` actualiza el ajuste y el estado de todos los productos a la vez (el panel pide confirmación y advierte cuántos cambian) y queda como valor por defecto para los productos nuevos. `create_interest`, `place_offer_by_token` y `thread_by_token` respetan el campo del producto.

### Migración 007 — verificación y saneamiento

Correr `supabase/007-verificacion.sql` al final (y cada vez que se dude del estado de la base). Corrige: sobrecarga duplicada de `create_interest`, lectura pública de `members` (exponía correos), inserción directa en `interests`, claves de auditoría sin `on delete set null` (impedían eliminar cuentas), ajustes y categorías base faltantes, realtime. Al terminar imprime una tabla con cada objeto que usa el sitio y `ok` / `FALTA`. Cualquier `FALTA` indica qué migración volver a correr.

**No volver a correr `schema.sql` después de 004**: su vista `catalog` tiene menos columnas y falla; los cambios posteriores viven en las migraciones.

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

Correr `supabase/bootstrap-admin.sql` con tu correo, nombre y una contraseña temporal: crea la cuenta en Auth si no existe, la marca como administrador activo y fija la contraseña. Entrar con **Contraseña** y cambiarla en **Mi cuenta**. No hace falta pasar por el correo.

Nota: "Enlace por correo" solo funciona para correos que ya tienen cuenta en el equipo (`shouldCreateUser: false`); un correo desconocido recibe el aviso de pedir la cuenta a un administrador. Las cuentas invitadas nacen en estado *invitado* y pasan a *activo* solas al abrir el enlace por primera vez.

Camino alternativo (histórico):
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

### Lista de coherencia entre plataformas (cuando el primer ingreso falla)

**Supabase → Authentication → URL Configuration**
- Site URL: `https://mobventa.netlify.app` (sin barra final).
- Redirect URLs: `https://mobventa.netlify.app/admin.html` y `https://mobventa.netlify.app/**`. Si faltan, el correo vuelve a la Site URL sin sesión o falla con "redirect_to is not allowed".

**Supabase → Authentication → Email Templates**
- *Invite user*, *Magic Link* y *Reset Password* deben contener `{{ .ConfirmationURL }}`. Si se editaron y perdieron la variable, el correo llega sin enlace.
- Conviene que el asunto diga el nombre del sitio para que no caiga en spam.

**Supabase → Authentication → Providers → Email**
- Email habilitado; *Confirm email* encendido; *Secure email change* por defecto. Minimum password length 8.

**Supabase → Project Settings → Auth → SMTP**
- Sin SMTP propio el remitente es `noreply@mail.app.supabase.io`, con límite de ~3–4 correos por hora y frecuente caída en spam. Para uso real configurar Resend/Brevo/Gmail y verificar el dominio remitente. Mientras no exista, crear cuentas **con contraseña inicial**.

**Supabase → Project Settings → API**
- URL del proyecto y `anon public` = `SUPABASE_URL`/`SUPABASE_ANON_KEY` en `site/src/supabase.js`.
- `service_role` = `SUPABASE_SERVICE_ROLE_KEY` en Netlify. Los tres deben ser del **mismo** proyecto.

**Supabase → SQL Editor**
- `000-base-completa.sql` ejecutado; el informe final con `ok` en `handle_new_user`, `on_auth_user_created`, `activar_invitacion` y "al menos un administrador activo".
- Authentication → Users: el correo debe aparecer y, si va a usar contraseña, con *Email confirmed*.

**Netlify → Site configuration**
- Environment variables: `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` sin espacios ni comillas. Tras cambiarlas: Deploys → *Clear cache and deploy site*.
- Functions: `cuentas`, `avisos`, `recuperar` y `visita` listadas. Si no aparecen, revisar `netlify.toml` y `netlify/functions/package.json`.
- Domain: si algún día se usa dominio propio, agregarlo también en Redirect URLs de Supabase y en `SITE_URL` de `supabase.js`.

**GitHub**
- `main` debe contener la misma versión de `admin.html`, `src/supabase.js`, `netlify/functions/cuentas.js` y `supabase/000-base-completa.sql` que este zip.

**Navegador y correo**
- El enlace sirve una vez y caduca en una hora. Algunos clientes de correo o antivirus lo "visitan" antes y lo consumen: usar *Reenviar enlace* en Equipo o entrar con contraseña.
- Abrir el enlace en el navegador donde se va a trabajar (no en la vista previa del cliente de correo).
- Si aparece "Cuenta invitado", el panel publicado está desactualizado: subir la versión nueva de `admin.html`.

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

Enlace privado al interesado, avisos al equipo cuando entra un interés o un pago, aviso a los administradores cuando una persona invitada activa su cuenta, y aviso al interesado cuando el equipo le responde (con botón para abrir y continuar su conversación): ver `docs/AVISOS-EMAIL.md` (Netlify Function + Resend + triggers creados con `supabase/014-aviso-respuesta.sql`, donde hay que poner el secreto).

## 8. Fotos

No hay que preparar las fotos antes de subirlas. Al elegirlas en el editor, el navegador las redimensiona (lado mayor 1600 px, JPEG al 86 %, orientación corregida) y sube esa versión; una foto de celular de 4–6 MB queda en 200–400 KB. Si el navegador no puede leer el archivo (HEIC de iPhone en Chrome/Windows), el editor lo avisa: exportarla como JPG y volver a subirla. En iPhone, Ajustes → Cámara → Formatos → *Más compatible* evita el problema.

En catálogo, ficha y editor la foto se ve **completa** dentro de su cuadro (sin recortes), sobre una copia desenfocada de sí misma que rellena el fondo. Las miniaturas pequeñas (tabla, chat, tira de la galería) siguen recortadas al cuadrado porque a ese tamaño solo sirven para reconocer el producto.

Las fotos subidas antes de este cambio se reducen con **Optimizar fotos existentes**, en el editor de cada producto (debajo de la cuadrícula de fotos): descarga cada una, la redimensiona en el navegador, la sube de nuevo y borra la original. Orden y portada se conservan; las que ya pesaban poco se dejan igual. Para que la descarga funcione, el bucket `fotos` debe permitir CORS desde el sitio (Supabase lo hace por defecto en buckets públicos).

## 9. Moderación de conversaciones (008)

Cualquier cuenta activa del equipo (administrador o editor) puede, desde el chat de un interesado:

- **Borrar un mensaje**: icono de papelera al pasar el cursor sobre la hora del mensaje (siempre visible en pantallas táctiles). Pide confirmación; el mensaje desaparece también en el enlace privado de la persona.
- **Descartar** al interesado: cierra su conversación (ya no puede escribir, ofertar ni pagar), retira su oferta del ranking público, anula pagos no confirmados y, si estaba reservado, el producto vuelve a *Disponible*. Se le muestra un mensaje de cierre editable. Los descartados salen de la bandeja *Todos* y quedan en la pestaña **Descartados**, desde donde se puede **Reabrir**.

- **Eliminar conversación** (papelera junto a *Conversar* en la bandeja, incluida la pestaña *Descartados*, y al pie del chat): borra el interés con sus mensajes, oferta y pago, y libera el producto si estaba reservado. El enlace privado deja de funcionar. No se permite si el pago ya fue confirmado. RPC `delete_interest` (010).
- **Datos de contacto** en el chat: franja bajo el encabezado con nombre, correo (enlace *mailto*) o teléfono (enlace *tel* y botón WhatsApp), fecha del interés y cantidad de mensajes.

Requiere ejecutar `supabase/008-moderacion.sql` y `010-eliminar-interes.sql` (ya incluidos en `000-base-completa.sql`, bloques 6b y 6d).

## 10. Mis conversaciones (009)

Página pública `/mis-conversaciones` (enlace en la barra superior de catálogo, ficha y hilo):

- Muestra los hilos abiertos **en este dispositivo** (guardados en el navegador).
- **¿Desde otro dispositivo?**: la persona escribe el correo con que marcó interés; la función `netlify/functions/recuperar.js` busca sus intereses (menos los descartados) y le envía por Resend un correo con un botón *Abrir* por conversación. En pantalla siempre se muestra el mismo mensaje, exista o no el correo, para que nadie pueda sondear correos ajenos.
- Tope de 3 solicitudes por correo cada hora (tabla `recovery_requests` + RPC `recovery_allowed`, solo `service_role`).
- Quien dejó teléfono en vez de correo no recibe nada: el equipo le reenvía el enlace privado por WhatsApp (aparece al pie del chat en el panel).

Requiere `supabase/009-recuperar.sql` (incluido en `000-base-completa.sql`, bloque 6c). La función usa las mismas variables de entorno que `avisos.js`; no necesita webhook.

## Pendiente opcional

- Cobro real con MercadoPago Checkout Pro: crear la preferencia en una function y marcar el pago como `pagado` desde el webhook en lugar de la confirmación manual. Prex y transferencia se mantienen declarativos.

## 11. Visibilidad por producto (011)

En el editor de cada producto, campo **Visibilidad**: *Visible en el catálogo* (por defecto) u *Oculto (solo el equipo lo ve)*. Un producto oculto no aparece en el catálogo ni abre su ficha pública, y nadie puede marcar interés en él; los hilos ya abiertos siguen funcionando. En la tabla de Productos se marca con la etiqueta **Oculto**. Útil para preparar una publicación o retirarla sin borrarla.

Requiere `supabase/011-visibilidad.sql` (incluido en `000-base-completa.sql`: columna `products.is_public`, vista `catalog`, política de lectura y `create_interest`).

## 12. Medidas y borrado por el interesado (012)

- **Medidas**: en el editor de producto, cuatro campos opcionales (ancho, alto, profundidad en cm; peso en kg). La ficha pública muestra solo los completados: «Medidas 120 × 80 × 45 cm · ancho × alto × prof.» y «Peso 32 kg».
- **Borrar conversación**: al pie de su hilo, la persona puede borrarlo (mensajes, oferta y enlace); si estaba reservado, el producto vuelve a *Disponible*. No se permite si el pago ya fue confirmado ni si el producto está vendido. En *Mis conversaciones* la **×** solo la quita de ese dispositivo, sin borrarla. RPC `delete_thread_by_token`.

Requiere `supabase/012-medidas-borrar-hilo.sql` (incluido en `000-base-completa.sql`).

## 13. Nombre del remitente de los correos

El nombre visible («venta.hogar») vive en la variable `MAIL_FROM` de Netlify, con el formato `Nombre visible <correo>`. Para cambiarlo: Site configuration → Environment variables → `MAIL_FROM` → Edit → p. ej. `Oferta de Muebles y Electrodomésticos <admin@contact.agencements.net>` → Save → Deploys → *Clear cache and deploy site*. Si configuraste el SMTP de Supabase con Resend, cambia también allí *Sender name*.

## 14. Visitas y estadísticas (013)

Pestaña **Visitas** del panel, visible solo para administradores.

**Qué se registra.** Cada carga del catálogo, cada ficha de producto abierta, cada clic en «Me interesa» confirmado y cada filtro de categoría. El navegador envía un aviso mínimo (`src/visitas.js`, `sendBeacon`) a la función `netlify/functions/visita.js`, que agrega en el servidor: IP completa, país, región, ciudad y coordenadas aproximadas (cabeceras geográficas de Netlify, sin servicio externo), dispositivo (móvil / tablet / escritorio), navegador y si es bot. Se guarda indefinidamente en `public.visits`. Las visitas del equipo no se cuentan: `admin.html` deja la marca `vh.equipo` en el navegador al entrar y la quita al salir.

**Qué se ve.** Periodo (7/30/90 días, todo, o fechas a elegir) y casilla para incluir bots. Totales (visitas, visitantes únicos por sesión, países, bots), gráfico de visitas por día con línea de únicos, mapa de visitantes (OpenStreetMap, círculos por ubicación), productos más vistos con tasa vista → interés, países, ciudades, dispositivos, origen (sitios externos), categorías filtradas, búsquedas, y tabla de visitas recientes (IP, lugar, página, dispositivo, origen). **Exportar CSV** descarga todo el periodo (separador `;`, listo para Excel en español).

**Seguridad.** La tabla no acepta lecturas ni escrituras con la clave pública: inserta la función con `SUPABASE_SERVICE_ROLE_KEY` (ya configurada) y leen solo cuentas activas con rol administrador (RLS + `visits_summary` comprueban `is_admin()`).

**Notas.** La geolocalización solo funciona en el sitio publicado (en local Netlify no envía esas cabeceras, la fila queda sin lugar). El evento `busqueda` está previsto pero el catálogo aún no tiene buscador; cuando se agregue, basta llamar `registrar('busqueda', { query })`. Requiere `supabase/013-visitas.sql` (incluido en `000-base-completa.sql`).
