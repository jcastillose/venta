-- 009 · Recuperar conversaciones por correo (tope de envíos).
-- Idempotente. Incorporado también en 000-base-completa.sql (bloque 6c).

-- Registro de solicitudes para limitar a 3 por correo cada hora. Solo service_role.
create table if not exists public.recovery_requests (
  email      text not null,
  created_at timestamptz not null default now()
);
create index if not exists recovery_requests_email on public.recovery_requests (email, created_at);
alter table public.recovery_requests enable row level security;
revoke all on public.recovery_requests from anon, authenticated;

-- Devuelve true y anota la solicitud si el correo lleva menos de 3 en la última hora.
create or replace function public.recovery_allowed(p_email text)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  delete from public.recovery_requests where created_at < now() - interval '1 day';
  select count(*) into v_n from public.recovery_requests
   where email = lower(p_email) and created_at > now() - interval '1 hour';
  if v_n >= 3 then return false; end if;
  insert into public.recovery_requests (email) values (lower(p_email));
  return true;
end $$;
revoke execute on function public.recovery_allowed(text) from public, anon, authenticated;
grant execute on function public.recovery_allowed(text) to service_role;
