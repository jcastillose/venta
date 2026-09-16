-- Migración: categorías editables y condición como catálogo cerrado. Re-ejecutable.

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
    -- las vistas dependen de la columna: se recrean más abajo
    drop view if exists public.catalog;
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

-- 3. Recrear la vista del catálogo (misma definición que 003).
create or replace view public.catalog as
  select p.*, m.name as published_by,
         (select count(*) from public.interests i where i.product_id = p.id) as interested_count,
         case when public.setting_on('ofertas_publicas') then o.top_offer_clp end as top_offer_clp,
         case when public.setting_on('ofertas_publicas') then coalesce(o.offer_count, 0) else 0 end as offer_count
  from public.products p
  join public.members m on m.id = p.created_by
  left join public.offer_summary o on o.product_id = p.id;
grant select on public.catalog to anon, authenticated;

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

do $$ begin
  execute 'alter publication supabase_realtime add table public.categories';
exception when duplicate_object then null; end $$;
