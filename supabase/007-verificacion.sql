-- Verificación y saneamiento de la base. Re-ejecutable.
-- Correr DESPUÉS de 001…006. Parte A corrige incoherencias detectadas al revisar
-- schema.sql + migraciones contra lo que usan index/producto/c/admin.html,
-- cuentas.js y avisos.js. Parte B imprime un informe: cada objeto que el sitio
-- necesita y si existe (ok / FALTA).

-- ── A. Correcciones ──────────────────────────────────────────────────────────

-- A1. Sobrecarga vieja de create_interest (4 parámetros, de schema.sql) convive con
--     la de 5 (002+). PostgREST puede no saber cuál elegir → "Could not choose the
--     best candidate function". Se elimina la vieja.
drop function if exists public.create_interest(uuid, text, text, text);

-- A2. members era legible por cualquiera (select using true): exponía correos y
--     last_seen del equipo al público. El catálogo y los RPC del interesado leen
--     members como owner/security definer, así que no necesitan esa política.
drop policy if exists "equipo: nombre público" on public.members;
drop policy if exists "equipo: lee su fila" on public.members;
create policy "equipo: lee su fila" on public.members for select using (auth.uid() = id);
drop policy if exists "equipo: activos leen equipo" on public.members;
create policy "equipo: activos leen equipo" on public.members for select using (public.is_member());

-- A3. Interés: la inserción entra solo por create_interest (security definer).
--     La política abierta permitía a anon insertar filas sueltas sin pasar por
--     las validaciones ni la oferta.
drop policy if exists "interés: cualquiera crea" on public.interests;

-- A4. Eliminar una cuenta fallaba si esa persona había tocado Ajustes
--     (site_settings.updated_by sin on delete). Todas las referencias de auditoría
--     pasan a "set null"; la autoría de productos (created_by) la reasigna cuentas.js.
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

-- A5. Ajustes por defecto que el panel espera (si faltaran).
insert into public.site_settings (key, value) values
  ('ofertas_habilitadas', 'true'::jsonb), ('ofertas_publicas', 'true'::jsonb),
  ('titulo_sitio', to_jsonb('Oferta de Muebles y Electrodomésticos'::text))
on conflict (key) do nothing;
insert into public.categories (name, position) values
  ('Muebles', 0), ('Electrodomésticos', 1), ('Electrónica', 2)
on conflict (name) do nothing;

-- A6. Todo producto debe tener su fila de categoría (FK) y las fotos un producto.
insert into public.categories (name, position)
select distinct p.category, 99 from public.products p
left join public.categories c on c.name = p.category where c.name is null;
delete from public.product_photos f where not exists (select 1 from public.products p where p.id = f.product_id);

-- A7. Realtime: todas las tablas que el panel refresca en vivo.
do $$
declare t text;
begin
  foreach t in array array['products','product_photos','interests','messages','payments','offers','site_settings','categories'] loop
    begin execute format('alter publication supabase_realtime add table public.%I', t);
    exception when duplicate_object then null; end;
  end loop;
end $$;

-- ── B. Informe ───────────────────────────────────────────────────────────────
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
