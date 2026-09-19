-- 011 · Visibilidad pública por producto (borrador / oculto).
-- Idempotente. Incorporado también en 000-base-completa.sql.

alter table public.products add column if not exists is_public boolean not null default true;

-- El catálogo público solo muestra productos visibles. El panel sigue leyendo
-- products directamente (RLS del equipo), así que ve todo.
drop view if exists public.catalog;
create view public.catalog as
  select p.*, m.name as published_by,
         (select count(*) from public.interests i where i.product_id = p.id) as interested_count,
         case when public.setting_on('ofertas_publicas') then o.top_offer_clp end as top_offer_clp,
         case when public.setting_on('ofertas_publicas') then coalesce(o.offer_count, 0) else 0 end as offer_count
  from public.products p
  join public.members m on m.id = p.created_by
  left join public.offer_summary o on o.product_id = p.id
  where p.is_public;
grant select on public.catalog to anon, authenticated;

-- La lectura pública directa de products también se restringe a los visibles
-- (el equipo conserva acceso total por su política propia).
drop policy if exists "productos: lectura pública" on public.products;
create policy "productos: lectura pública" on public.products for select using (is_public or public.is_member());

-- No se puede marcar interés en un producto oculto (mismo cuerpo que la versión vigente).
-- Se aplica editando create_interest en 000-base-completa.sql; aquí solo la comprobación:
--   select accepts_offers, is_public into v_on, v_public from public.products where id = p_product and status <> 'vendido';
--   if v_on is null or not v_public then raise exception 'Producto no disponible'; end if;
