-- 020 · Rendimiento: miniaturas, índices de FK, RLS sin re-evaluación por fila y purga de visitas. Re-ejecutable.

-- Miniatura por foto (~640 px, generada en el navegador al subir; Ajustes → «Generar miniaturas» para las antiguas).
alter table public.product_photos add column if not exists thumb_path text;

-- Índices para las FK que los advisors marcaban sin cobertura.
create index if not exists products_created_by_idx on public.products (created_by);
create index if not exists products_updated_by_idx on public.products (updated_by);
create index if not exists products_category_idx on public.products (category);
create index if not exists payments_confirmed_by_idx on public.payments (confirmed_by);
create index if not exists payment_settings_updated_by_idx on public.payment_settings (updated_by);
create index if not exists site_settings_updated_by_idx on public.site_settings (updated_by);
-- Catálogo público: filtro y orden habituales.
create index if not exists products_publicos_idx on public.products (created_at desc) where is_public;
-- Visitas: filtros del panel por fecha excluyendo bots.
create index if not exists visits_fecha_no_bot_idx on public.visits (created_at desc) where not bot;

-- RLS: auth.uid() envuelto en (select …) se evalúa una vez por consulta y no por fila.
drop policy if exists "equipo: lee su fila" on public.members;
create policy "equipo: lee su fila" on public.members for select using ((select auth.uid()) = id);
drop policy if exists "equipo: edita su perfil" on public.members;
create policy "equipo: edita su perfil" on public.members
  for update using ((select auth.uid()) = id and public.is_member()) with check ((select auth.uid()) = id);

-- Índice de sesión de visitas sin uso.
drop index if exists public.visits_session_idx;

-- Purga de visitas: se conservan 180 días (el panel muestra hasta 90). Requiere pg_cron.
create extension if not exists pg_cron with schema pg_catalog;
do $$ begin
  perform cron.unschedule('purgar-visitas');
exception when others then null; end $$;
select cron.schedule('purgar-visitas', '17 4 * * *', $$delete from public.visits where created_at < now() - interval '180 days'$$);

-- Verificación
select 'thumb_path' as chequeo, count(*)::text from information_schema.columns where table_name = 'product_photos' and column_name = 'thumb_path'
union all
select 'índices nuevos', count(*)::text from pg_indexes where indexname in ('products_created_by_idx','products_updated_by_idx','products_category_idx','payments_confirmed_by_idx','payment_settings_updated_by_idx','site_settings_updated_by_idx','products_publicos_idx','visits_fecha_no_bot_idx')
union all
select 'cron purga', coalesce((select schedule from cron.job where jobname = 'purgar-visitas'), 'sin programar');
