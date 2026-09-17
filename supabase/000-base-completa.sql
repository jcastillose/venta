-- ============================================================================
-- venta.hogar — BASE DE DATOS COMPLETA (Supabase / Postgres)
-- Un solo script que crea o repara TODO lo que el sitio necesita y termina con
-- un informe ok / FALTA por objeto. Reemplaza a schema.sql + 002…007.
--
-- Re-ejecutable: se puede correr completo cuantas veces haga falta, sobre una
-- base vacía o sobre una que ya tenga datos (no borra productos, interesados,
-- pagos ni cuentas).
--
-- Supabase → SQL Editor → pegar todo → Run. Revisar la tabla final: toda fila
-- debe decir "ok". Después: bootstrap-admin.sql para la primera cuenta admin.
-- ============================================================================

-- ── 1. Tipos y tablas base ───────────────────────────────────────────────────
create extension if not exists "pgcrypto";

-- ── Tipos ────────────────────────────────────────────────────────────────────
do $$ begin
  create type public.member_role as enum ('admin', 'editor');
exception when duplicate_object then null; end $$;
do $$ begin
  create type public.member_status as enum ('activo', 'invitado', 'suspendido');
exception when duplicate_object then null; end $$;
do $$ begin
  create type public.product_status as enum ('disponible', 'reservado', 'vendido');
exception when duplicate_object then null; end $$;
do $$ begin
  create type public.product_category as enum ('Muebles', 'Electrodomésticos', 'Electrónica');
exception when duplicate_object then null; end $$;
do $$ begin
  create type public.interest_status as enum ('nuevo', 'conversando', 'reservado', 'vendido', 'descartado');
exception when duplicate_object then null; end $$;
do $$ begin
  create type public.sender_role as enum ('vendedor', 'interesado');
exception when duplicate_object then null; end $$;
do $$ begin
  create type public.pay_method as enum ('prex', 'mercadopago', 'transferencia');
exception when duplicate_object then null; end $$;
do $$ begin
  create type public.payment_status as enum ('porconfirmar', 'pagado', 'anulado');
exception when duplicate_object then null; end $$;

-- ── Tablas ───────────────────────────────────────────────────────────────────
-- Cuentas del equipo: 1 fila por usuario de Supabase Auth.
-- Toda cuenta activa edita todos los productos; 'admin' además gestiona
-- cuentas y datos de cobro.
create table if not exists public.members (
  id          uuid primary key references auth.users(id) on delete cascade,
  name        text not null,
  email       text not null unique,
  role        public.member_role not null default 'editor',
  status      public.member_status not null default 'activo',
  last_seen   timestamptz,
  created_at  timestamptz not null default now()
);

