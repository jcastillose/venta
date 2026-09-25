-- Alta de la primera cuenta de administrador + contraseña inicial.
-- Ejecutar DESPUÉS de 000-base-completa.sql. Crea el usuario en Auth si no existe.
-- Supabase → SQL Editor → pegar todo → Run. Re-ejecutable: si el usuario ya existe, NO toca su contraseña.

-- 1. Cambia estos tres valores y nada más. NUNCA subas este archivo con valores reales.
--    La contraseña es temporal: cámbiala luego en la pantalla "Mi cuenta".
do $$
declare
  v_email    text := 'tu-correo@ejemplo.cl';
  v_nombre   text := 'Nombre Apellido';
  v_password text := 'CAMBIAR-ANTES-DE-EJECUTAR';
  v_id       uuid;
begin
  select id into v_id from auth.users where lower(email) = lower(v_email);

  if v_password = 'CAMBIAR-ANTES-DE-EJECUTAR' then raise exception 'Define v_password antes de ejecutar'; end if;
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

  -- Correo confirmado y metadatos; la contraseña solo se fija al crear el usuario (arriba).
  update auth.users
     set email_confirmed_at = coalesce(email_confirmed_at, now()),
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
