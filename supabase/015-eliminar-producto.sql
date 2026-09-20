-- 015 · Eliminar un producto publicado desde el panel.
-- Idempotente. Incorporado también en 000-base-completa.sql (bloque 6g).
--
-- Borra el producto y, en cascada, sus fotos (filas), interesados, mensajes,
-- ofertas y pagos; los enlaces privados de sus hilos dejan de funcionar.
-- Bloqueado si algún interesado ya tiene un pago confirmado. Devuelve las rutas
-- de las fotos en Storage para que el panel las borre del bucket `fotos`.
create or replace function public.delete_product(p_product uuid)
returns text[] language plpgsql security definer set search_path = public as $$
declare v_paths text[];
begin
  if not public.is_member() then raise exception 'Solo el equipo puede eliminar productos'; end if;
  if not exists (select 1 from public.products where id = p_product) then return '{}'; end if;
  if exists (
    select 1 from public.payments y join public.interests i on i.id = y.interest_id
    where i.product_id = p_product and y.status = 'pagado'
  ) then
    raise exception 'Este producto tiene un pago confirmado: no se puede eliminar. Márcalo como vendido u ocúltalo.';
  end if;
  select coalesce(array_agg(storage_path), '{}') into v_paths from public.product_photos where product_id = p_product;
  delete from public.products where id = p_product;
  return v_paths;
end $$;
revoke all on function public.delete_product(uuid) from public;
grant execute on function public.delete_product(uuid) to authenticated;

-- El nombre por defecto del sitio pasa a MobVenta (solo si nadie lo cambió en Ajustes).
update public.site_settings set value = to_jsonb('MobVenta'::text)
  where key = 'titulo_sitio' and value = to_jsonb('Oferta de Muebles y Electrodomésticos'::text);

select 'ok' as delete_product where exists (select 1 from pg_proc where proname = 'delete_product');
