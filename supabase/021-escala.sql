-- 021 · Escala: contadores por trigger, catálogo O(1) con portada, RPC sin agregados globales,
-- RLS evaluada una vez por consulta, índices de listado, Realtime mínimo y purga de pg_net. Re-ejecutable.
-- Se aplica sobre 000 + 014 + 017 + 018 + 019 + 020.

-- ── A. Índices de listado ────────────────────────────────────────────────────
create index if not exists products_catalogo_idx on public.products (status, created_at desc) where is_public;
create index if not exists products_categoria_idx on public.products (category, status, created_at desc);
drop index if exists public.products_category_idx;
-- (product_id, created_at desc) cubre la FK, el tope «30 por producto cada 10 min» y el listado del panel.
create index if not exists interests_producto_fecha on public.interests (product_id, created_at desc);
drop index if exists public.interests_producto;
-- Un hilo abierto por contacto y producto, atómico (019 lo comprobaba antes de insertar).
do $$ begin
  create unique index if not exists interests_hilo_abierto
    on public.interests (product_id, lower(buyer_contact)) where status <> 'descartado';
exception when unique_violation then
  raise notice 'interests_hilo_abierto no creado: hay hilos abiertos duplicados';
end $$;
-- recovery_requests: clave primaria.
alter table public.recovery_requests add column if not exists id bigint generated always as identity;
do $$ begin
  if not exists (select 1 from pg_constraint where conrelid = 'public.recovery_requests'::regclass and contype = 'p') then
    alter table public.recovery_requests add primary key (id);
  end if;
end $$;

-- ── B. Contadores por producto mantenidos por trigger ───────────────────────
-- Tabla aparte: un interés nuevo no toca products (sin evento Realtime ni bloqueo con el editor).
create table if not exists public.product_stats (
  product_id       uuid primary key references public.products(id) on delete cascade,
  interested_count integer not null default 0,
  offer_count      integer not null default 0,
  top_offer_clp    integer,
  last_offer_at    timestamptz,
  updated_at       timestamptz not null default now()
);
alter table public.product_stats enable row level security;
revoke all on public.product_stats from anon, authenticated;

create or replace function public.product_stats_refresh(p_product uuid) returns void
language sql security definer set search_path = public as $$
  insert into public.product_stats as s (product_id, interested_count, offer_count, top_offer_clp, last_offer_at, updated_at)
  select p.id,
         (select count(*) from public.interests i where i.product_id = p.id),
         coalesce(o.n, 0), o.top, o.last, now()
  from public.products p
  left join lateral (
    select count(*) as n, max(amount_clp) as top, max(updated_at) as last
    from public.offers where product_id = p.id
  ) o on true
  where p.id = p_product
  on conflict (product_id) do update
    set interested_count = excluded.interested_count, offer_count = excluded.offer_count,
        top_offer_clp = excluded.top_offer_clp, last_offer_at = excluded.last_offer_at, updated_at = now();
$$;
revoke all on function public.product_stats_refresh(uuid) from public, anon, authenticated;

-- Trigger por sentencia con tablas de transición: un borrado en cascada recalcula una vez, no N.
create or replace function public.product_stats_trg() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    perform public.product_stats_refresh(x.product_id) from (select distinct product_id from new_rows) x;
  elsif tg_op = 'DELETE' then
    perform public.product_stats_refresh(x.product_id) from (select distinct product_id from old_rows) x;
  else
    perform public.product_stats_refresh(x.product_id)
      from (select product_id from new_rows union select product_id from old_rows) x;
  end if;
  return null;
end $$;
revoke all on function public.product_stats_trg() from public, anon, authenticated;

drop trigger if exists product_stats_interests_ins on public.interests;
create trigger product_stats_interests_ins after insert on public.interests
  referencing new table as new_rows for each statement execute function public.product_stats_trg();
drop trigger if exists product_stats_interests_del on public.interests;
create trigger product_stats_interests_del after delete on public.interests
  referencing old table as old_rows for each statement execute function public.product_stats_trg();
