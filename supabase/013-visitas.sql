-- 013 · Registro de visitas y estadísticas de productos.
-- Idempotente. Incorporado también en 000-base-completa.sql (bloque 6f).
--
-- Cada visita la registra la función Netlify `visita.js` con la clave service_role:
-- IP, país, región, ciudad y coordenadas vienen de las cabeceras geográficas de
-- Netlify (sin servicio externo). La tabla no es legible con la clave pública:
-- solo administradores activos (is_admin) la leen; nadie inserta desde el navegador.

create table if not exists public.visits (
  id          bigint generated always as identity primary key,
  created_at  timestamptz not null default now(),
  event       text not null check (event in ('catalogo','producto','interes','busqueda','categoria')),
  path        text,
  product_id  uuid references public.products(id) on delete set null,
  category    text,
  query       text,
  referrer    text,
  session_id  text,
  ip          text,
  country     text,
  region      text,
  city        text,
  lat         double precision,
  lon         double precision,
  device      text,
  agent       text,
  bot         boolean not null default false
);
create index if not exists visits_created_idx on public.visits (created_at desc);
create index if not exists visits_product_idx on public.visits (product_id, event);
create index if not exists visits_session_idx on public.visits (session_id);

alter table public.visits enable row level security;
revoke all on public.visits from anon, authenticated;
grant select on public.visits to authenticated;
drop policy if exists "visitas: solo administradores" on public.visits;
create policy "visitas: solo administradores" on public.visits for select using (public.is_admin());

-- Resumen agregado para el panel: totales, serie diaria, productos, lugares,
-- dispositivos, procedencias, búsquedas, categorías y puntos para el mapa.
create or replace function public.visits_summary(p_from timestamptz, p_to timestamptz, p_bots boolean default false)
returns json language plpgsql security definer set search_path = public stable as $$
declare r json;
begin
  if not public.is_admin() then raise exception 'sin permiso'; end if;
  with v as (
    select * from public.visits
    where created_at >= p_from and created_at < p_to and (p_bots or not bot)
  )
  select json_build_object(
    'total',    (select count(*) from v),
    'unicos',   (select count(distinct coalesce(session_id, ip)) from v),
    'n_paises', (select count(distinct country) from v where country is not null),
    'bots',     (select count(*) from public.visits where created_at >= p_from and created_at < p_to and bot),
    'por_dia',  (select coalesce(json_agg(json_build_object('dia', d.dia, 'n', d.n, 'u', d.u) order by d.dia), '[]') from (
                   select (created_at at time zone 'America/Santiago')::date as dia,
                          count(*) as n, count(distinct coalesce(session_id, ip)) as u
                   from v group by 1) d),
    'productos', (select coalesce(json_agg(json_build_object('id', p.id, 'title', p.title, 'status', p.status,
                                                             'vistas', x.vistas, 'intereses', x.intereses) order by x.vistas desc), '[]')
                  from (select product_id,
                               count(*) filter (where event = 'producto') as vistas,
                               count(*) filter (where event = 'interes')  as intereses
                        from v where product_id is not null group by 1 order by 2 desc limit 20) x
                  join public.products p on p.id = x.product_id),
    'paises',   (select coalesce(json_agg(json_build_object('k', country, 'n', n) order by n desc), '[]') from (
                   select country, count(*) as n from v where country is not null group by 1 order by 2 desc limit 12) t),
    'ciudades', (select coalesce(json_agg(json_build_object('k', city, 'pais', country, 'n', n) order by n desc), '[]') from (
                   select city, country, count(*) as n from v where city is not null group by 1, 2 order by 3 desc limit 12) t),
    'dispositivos', (select coalesce(json_agg(json_build_object('k', coalesce(device, 'desconocido'), 'n', n) order by n desc), '[]') from (
                   select device, count(*) as n from v group by 1) t),
    'referencias', (select coalesce(json_agg(json_build_object('k', host, 'n', n) order by n desc), '[]') from (
                   select regexp_replace(referrer, '^https?://(www\.)?([^/]+).*$', '\2') as host, count(*) as n
                   from v where referrer is not null and referrer !~* 'mobventa\.netlify\.app'
                   group by 1 order by 2 desc limit 10) t),
    'busquedas', (select coalesce(json_agg(json_build_object('k', query, 'n', n) order by n desc), '[]') from (
                   select lower(trim(query)) as query, count(*) as n from v where event = 'busqueda' and coalesce(trim(query), '') <> ''
                   group by 1 order by 2 desc limit 15) t),
    'categorias', (select coalesce(json_agg(json_build_object('k', category, 'n', n) order by n desc), '[]') from (
                   select category, count(*) as n from v where event = 'categoria' and category is not null group by 1 order by 2 desc limit 12) t),
    'puntos',   (select coalesce(json_agg(json_build_object('lat', lat, 'lon', lon, 'city', city, 'pais', country, 'n', n)), '[]') from (
                   select round(lat::numeric, 2) as lat, round(lon::numeric, 2) as lon, min(city) as city, min(country) as country, count(*) as n
                   from v where lat is not null and lon is not null group by 1, 2 order by 5 desc limit 300) t)
  ) into r;
  return r;
end $$;
revoke all on function public.visits_summary(timestamptz, timestamptz, boolean) from public;
grant execute on function public.visits_summary(timestamptz, timestamptz, boolean) to authenticated;