create table if not exists public.products (
  id          uuid primary key default gen_random_uuid(),
  created_by  uuid not null references public.members(id),
  updated_by  uuid references public.members(id),
  title       text not null,
  category    text not null,
  description text not null default '',
  price_clp   integer not null check (price_clp >= 0),
  status      public.product_status not null default 'disponible',
  lugar       text,
  condicion   text,
  accepts_offers boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
alter table public.products add column if not exists accepts_offers boolean not null default true;

-- Fotos: archivos del bucket "fotos". position 0 = portada.
create table if not exists public.product_photos (
  id           uuid primary key default gen_random_uuid(),
  product_id   uuid not null references public.products(id) on delete cascade,
  storage_path text not null,
  position     smallint not null default 0,
  created_at   timestamptz not null default now()
);
create index if not exists product_photos_orden on public.product_photos (product_id, position);

-- Interés = solicitud de reserva a precio fijo. Sin cuenta: la persona recibe
-- un token (enlace /c/<token>) con el que abre su hilo y su pantalla de pago.
create table if not exists public.interests (
  id            uuid primary key default gen_random_uuid(),
  product_id    uuid not null references public.products(id) on delete cascade,
  buyer_name    text not null,
  buyer_contact text not null,
  status        public.interest_status not null default 'nuevo',
  token         text not null unique default encode(gen_random_bytes(24), 'hex'),
  created_at    timestamptz not null default now()
);
create index if not exists interests_producto on public.interests (product_id);

create table if not exists public.messages (
  id           uuid primary key default gen_random_uuid(),
  interest_id  uuid not null references public.interests(id) on delete cascade,
  sender       public.sender_role not null,
  body         text not null check (length(body) between 1 and 2000),
  created_at   timestamptz not null default now()
);
create index if not exists messages_hilo on public.messages (interest_id, created_at);

-- Datos de cobro del equipo: una fila por medio. `details` guarda los campos
-- que ve quien paga (titular, RUT, alias Prex, link MercadoPago, banco…).
create table if not exists public.payment_settings (
  method     public.pay_method primary key,
  enabled    boolean not null default true,
  details    jsonb not null default '{}'::jsonb,
  updated_by uuid references public.members(id),
  updated_at timestamptz not null default now()
);

insert into public.payment_settings (method, enabled, details) values
  ('prex', true, '{"Titular":"","RUT":"","Teléfono o alias Prex":""}'),
  ('mercadopago', true, '{"Usuario":"","Link de cobro":""}'),
  ('transferencia', true, '{"Banco":"","Tipo de cuenta":"","Número":"","RUT":"","Correo de aviso":""}')
on conflict (method) do nothing;

-- Un pago por interés: lo declara la persona interesada y lo confirma el equipo.
create table if not exists public.payments (
  id            uuid primary key default gen_random_uuid(),
  interest_id   uuid not null unique references public.interests(id) on delete cascade,
  method        public.pay_method not null,
  amount_clp    integer not null check (amount_clp >= 0),
  reference     text,
  status        public.payment_status not null default 'porconfirmar',
  declared_at   timestamptz not null default now(),
  confirmed_at  timestamptz,
  confirmed_by  uuid references public.members(id)
);

-- ── Funciones de apoyo ───────────────────────────────────────────────────────
create or replace function public.is_member() returns boolean
language sql security definer set search_path = public stable as $$
  select exists (select 1 from public.members m where m.id = auth.uid() and m.status = 'activo');
$$;

create or replace function public.is_admin() returns boolean
language sql security definer set search_path = public stable as $$
  select exists (select 1 from public.members m where m.id = auth.uid() and m.status = 'activo' and m.role = 'admin');
$$;

-- ── Vistas ───────────────────────────────────────────────────────────────────
create or replace view public.payment_options as
  select method, details from public.payment_settings where enabled;

-- ── Trigger: crear la cuenta del equipo al registrarse ───────────────────────
-- Solo crea la fila si la cuenta nació desde el panel (cuentas.js marca
-- user_metadata.equipo = true). Un correo cualquiera que pida "Enlace por correo"
-- entra a Auth pero NO al equipo: verá "Tu correo no tiene cuenta en el equipo".
-- La primera cuenta se da de alta con bootstrap-admin.sql.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if coalesce((new.raw_user_meta_data->>'equipo')::boolean, false) then
    insert into public.members (id, name, email, role, status)
    values (new.id,
            coalesce(new.raw_user_meta_data->>'name', split_part(new.email, '@', 1)),
            new.email,
            coalesce((new.raw_user_meta_data->>'role')::public.member_role, 'editor'),
            coalesce((new.raw_user_meta_data->>'status')::public.member_status, 'activo'))
    on conflict (id) do nothing;
  end if;
  return new;
end $$;

-- Primer ingreso de una cuenta invitada: al abrir el enlace pasa de 'invitado' a 'activo'.
create or replace function public.activar_invitacion() returns public.member_status
language plpgsql security definer set search_path = public as $$
declare s public.member_status;
begin
  update public.members set status = 'activo', last_seen = now()
   where id = auth.uid() and status = 'invitado';
  select status into s from public.members where id = auth.uid();
  return s;
end $$;
grant execute on function public.activar_invitacion() to authenticated;

-- Confirma el correo de las cuentas del equipo que ya entraron alguna vez.
update auth.users u set email_confirmed_at = coalesce(u.email_confirmed_at, now())
  from public.members m where m.id = u.id and m.status = 'activo';

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ── RLS ──────────────────────────────────────────────────────────────────────
alter table public.members          enable row level security;
alter table public.products         enable row level security;
alter table public.product_photos   enable row level security;
alter table public.interests        enable row level security;
alter table public.messages         enable row level security;
alter table public.payment_settings enable row level security;
alter table public.payments         enable row level security;

-- Catálogo público (incluye vendidos: la UI los muestra con etiqueta).
drop policy if exists "productos: lectura pública" on public.products;
create policy "productos: lectura pública" on public.products for select using (true);

drop policy if exists "fotos: lectura pública" on public.product_photos;
create policy "fotos: lectura pública" on public.product_photos for select using (true);

drop policy if exists "equipo: nombre público" on public.members;  -- members no es público: exponía correos (políticas en el bloque 7)

-- Cualquier cuenta activa del equipo edita todos los productos y sus fotos.
drop policy if exists "productos: equipo escribe" on public.products;
create policy "productos: equipo escribe" on public.products
  for all using (public.is_member()) with check (public.is_member());

drop policy if exists "fotos: equipo escribe" on public.product_photos;
create policy "fotos: equipo escribe" on public.product_photos
  for all using (public.is_member()) with check (public.is_member());

-- Cuentas: solo admin invita, cambia roles o suspende; cada uno edita su perfil.
drop policy if exists "equipo: admin gestiona" on public.members;
create policy "equipo: admin gestiona" on public.members
  for all using (public.is_admin()) with check (public.is_admin());

drop policy if exists "equipo: edita su perfil" on public.members;
create policy "equipo: edita su perfil" on public.members for update using (auth.uid() = id);

-- Interés: cualquiera lo crea (vía RPC); el equipo lo lee y actualiza.
drop policy if exists "interés: cualquiera crea" on public.interests;  -- la inserción entra solo por create_interest (RPC)

drop policy if exists "interés: equipo lee" on public.interests;
create policy "interés: equipo lee" on public.interests for select using (public.is_member());

drop policy if exists "interés: equipo actualiza" on public.interests;
create policy "interés: equipo actualiza" on public.interests for update using (public.is_member());

-- Mensajes: el equipo por RLS; la persona interesada por RPC con token.
drop policy if exists "mensajes: equipo lee" on public.messages;
create policy "mensajes: equipo lee" on public.messages for select using (public.is_member());

drop policy if exists "mensajes: equipo escribe" on public.messages;
create policy "mensajes: equipo escribe" on public.messages for insert
  with check (sender = 'vendedor' and public.is_member());

-- Datos de cobro: el equipo los lee, solo admin los edita.
drop policy if exists "cobro: equipo lee" on public.payment_settings;
create policy "cobro: equipo lee" on public.payment_settings for select using (public.is_member());

drop policy if exists "cobro: admin edita" on public.payment_settings;
create policy "cobro: admin edita" on public.payment_settings
  for all using (public.is_admin()) with check (public.is_admin());

-- Pagos: el equipo los lee y confirma; la declaración entra por RPC.
drop policy if exists "pagos: equipo lee" on public.payments;
create policy "pagos: equipo lee" on public.payments for select using (public.is_member());

drop policy if exists "pagos: equipo actualiza" on public.payments;
create policy "pagos: equipo actualiza" on public.payments for update using (public.is_member());

-- ── RPC para la persona interesada sin cuenta (token del enlace) ─────────────
create or replace function public.messages_by_token(p_token text)
returns setof public.messages
language sql security definer set search_path = public stable as $$
  select m.* from public.messages m join public.interests i on i.id = m.interest_id
  where i.token = p_token order by m.created_at;
$$;

create or replace function public.send_message_by_token(p_token text, p_body text)
returns public.messages
language plpgsql security definer set search_path = public as $$
declare v_interest uuid; v_msg public.messages;
begin
  select id into v_interest from public.interests where token = p_token;
  if v_interest is null then raise exception 'token inválido'; end if;
  insert into public.messages (interest_id, sender, body) values (v_interest, 'interesado', p_body) returning * into v_msg;
  update public.interests set status = 'conversando' where id = v_interest and status = 'nuevo';
  return v_msg;
end $$;

-- Medios de pago habilitados, para la pantalla de pago del enlace.
create or replace function public.payment_options_by_token(p_token text)
returns table (method public.pay_method, details jsonb)
language sql security definer set search_path = public stable as $$
  select s.method, s.details from public.payment_settings s
  where s.enabled and exists (select 1 from public.interests i where i.token = p_token);
$$;

-- La persona declara su pago (Prex / MercadoPago / transferencia).
create or replace function public.declare_payment_by_token(
  p_token text, p_method public.pay_method, p_reference text default null)
returns public.payments
language plpgsql security definer set search_path = public as $$
declare v_interest uuid; v_amount integer; v_pay public.payments;
begin
  select i.id, p.price_clp into v_interest, v_amount
  from public.interests i join public.products p on p.id = i.product_id
  where i.token = p_token;
  if v_interest is null then raise exception 'token inválido'; end if;
  if not exists (select 1 from public.payment_settings where method = p_method and enabled) then
    raise exception 'medio de pago no disponible';
  end if;

  insert into public.payments (interest_id, method, amount_clp, reference, status)
  values (v_interest, p_method, v_amount, nullif(p_reference, ''), 'porconfirmar')
  on conflict (interest_id) do update
    set method = excluded.method, reference = excluded.reference,
        status = 'porconfirmar', declared_at = now(), confirmed_at = null, confirmed_by = null
  returning * into v_pay;

  insert into public.messages (interest_id, sender, body)
  values (v_interest, 'interesado',
          'Pagué $' || to_char(v_amount, 'FM999G999G999') || ' por ' || p_method::text ||
          coalesce('. Referencia: ' || nullif(p_reference, ''), '') || '.');
  return v_pay;
end $$;

-- ── Cierre del trato (equipo) ────────────────────────────────────────────────
create or replace function public.close_deal(p_interest uuid, p_status public.product_status)
returns void language plpgsql security definer set search_path = public as $$
declare v_product uuid;
begin
  if not public.is_member() then raise exception 'no autorizado'; end if;
  select i.product_id into v_product from public.interests i where i.id = p_interest;
  if v_product is null then raise exception 'interés inexistente'; end if;
  update public.products  set status = p_status, updated_at = now(), updated_by = auth.uid() where id = v_product;
  update public.interests set status = p_status::text::public.interest_status where id = p_interest;
end $$;

-- Confirmar el pago recibido: marca pagado y cierra la venta en un paso.
create or replace function public.confirm_payment(p_interest uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_member() then raise exception 'no autorizado'; end if;
  update public.payments set status = 'pagado', confirmed_at = now(), confirmed_by = auth.uid()
   where interest_id = p_interest;
  insert into public.messages (interest_id, sender, body)
  values (p_interest, 'vendedor', 'Pago confirmado, ¡gracias! Coordinemos la entrega por aquí.');
  perform public.close_deal(p_interest, 'vendido');
end $$;

-- ── Storage ──────────────────────────────────────────────────────────────────
insert into storage.buckets (id, name, public) values ('fotos', 'fotos', true)
on conflict (id) do update set public = true;

drop policy if exists "fotos: lectura pública" on storage.objects;
create policy "fotos: lectura pública" on storage.objects for select using (bucket_id = 'fotos');

drop policy if exists "fotos: equipo sube" on storage.objects;
create policy "fotos: equipo sube" on storage.objects for insert
  with check (bucket_id = 'fotos' and public.is_member());

drop policy if exists "fotos: equipo borra" on storage.objects;
create policy "fotos: equipo borra" on storage.objects for delete
  using (bucket_id = 'fotos' and public.is_member());

-- ── 2. Ofertas ───────────────────────────────────────────────────────────────
create table if not exists public.offers (
  id           uuid primary key default gen_random_uuid(),
  interest_id  uuid not null unique references public.interests(id) on delete cascade,
  product_id   uuid not null references public.products(id) on delete cascade,
  amount_clp   integer not null check (amount_clp > 0),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index if not exists offers_producto_monto on public.offers (product_id, amount_clp desc);

alter table public.offers enable row level security;

drop policy if exists "ofertas: equipo lee" on public.offers;
create policy "ofertas: equipo lee" on public.offers for select using (public.is_member());

-- Resumen público por producto: solo el monto más alto y la cantidad, nunca quién.
create or replace view public.offer_summary as
  select product_id,
         max(amount_clp)          as top_offer_clp,
         count(*)                 as offer_count,
         max(updated_at)          as last_offer_at
  from public.offers
  group by product_id;

grant select on public.offer_summary to anon, authenticated;
grant all on public.offers to authenticated, service_role;

-- ── 3. Ajustes del sitio ─────────────────────────────────────────────────────
create table if not exists public.site_settings (
  key        text primary key,
  value      jsonb not null,
  updated_by uuid references public.members(id),
  updated_at timestamptz not null default now()
);

insert into public.site_settings (key, value) values
  ('ofertas_habilitadas', 'true'::jsonb),      -- los interesados pueden ofertar
  ('ofertas_publicas',    'true'::jsonb)       -- la oferta más alta se muestra en catálogo y detalle
on conflict (key) do nothing;

alter table public.site_settings enable row level security;

drop policy if exists "ajustes: lectura pública" on public.site_settings;
create policy "ajustes: lectura pública" on public.site_settings for select using (true);

drop policy if exists "ajustes: admin edita" on public.site_settings;
create policy "ajustes: admin edita" on public.site_settings
  for all using (public.is_admin()) with check (public.is_admin());

grant select on public.site_settings to anon, authenticated;
grant all on public.site_settings to authenticated, service_role;

create or replace function public.setting_on(p_key text) returns boolean
language sql security definer set search_path = public stable as $$
  select coalesce((select value = 'true'::jsonb from public.site_settings where key = p_key), false);
$$;

-- ── 4. Categorías editables y condición cerrada ──────────────────────────────
-- 1. Categorías en tabla (antes eran un enum fijo).
create table if not exists public.categories (
  id         uuid primary key default gen_random_uuid(),
  name       text not null unique,
  position   smallint not null default 0,
  created_at timestamptz not null default now()
);

insert into public.categories (name, position) values
  ('Muebles', 0), ('Electrodomésticos', 1), ('Electrónica', 2)
on conflict (name) do nothing;

alter table public.categories enable row level security;
drop policy if exists "categorías: lectura pública" on public.categories;
create policy "categorías: lectura pública" on public.categories for select using (true);
drop policy if exists "categorías: admin gestiona" on public.categories;
create policy "categorías: admin gestiona" on public.categories
  for all using (public.is_admin()) with check (public.is_admin());
grant select on public.categories to anon, authenticated;
grant all on public.categories to authenticated, service_role;

-- products.category pasa de enum a texto con FK al nombre de la categoría.
do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'products'
      and column_name = 'category' and udt_name = 'product_category'
  ) then
    drop view if exists public.catalog;  -- se recrea en el bloque 5
    alter table public.products alter column category type text using category::text;
  end if;
end $$;

alter table public.products drop constraint if exists products_category_fkey;
alter table public.products add constraint products_category_fkey
  foreign key (category) references public.categories(name) on update cascade;

-- 2. Condición: valores cerrados (el editor los muestra como desplegable).
alter table public.products drop constraint if exists products_condicion_check;
update public.products set condicion = case
  when condicion in ('nuevo','como_nuevo','impecable','pocos_detalles','uso_evidente','a_reparar','repuestos') then condicion
  when condicion ilike '%como nuevo%' then 'como_nuevo'
  when condicion ilike '%nuevo%' then 'nuevo'
  when condicion ilike '%impecable%' or condicion ilike '%muy buen%' then 'impecable'
  when condicion ilike '%repar%' or condicion ilike '%falla%' then 'a_reparar'
  when condicion ilike '%repuesto%' then 'repuestos'
  when condicion ilike '%uso%' or condicion ilike '%marca%' then 'uso_evidente'
  when condicion is null or condicion = '' then null
  else 'pocos_detalles' end;
alter table public.products add constraint products_condicion_check
  check (condicion is null or condicion in ('nuevo','como_nuevo','impecable','pocos_detalles','uso_evidente','a_reparar','repuestos'));

-- 4. Eliminar categoría solo si no tiene productos (la FK ya lo impide; esta RPC da un mensaje claro).
create or replace function public.delete_category(p_name text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Solo un administrador puede eliminar categorías'; end if;
  if exists (select 1 from public.products where category = p_name) then
    raise exception 'La categoría tiene productos; muévelos a otra antes de eliminarla';
  end if;
  delete from public.categories where name = p_name;
end $$;
grant execute on function public.delete_category(text) to authenticated;

-- ── 5. Catálogo, RPC del interesado y ofertas por producto ───────────────────
-- Versión vigente de catalog, create_interest, place_offer_by_token y
-- thread_by_token (rige products.accepts_offers; el ajuste global es masivo).
drop function if exists public.create_interest(uuid, text, text, text);
-- El catálogo expone la columna nueva. La vista se recrea (p.* se expandió al
-- crearla y `create or replace` no puede insertar columnas en medio).
drop view if exists public.catalog;
create view public.catalog as
  select p.*, m.name as published_by,
         (select count(*) from public.interests i where i.product_id = p.id) as interested_count,
         case when public.setting_on('ofertas_publicas') then o.top_offer_clp end as top_offer_clp,
         case when public.setting_on('ofertas_publicas') then coalesce(o.offer_count, 0) else 0 end as offer_count
  from public.products p
  join public.members m on m.id = p.created_by
  left join public.offer_summary o on o.product_id = p.id;
grant select on public.catalog to anon, authenticated;

-- Interruptor global: cambia el ajuste y el estado de todos los productos a la vez.
create or replace function public.set_offers_for_all(p_on boolean) returns integer
language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if not public.is_admin() then raise exception 'Solo un administrador puede cambiar este ajuste'; end if;
  insert into public.site_settings (key, value, updated_by, updated_at)
  values ('ofertas_habilitadas', to_jsonb(p_on), auth.uid(), now())
  on conflict (key) do update set value = excluded.value, updated_by = excluded.updated_by, updated_at = now();
  update public.products set accepts_offers = p_on where accepts_offers <> p_on;
  get diagnostics n = row_count;
  return n;
end $$;
grant execute on function public.set_offers_for_all(boolean) to authenticated;

-- Ofertar desde el hilo: rige el interruptor del producto.
create or replace function public.place_offer_by_token(p_token text, p_amount integer)
returns table (my_offer_clp integer, top_offer_clp integer, offer_count bigint)
language plpgsql security definer set search_path = public as $$
declare v_interest uuid; v_product uuid; v_status public.product_status; v_on boolean;
begin
  if p_amount is null or p_amount <= 0 then raise exception 'La oferta debe ser mayor que cero'; end if;
  select i.id, i.product_id, p.status, p.accepts_offers into v_interest, v_product, v_status, v_on
  from public.interests i join public.products p on p.id = i.product_id where i.token = p_token;
  if v_interest is null then raise exception 'token inválido'; end if;
  if not v_on then raise exception 'Las ofertas están desactivadas para este producto'; end if;
  if v_status = 'vendido' then raise exception 'El producto ya fue vendido'; end if;

  insert into public.offers (interest_id, product_id, amount_clp)
  values (v_interest, v_product, p_amount)
  on conflict (interest_id) do update set amount_clp = excluded.amount_clp, updated_at = now();

  insert into public.messages (interest_id, sender, body)
  values (v_interest, 'interesado', 'Ofrezco $' || to_char(p_amount, 'FM999G999G999') || '.');
  update public.interests set status = 'conversando' where id = v_interest and status = 'nuevo';

  return query
    select p_amount,
           case when public.setting_on('ofertas_publicas') then s.top_offer_clp end,
           case when public.setting_on('ofertas_publicas') then s.offer_count else 0::bigint end
    from public.offer_summary s where s.product_id = v_product;
end $$;

-- Marcar interés: la oferta solo se registra si el producto la acepta.
create or replace function public.create_interest(
  p_product uuid, p_name text, p_contact text, p_message text default null, p_offer integer default null)
returns text
language plpgsql security definer set search_path = public as $$
declare v_token text; v_id uuid; v_on boolean;
begin
  if coalesce(trim(p_name), '') = '' or coalesce(trim(p_contact), '') = '' then
    raise exception 'Nombre y contacto son obligatorios';
  end if;
  select accepts_offers into v_on from public.products where id = p_product and status <> 'vendido';
  if v_on is null then raise exception 'Producto no disponible'; end if;
  if not v_on then p_offer := null; end if;
  if p_offer is not null and p_offer <= 0 then
    raise exception 'La oferta debe ser mayor que cero';
  end if;

  insert into public.interests (product_id, buyer_name, buyer_contact)
  values (p_product, trim(p_name), trim(p_contact))
  returning id, token into v_id, v_token;

  if p_offer is not null then
    insert into public.offers (interest_id, product_id, amount_clp) values (v_id, p_product, p_offer);
    insert into public.messages (interest_id, sender, body)
    values (v_id, 'interesado', 'Ofrezco $' || to_char(p_offer, 'FM999G999G999') || '.');
  end if;
  if coalesce(trim(p_message), '') <> '' then
    insert into public.messages (interest_id, sender, body) values (v_id, 'interesado', trim(p_message));
  end if;
  return v_token;
end $$;

-- El hilo informa si ese producto acepta ofertas.
drop function if exists public.thread_by_token(text);
create or replace function public.thread_by_token(p_token text)
returns table (interest_id uuid, product_id uuid, product_title text, price_clp integer,
               product_status public.product_status, interest_status public.interest_status,
               published_by text, buyer_name text,
               payment_method public.pay_method, payment_status public.payment_status,
               payment_reference text,
               my_offer_clp integer, top_offer_clp integer, offer_count bigint,
               offers_enabled boolean)
language sql security definer set search_path = public stable as $$
  select i.id, p.id, p.title, p.price_clp, p.status, i.status, m.name, i.buyer_name,
         y.method, y.status, y.reference,
         o.amount_clp,
         case when public.setting_on('ofertas_publicas') then s.top_offer_clp end,
         case when public.setting_on('ofertas_publicas') then coalesce(s.offer_count, 0) else 0::bigint end,
         p.accepts_offers
  from public.interests i
  join public.products p on p.id = i.product_id
  join public.members  m on m.id = p.created_by
  left join public.payments y on y.interest_id = i.id
  left join public.offers   o on o.interest_id = i.id
  left join public.offer_summary s on s.product_id = p.id
  where i.token = p_token;
$$;

grant execute on function public.thread_by_token(text),
  public.place_offer_by_token(text, integer), public.create_interest(uuid, text, text, text, integer)
  to anon, authenticated;

-- ── 6. Permisos de vistas y RPC ──────────────────────────────────────────────
grant select on public.catalog, public.payment_options, public.offer_summary,
  public.site_settings, public.categories to anon, authenticated;
grant execute on function
  public.create_interest(uuid, text, text, text, integer),
  public.thread_by_token(text),
  public.messages_by_token(text),
  public.send_message_by_token(text, text),
  public.payment_options_by_token(text),
  public.declare_payment_by_token(text, public.pay_method, text),
  public.place_offer_by_token(text, integer),
  public.setting_on(text)
  to anon, authenticated;
grant execute on function
  public.close_deal(uuid, public.product_status),
  public.confirm_payment(uuid),
  public.delete_category(text),
  public.set_offers_for_all(boolean),
  public.is_member(), public.is_admin()
  to authenticated;

-- ── 7. Saneamiento, semillas, integridad y realtime ──────────────────────────
-- Equipo: cada cuenta lee su fila; las activas leen a todo el equipo. Nadie más.
drop policy if exists "equipo: nombre público" on public.members;
drop policy if exists "equipo: lee su fila" on public.members;
create policy "equipo: lee su fila" on public.members for select using (auth.uid() = id);
drop policy if exists "equipo: activos leen equipo" on public.members;
create policy "equipo: activos leen equipo" on public.members for select using (public.is_member());

-- Auditoría: eliminar una cuenta no debe fallar por sus huellas (updated_by, confirmed_by).
-- La autoría de productos (created_by) la reasigna cuentas.js antes de borrar.
alter table public.products drop constraint if exists products_updated_by_fkey;
alter table public.products add constraint products_updated_by_fkey
  foreign key (updated_by) references public.members(id) on delete set null;
alter table public.payments drop constraint if exists payments_confirmed_by_fkey;
alter table public.payments add constraint payments_confirmed_by_fkey
  foreign key (confirmed_by) references public.members(id) on delete set null;
alter table public.payment_settings drop constraint if exists payment_settings_updated_by_fkey;
alter table public.payment_settings add constraint payment_settings_updated_by_fkey
  foreign key (updated_by) references public.members(id) on delete set null;
alter table public.site_settings drop constraint if exists site_settings_updated_by_fkey;
alter table public.site_settings add constraint site_settings_updated_by_fkey
  foreign key (updated_by) references public.members(id) on delete set null;

-- Datos semilla: ajustes y categorías que el panel espera.
insert into public.site_settings (key, value) values
  ('ofertas_habilitadas', 'true'::jsonb), ('ofertas_publicas', 'true'::jsonb),
  ('titulo_sitio', to_jsonb('Oferta de Muebles y Electrodomésticos'::text))
on conflict (key) do nothing;
insert into public.categories (name, position) values
  ('Muebles', 0), ('Electrodomésticos', 1), ('Electrónica', 2)
on conflict (name) do nothing;

-- Integridad: todo producto con categoría existente; fotos sin producto fuera.
insert into public.categories (name, position)
select distinct p.category, 99 from public.products p
left join public.categories c on c.name = p.category where c.name is null;
delete from public.product_photos f where not exists (select 1 from public.products p where p.id = f.product_id);

-- Realtime: tablas que el panel refresca en vivo.
do $$
declare t text;
begin
  foreach t in array array['products','product_photos','interests','messages','payments','offers','site_settings','categories'] loop
    begin execute format('alter publication supabase_realtime add table public.%I', t);
    exception when duplicate_object then null; end;
  end loop;
end $$;

-- ── 8. Informe final ─────────────────────────────────────────────────────────
with esperado(tipo, nombre, usado_por) as (values
  ('tabla',   'members',          'admin.html, cuentas.js, avisos.js'),
  ('tabla',   'products',         'admin.html, avisos.js'),
  ('tabla',   'product_photos',   'index, producto, c, admin'),
  ('tabla',   'interests',        'admin.html, RPC'),
  ('tabla',   'messages',         'admin.html, RPC'),
  ('tabla',   'payments',         'admin.html, RPC'),
  ('tabla',   'payment_settings', 'admin.html'),
  ('tabla',   'offers',           'admin.html (002)'),
  ('tabla',   'site_settings',    'index, producto, admin (003)'),
  ('tabla',   'categories',       'todas las pantallas (004)'),
  ('vista',   'catalog',          'index.html, producto.html'),
  ('vista',   'payment_options',  'producto.html'),
  ('vista',   'offer_summary',    'catalog, RPC'),
  ('columna', 'products.accepts_offers', 'ofertas por producto (006)'),
  ('columna', 'products.lugar',   'editor'),
  ('columna', 'products.condicion','editor (004)'),
  ('columna', 'members.last_seen','admin.html'),
  ('columna', 'site_settings.updated_by','admin.html'),
  ('rpc',     'create_interest',  'producto.html'),
  ('rpc',     'thread_by_token',  'c.html'),
  ('rpc',     'messages_by_token','c.html'),
  ('rpc',     'send_message_by_token','c.html'),
  ('rpc',     'payment_options_by_token','c.html'),
  ('rpc',     'declare_payment_by_token','c.html'),
  ('rpc',     'place_offer_by_token','c.html (002)'),
  ('rpc',     'close_deal',       'admin.html'),
  ('rpc',     'confirm_payment',  'admin.html'),
  ('rpc',     'delete_category',  'admin.html (004)'),
  ('rpc',     'set_offers_for_all','admin.html (006)'),
  ('rpc',     'activar_invitacion','admin.html primer ingreso'),
  ('rpc',     'setting_on',       'catalog (003)'),
  ('rpc',     'is_member',        'RLS'),
  ('rpc',     'is_admin',         'RLS'),
  ('rpc',     'handle_new_user',  'trigger auth.users'),
  ('trigger', 'on_auth_user_created','alta de cuentas'),
  ('bucket',  'fotos',            'fotos de productos'),
  ('ajuste',  'ofertas_habilitadas','Ajustes'),
  ('ajuste',  'ofertas_publicas', 'Ajustes'),
  ('ajuste',  'titulo_sitio',     'Ajustes (005)'),
  ('rls',     'members',          ''), ('rls','products',''), ('rls','product_photos',''),
  ('rls',     'interests',        ''), ('rls','messages',''), ('rls','payments',''),
  ('rls',     'payment_settings', ''), ('rls','offers',''), ('rls','site_settings',''), ('rls','categories',''),
  ('admin',   'al menos un administrador activo', 'acceso al panel')
)
select e.tipo, e.nombre,
  case when (
    (e.tipo = 'tabla'   and exists (select 1 from information_schema.tables where table_schema='public' and table_name=e.nombre and table_type='BASE TABLE')) or
    (e.tipo = 'vista'   and exists (select 1 from information_schema.views  where table_schema='public' and table_name=e.nombre)) or
    (e.tipo = 'columna' and exists (select 1 from information_schema.columns where table_schema='public'
                                    and table_name=split_part(e.nombre,'.',1) and column_name=split_part(e.nombre,'.',2))) or
    (e.tipo = 'rpc'     and exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname=e.nombre)) or
    (e.tipo = 'trigger' and exists (select 1 from pg_trigger where tgname=e.nombre)) or
    (e.tipo = 'bucket'  and exists (select 1 from storage.buckets where id=e.nombre and public)) or
    (e.tipo = 'ajuste'  and exists (select 1 from public.site_settings where key=e.nombre)) or
    (e.tipo = 'rls'     and exists (select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
                                    where n.nspname='public' and c.relname=e.nombre and c.relrowsecurity)) or
    (e.tipo = 'admin'   and exists (select 1 from public.members where role='admin' and status='activo'))
  ) then 'ok' else 'FALTA' end as estado,
  e.usado_por
from esperado e
order by case when e.tipo='admin' then 0 else 1 end, e.tipo, e.nombre;