drop trigger if exists product_stats_offers_ins on public.offers;
create trigger product_stats_offers_ins after insert on public.offers
  referencing new table as new_rows for each statement execute function public.product_stats_trg();
drop trigger if exists product_stats_offers_upd on public.offers;
create trigger product_stats_offers_upd after update on public.offers
  referencing old table as old_rows new table as new_rows for each statement execute function public.product_stats_trg();
drop trigger if exists product_stats_offers_del on public.offers;
create trigger product_stats_offers_del after delete on public.offers
  referencing old table as old_rows for each statement execute function public.product_stats_trg();

do $$ begin perform public.product_stats_refresh(id) from public.products; end $$;

-- ── C. Vista catalog: coste constante por fila, con portada y miniatura ──────
drop view if exists public.catalog;
create view public.catalog as
  select p.*, m.name as published_by,
         coalesce(s.interested_count, 0)::bigint as interested_count,
         case when (select public.setting_on('ofertas_publicas')) then s.top_offer_clp end as top_offer_clp,
         (case when (select public.setting_on('ofertas_publicas')) then coalesce(s.offer_count, 0) else 0 end)::bigint as offer_count,
         f.storage_path as cover,
         f.thumb_path as cover_thumb,
         coalesce(f.n, 0)::integer as photo_count
  from public.products p
  join public.members m on m.id = p.created_by
  left join public.product_stats s on s.product_id = p.id
  left join lateral (
    select storage_path, thumb_path, count(*) over () as n
    from public.product_photos where product_id = p.id
    order by position limit 1
  ) f on true
  where p.is_public;
grant select on public.catalog to anon, authenticated;

-- ── D. RPC por token sin agregados globales ─────────────────────────────────
drop function if exists public.thread_by_token(text);
create function public.thread_by_token(p_token text)
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
         case when (select public.setting_on('ofertas_publicas')) then s.top_offer_clp end,
         case when (select public.setting_on('ofertas_publicas')) then coalesce(s.offer_count, 0)::bigint else 0::bigint end,
         p.accepts_offers
  from public.interests i
  join public.products p on p.id = i.product_id
  join public.members  m on m.id = p.created_by
  left join public.payments      y on y.interest_id = i.id
  left join public.offers        o on o.interest_id = i.id
  left join public.product_stats s on s.product_id = p.id
  where i.token = p_token;
$$;
grant execute on function public.thread_by_token(text) to anon, authenticated;

create or replace function public.place_offer_by_token(p_token text, p_amount integer)
returns table (my_offer_clp integer, top_offer_clp integer, offer_count bigint)
language plpgsql security definer set search_path = public as $$
declare v_interest uuid; v_product uuid; v_istatus public.interest_status; v_status public.product_status; v_on boolean;
begin
  if p_amount is null or p_amount <= 0 then raise exception 'La oferta debe ser mayor que cero'; end if;
  select i.id, i.product_id, i.status, p.status, p.accepts_offers
    into v_interest, v_product, v_istatus, v_status, v_on
  from public.interests i join public.products p on p.id = i.product_id where i.token = p_token;
  if v_interest is null then raise exception 'token inválido'; end if;
  if not v_on then raise exception 'Las ofertas están desactivadas para este producto'; end if;
  if v_status = 'vendido' then raise exception 'El producto ya fue vendido'; end if;
  if v_istatus = 'descartado' then raise exception 'Esta conversación fue cerrada por el equipo de venta'; end if;

  insert into public.offers (interest_id, product_id, amount_clp)
  values (v_interest, v_product, p_amount)
  on conflict (interest_id) do update set amount_clp = excluded.amount_clp, updated_at = now();

  insert into public.messages (interest_id, sender, body)
  values (v_interest, 'interesado', 'Ofrezco $' || to_char(p_amount, 'FM999G999G999') || '.');
  update public.interests set status = 'conversando' where id = v_interest and status = 'nuevo';

  return query
    select p_amount,
           case when (select public.setting_on('ofertas_publicas')) then s.top_offer_clp end,
           case when (select public.setting_on('ofertas_publicas')) then s.offer_count::bigint else 0::bigint end
    from public.product_stats s where s.product_id = v_product;
