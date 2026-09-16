-- Migración: título del sitio editable desde Administración → Ajustes. Re-ejecutable.
-- Requiere 003-ajustes.sql (tabla site_settings).

insert into public.site_settings (key, value)
values ('titulo_sitio', to_jsonb('Oferta de Muebles y Electrodomésticos'::text))
on conflict (key) do nothing;
