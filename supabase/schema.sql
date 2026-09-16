-- venta.hogar — esquema Supabase (Postgres)
-- Re-ejecutable: se puede correr completo varias veces sin error.
-- Supabase → SQL Editor → pegar todo → Run.

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
  category    public.product_category not null,
  description text not null default '',
  price_clp   integer not null check (price_clp >= 0),
  status      public.product_status not null default 'disponible',
  lugar       text,
  condicion   text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

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
create or replace view public.catalog as
  select p.*, m.name as published_by,
         (select count(*) from public.interests i where i.product_id = p.id) as interested_count
  from public.products p join public.members m on m.id = p.created_by;

create or replace view public.payment_options as
  select method, details from public.payment_settings where enabled;

-- ── Trigger: crear la cuenta del equipo al registrarse ───────────────────────
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.members (id, name, email, role, status)
  values (new.id,
          coalesce(new.raw_user_meta_data->>'name', split_part(new.email, '@', 1)),
          new.email,
          coalesce((new.raw_user_meta_data->>'role')::public.member_role, 'editor'),
          'activo')
  on conflict (id) do update set status = 'activo';
  return new;
end $$;

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

drop policy if exists "equipo: nombre público" on public.members;
create policy "equipo: nombre público" on public.members for select using (true);

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
drop policy if exists "interés: cualquiera crea" on public.interests;
create policy "interés: cualquiera crea" on public.interests for insert with check (true);

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
-- Marcar interés: inserta y devuelve el token del hilo (anon no puede leer la
-- tabla, así que el token se entrega solo por esta vía).
create or replace function public.create_interest(
  p_product uuid, p_name text, p_contact text, p_message text default null)
returns text
language plpgsql security definer set search_path = public as $$
declare v_token text; v_id uuid;
begin
  if coalesce(trim(p_name), '') = '' or coalesce(trim(p_contact), '') = '' then
    raise exception 'Nombre y contacto son obligatorios';
  end if;
  if not exists (select 1 from public.products where id = p_product and status <> 'vendido') then
    raise exception 'Producto no disponible';
  end if;

  insert into public.interests (product_id, buyer_name, buyer_contact)
  values (p_product, trim(p_name), trim(p_contact))
  returning id, token into v_id, v_token;

  if coalesce(trim(p_message), '') <> '' then
    insert into public.messages (interest_id, sender, body) values (v_id, 'interesado', trim(p_message));
  end if;
  return v_token;
end $$;

create or replace function public.thread_by_token(p_token text)
returns table (interest_id uuid, product_id uuid, product_title text, price_clp integer,
               product_status public.product_status, interest_status public.interest_status,
               published_by text, buyer_name text,
               payment_method public.pay_method, payment_status public.payment_status,
               payment_reference text)
language sql security definer set search_path = public stable as $$
  select i.id, p.id, p.title, p.price_clp, p.status, i.status, m.name, i.buyer_name,
         y.method, y.status, y.reference
  from public.interests i
  join public.products p on p.id = i.product_id
  join public.members  m on m.id = p.created_by
  left join public.payments y on y.interest_id = i.id
  where i.token = p_token;
$$;

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

-- ── Permisos de vistas y RPC públicos ────────────────────────────────────────
-- Grants base del esquema (Supabase los pone por defecto, pero se pierden si el
-- esquema public se recreó; sin ellos toda consulta falla con "permission denied").
grant usage on schema public to anon, authenticated, service_role;
grant all on all tables    in schema public to anon, authenticated, service_role;
grant all on all sequences in schema public to anon, authenticated, service_role;
grant all on all routines  in schema public to anon, authenticated, service_role;
alter default privileges in schema public grant all on tables    to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
alter default privileges in schema public grant all on routines  to anon, authenticated, service_role;
-- Lo que cada rol puede ver de verdad lo deciden las políticas RLS de arriba.

grant select on public.catalog, public.payment_options to anon, authenticated;
grant execute on function
  public.create_interest(uuid, text, text, text),
  public.thread_by_token(text),
  public.messages_by_token(text),
  public.send_message_by_token(text, text),
  public.payment_options_by_token(text),
  public.declare_payment_by_token(text, public.pay_method, text)
  to anon, authenticated;
grant execute on function
  public.close_deal(uuid, public.product_status),
  public.confirm_payment(uuid),
  public.is_member(), public.is_admin()
  to authenticated;

-- ── Realtime ─────────────────────────────────────────────────────────────────
do $$
declare t text;
begin
  foreach t in array array['products', 'interests', 'messages', 'payments'] loop
    begin
      execute format('alter publication supabase_realtime add table public.%I', t);
    exception when duplicate_object then null;
    end;
  end loop;
end $$;
