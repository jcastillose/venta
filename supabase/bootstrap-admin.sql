-- Alta de la primera cuenta de administrador + contraseña inicial.
-- Ejecutar DESPUÉS de schema.sql y después de haber entrado al menos una vez
-- (el usuario debe existir en auth.users).
-- Supabase → SQL Editor → pegar todo → Run. Re-ejecutable.

-- 1. Cambia estos tres valores y nada más.
--    La contraseña es temporal: cámbiala luego en la pantalla "Mi cuenta".
do $$
declare
  v_email    text := 'jcastillo.se@gmail.com';
  v_nombre   text := 'Jorge Castillo Sepúlveda';
  v_password text := 'CambiaEstaClave123';
  v_id       uuid;
begin
  select id into v_id from auth.users where lower(email) = lower(v_email);

  if v_id is null then
    -- Crear el usuario directamente (no hay aún quien lo invite desde el panel).
    v_id := gen_random_uuid();
    insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                            raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    values ('00000000-0000-0000-0000-000000000000', v_id, 'authenticated', 'authenticated', lower(v_email),
            crypt(v_password, gen_salt('bf')), now(),
            '{"provider":"email","providers":["email"]}'::jsonb,
            jsonb_build_object('name', v_nombre, 'equipo', true, 'role', 'admin', 'tiene_password', true),
            now(), now());
    insert into auth.identities (id, user_id, provider_id, provider, identity_data, last_sign_in_at, created_at, updated_at)
    values (gen_random_uuid(), v_id, lower(v_email), 'email',
            jsonb_build_object('sub', v_id::text, 'email', lower(v_email), 'email_verified', true), now(), now(), now());
  end if;

  -- Cuenta del equipo con rol admin.
  insert into public.members (id, name, email, role, status)
  values (v_id, v_nombre, v_email, 'admin', 'activo')
  on conflict (id) do update
    set name = excluded.name, email = excluded.email, role = 'admin', status = 'activo';

  -- Contraseña inicial, sin pasar por el correo (evita el límite de envíos).
  update auth.users
     set encrypted_password = crypt(v_password, gen_salt('bf')),
         email_confirmed_at = coalesce(email_confirmed_at, now()),
         raw_user_meta_data = coalesce(raw_user_meta_data, '{}'::jsonb) || jsonb_build_object('name', v_nombre, 'equipo', true, 'tiene_password', true),
         updated_at = now()
   where id = v_id;

  raise notice 'Listo: % es administrador. Entra con la contraseña indicada y cámbiala en Mi cuenta.', v_email;
end $$;

-- 2. Verificación: debe mostrar tu fila como admin / activo.
select m.name, m.email, m.role, m.status, u.email_confirmed_at is not null as correo_confirmado
from public.members m
join auth.users u on u.id = m.id
order by m.created_at;
