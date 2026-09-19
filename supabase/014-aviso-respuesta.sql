-- 014 · Aviso por correo al interesado cuando el equipo responde.
-- Idempotente. Incorporado también en 000-base-completa.sql.
--
-- Reemplaza la creación manual de webhooks en la interfaz: los tres avisos
-- existentes y el nuevo se disparan desde una sola función de trigger.
-- REEMPLAZA 'TU_SECRETO' por el valor exacto de AVISOS_SECRET en Netlify.

create extension if not exists pg_net with schema extensions;

create or replace function public.aviso_webhook() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform net.http_post(
    url := 'https://mobventa.netlify.app/.netlify/functions/avisos',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-avisos-secret', 'TU_SECRETO'),
    body := jsonb_build_object(
      'type', tg_op, 'table', tg_table_name, 'schema', tg_table_schema,
      'record', case when tg_op = 'DELETE' then null else to_jsonb(new) end,
      'old_record', case when tg_op = 'INSERT' then null else to_jsonb(old) end),
    timeout_milliseconds := 5000);
  return coalesce(new, old);
end $$;

drop trigger if exists "aviso-interes" on public.interests;
create trigger "aviso-interes" after insert on public.interests
  for each row execute function public.aviso_webhook();

drop trigger if exists "aviso-pago" on public.payments;
create trigger "aviso-pago" after insert on public.payments
  for each row execute function public.aviso_webhook();

drop trigger if exists "aviso-cuenta" on public.members;
create trigger "aviso-cuenta" after update on public.members
  for each row execute function public.aviso_webhook();

-- Nuevo: solo los mensajes que escribe el equipo (sender = 'vendedor').
drop trigger if exists "aviso-respuesta" on public.messages;
create trigger "aviso-respuesta" after insert on public.messages
  for each row when (new.sender = 'vendedor') execute function public.aviso_webhook();

select tgname, tgrelid::regclass as tabla from pg_trigger where tgname like 'aviso-%' order by 1;