end $$;

-- Recuperación de conversaciones por correo con igualdad (usa interests_contact_idx); solo service_role.
create or replace function public.interests_by_contact(p_email text)
returns table (token text, status public.interest_status, created_at timestamptz, title text, price_clp integer, product_status public.product_status)
language sql security definer set search_path = public stable as $$
  select i.token, i.status, i.created_at, p.title, p.price_clp, p.status
  from public.interests i join public.products p on p.id = i.product_id
  where lower(i.buyer_contact) = lower(trim(p_email)) and i.status <> 'descartado'
  order by i.created_at desc;
$$;
revoke all on function public.interests_by_contact(text) from public, anon, authenticated;
grant execute on function public.interests_by_contact(text) to service_role;

-- ── E. RLS: (select f()) se evalúa una vez por consulta; una política por comando ──
drop policy if exists "equipo: lee su fila"        on public.members;
drop policy if exists "equipo: activos leen equipo" on public.members;
drop policy if exists "equipo: admin gestiona"     on public.members;
drop policy if exists "equipo: edita su perfil"    on public.members;
drop policy if exists "equipo: lee"                on public.members;
drop policy if exists "equipo: admin inserta"      on public.members;
drop policy if exists "equipo: actualiza"          on public.members;
drop policy if exists "equipo: admin borra"        on public.members;
create policy "equipo: lee" on public.members for select
  using (id = (select auth.uid()) or (select public.is_member()));
create policy "equipo: admin inserta" on public.members for insert
  with check ((select public.is_admin()));
create policy "equipo: actualiza" on public.members for update
  using ((id = (select auth.uid()) and (select public.is_member())) or (select public.is_admin()))
  with check (id = (select auth.uid()) or (select public.is_admin()));   -- columnas limitadas por el grant de 017
create policy "equipo: admin borra" on public.members for delete
  using ((select public.is_admin()));

drop policy if exists "productos: lectura pública" on public.products;
create policy "productos: lectura pública" on public.products for select
  using (is_public or (select public.is_member()));
drop policy if exists "productos: equipo crea" on public.products;
create policy "productos: equipo crea" on public.products for insert with check ((select public.is_member()));
drop policy if exists "productos: equipo edita" on public.products;
create policy "productos: equipo edita" on public.products for update
  using ((select public.is_member())) with check ((select public.is_member()));

drop policy if exists "fotos: equipo escribe" on public.product_photos;
drop policy if exists "fotos: equipo inserta" on public.product_photos;
drop policy if exists "fotos: equipo edita"   on public.product_photos;
drop policy if exists "fotos: equipo borra"   on public.product_photos;
create policy "fotos: equipo inserta" on public.product_photos for insert with check ((select public.is_member()));
create policy "fotos: equipo edita"   on public.product_photos for update
  using ((select public.is_member())) with check ((select public.is_member()));
create policy "fotos: equipo borra"   on public.product_photos for delete using ((select public.is_member()));

drop policy if exists "interés: equipo lee" on public.interests;
create policy "interés: equipo lee" on public.interests for select using ((select public.is_member()));
drop policy if exists "interés: equipo actualiza" on public.interests;
create policy "interés: equipo actualiza" on public.interests for update using ((select public.is_member()));

drop policy if exists "mensajes: equipo lee" on public.messages;
create policy "mensajes: equipo lee" on public.messages for select using ((select public.is_member()));
drop policy if exists "mensajes: equipo escribe" on public.messages;
create policy "mensajes: equipo escribe" on public.messages for insert
  with check (sender = 'vendedor' and (select public.is_member()));
drop policy if exists "mensajes: equipo borra" on public.messages;
create policy "mensajes: equipo borra" on public.messages for delete using ((select public.is_member()));

