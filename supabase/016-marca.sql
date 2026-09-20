-- 016 · Marca del sitio: logo propio o texto.
-- Idempotente. Incorporado también en 000-base-completa.sql.
--
--   marca_tipo  "logo" (imagen, por defecto) | "texto" (solo el nombre del sitio)
--   marca_logo  ruta del logo subido dentro del bucket `fotos` ("" = usa /src/logo.png)
-- Ambos se editan en Administración → Ajustes → Marca del sitio (solo administradores;
-- la política «ajustes: admin edita» de 003-ajustes.sql ya los cubre).

insert into public.site_settings (key, value) values
  ('marca_tipo', '"logo"'::jsonb),
  ('marca_logo', '""'::jsonb)
on conflict (key) do nothing;

select 'ok' as marca, (select value #>> '{}' from public.site_settings where key = 'marca_tipo') as tipo;
