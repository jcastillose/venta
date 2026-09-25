-- 018 · El secreto de los avisos sale del código: aviso_webhook() lo lee de Vault.
-- Re-ejecutable. Sustituye la función creada por 014 (los triggers no cambian).
--
-- Antes de ejecutar este archivo, guarda el secreto en Vault UNA vez desde el SQL Editor
-- (mismo valor que AVISOS_SECRET en Netlify; no lo pegues en ningún archivo ni chat):
--
--   select vault.create_secret('EL_VALOR_NUEVO', 'avisos_secret');
--
-- Para rotarlo después:
--
--   select vault.update_secret((select id from vault.secrets where name = 'avisos_secret'), 'OTRO_VALOR');
--
-- Si el secreto no existe, la función envía la cabecera vacía y Netlify responde 403 (no se rompe nada más).

create or replace function public.aviso_webhook() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
declare v_secret text;
begin
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'avisos_secret' limit 1;
  perform net.http_post(
    url := 'https://mobventa.netlify.app/.netlify/functions/avisos',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-avisos-secret', coalesce(v_secret, '')),
    body := jsonb_build_object(
      'type', tg_op, 'table', tg_table_name, 'schema', tg_table_schema,
      'record', case when tg_op = 'DELETE' then null else to_jsonb(new) end,
      'old_record', case when tg_op = 'INSERT' then null else to_jsonb(old) end),
    timeout_milliseconds := 5000);
  return coalesce(new, old);
end $$;
revoke execute on function public.aviso_webhook() from public, anon, authenticated;

-- Verificación: debe devolver 'avisos_secret' (sin mostrar el valor) y la función sin secreto literal.
select name, created_at from vault.secrets where name = 'avisos_secret';
select proname, (prosrc not like '%x-avisos-secret'', ''%') as sin_secreto_literal from pg_proc where proname = 'aviso_webhook';
