-- 022 · Latido: mantiene el proyecto con actividad de usuarios para que Supabase (plan gratuito)
-- no lo pause tras 7 días de poco uso. Re-ejecutable. Ver docs/MANTENIMIENTO.md.
--
-- Dos disparadores externos llaman a latido() a través de la API:
--   'netlify'  función programada netlify/functions/latido.js (cada 6 h)
--   'sentry'   monitor de disponibilidad de Sentry (cada hora, directo a Supabase; avisa si no responde)

create table if not exists public.latidos (
  origen text primary key,
  ultimo timestamptz not null default now(),
  total  bigint not null default 1
);
alter table public.latidos enable row level security;
revoke all on public.latidos from anon, authenticated;
grant select on public.latidos to authenticated;
drop policy if exists "latidos: equipo lee" on public.latidos;
create policy "latidos: equipo lee" on public.latidos for select using ((select public.is_member()));

-- Solo orígenes conocidos y como mucho una escritura cada 10 minutos por origen:
-- la función es pública (la llama Sentry con la clave anónima) y no debe servir para llenar la base.
create or replace function public.latido(p_origen text default 'netlify') returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_ultimo timestamptz;
begin
  if p_origen not in ('netlify', 'sentry') then raise exception 'origen desconocido'; end if;
  insert into public.latidos as l (origen) values (p_origen)
  on conflict (origen) do update set ultimo = now(), total = l.total + 1
    where l.ultimo < now() - interval '10 minutes'
  returning ultimo into v_ultimo;
  if v_ultimo is null then select ultimo into v_ultimo from public.latidos where origen = p_origen; end if;
  return jsonb_build_object('ok', true, 'origen', p_origen, 'ultimo', v_ultimo);
end $$;
revoke all on function public.latido(text) from public;
grant execute on function public.latido(text) to anon, authenticated, service_role;

select 'latidos' as chequeo, coalesce(string_agg(origen || ' ' || to_char(ultimo, 'YYYY-MM-DD HH24:MI') || ' x' || total, ' | '), 'sin latidos aún') as valor from public.latidos;