drop policy if exists "cobro: equipo lee"  on public.payment_settings;
drop policy if exists "cobro: admin edita" on public.payment_settings;
drop policy if exists "cobro: admin inserta" on public.payment_settings;
drop policy if exists "cobro: admin actualiza" on public.payment_settings;
drop policy if exists "cobro: admin borra" on public.payment_settings;
create policy "cobro: equipo lee" on public.payment_settings for select using ((select public.is_member()));
create policy "cobro: admin inserta"   on public.payment_settings for insert with check ((select public.is_admin()));
create policy "cobro: admin actualiza" on public.payment_settings for update
  using ((select public.is_admin())) with check ((select public.is_admin()));
create policy "cobro: admin borra"     on public.payment_settings for delete using ((select public.is_admin()));

drop policy if exists "pagos: equipo lee" on public.payments;
create policy "pagos: equipo lee" on public.payments for select using ((select public.is_member()));
drop policy if exists "pagos: equipo actualiza" on public.payments;
create policy "pagos: equipo actualiza" on public.payments for update using ((select public.is_member()));

drop policy if exists "ofertas: equipo lee" on public.offers;
create policy "ofertas: equipo lee" on public.offers for select using ((select public.is_member()));

drop policy if exists "ajustes: admin edita" on public.site_settings;
drop policy if exists "ajustes: admin inserta" on public.site_settings;
drop policy if exists "ajustes: admin actualiza" on public.site_settings;
drop policy if exists "ajustes: admin borra" on public.site_settings;
create policy "ajustes: admin inserta"   on public.site_settings for insert with check ((select public.is_admin()));
create policy "ajustes: admin actualiza" on public.site_settings for update
  using ((select public.is_admin())) with check ((select public.is_admin()));
create policy "ajustes: admin borra"     on public.site_settings for delete using ((select public.is_admin()));

drop policy if exists "categorías: admin gestiona" on public.categories;
drop policy if exists "categorías: admin inserta" on public.categories;
drop policy if exists "categorías: admin actualiza" on public.categories;
drop policy if exists "categorías: admin borra" on public.categories;
create policy "categorías: admin inserta"   on public.categories for insert with check ((select public.is_admin()));
create policy "categorías: admin actualiza" on public.categories for update
  using ((select public.is_admin())) with check ((select public.is_admin()));
create policy "categorías: admin borra"     on public.categories for delete using ((select public.is_admin()));

drop policy if exists "visitas: solo administradores" on public.visits;
create policy "visitas: solo administradores" on public.visits for select using ((select public.is_admin()));

drop policy if exists "fotos: equipo sube" on storage.objects;
create policy "fotos: equipo sube" on storage.objects for insert
  with check (bucket_id = 'fotos' and (select public.is_member()));
drop policy if exists "fotos: equipo borra" on storage.objects;
create policy "fotos: equipo borra" on storage.objects for delete
  using (bucket_id = 'fotos' and (select public.is_member()));

-- ── F. Realtime: solo lo que alguien escucha; purga de la cola de pg_net ─────
do $$ declare t text;
begin
  foreach t in array array['product_photos','interests','messages','payments','offers'] loop
    begin execute format('alter publication supabase_realtime drop table public.%I', t);
    exception when undefined_object then null; end;
  end loop;
end $$;
do $$ begin perform cron.unschedule('purgar-net'); exception when others then null; end $$;
select cron.schedule('purgar-net', '41 4 * * *', $$delete from net._http_response where created < now() - interval '7 days'$$);

-- ── G. Informe ───────────────────────────────────────────────────────────────
select 'product_stats filas' as chequeo, count(*)::text as valor from public.product_stats
union all select 'catalog cover_thumb', (exists (select 1 from information_schema.columns where table_name='catalog' and column_name='cover_thumb'))::text
union all select 'políticas SELECT members', count(*)::text from pg_policies where tablename='members' and cmd='SELECT'
union all select 'publicación realtime', string_agg(tablename, ',' order by tablename) from pg_publication_tables where pubname='supabase_realtime'
union all select 'cron', string_agg(jobname, ',' order by jobname) from cron.job
union all select 'interests_producto (debe ser 0)', count(*)::text from pg_indexes where indexname='interests_producto';
