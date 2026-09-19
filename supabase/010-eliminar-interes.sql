-- 010 · Eliminar un interesado (hilo completo) desde el panel.
-- Idempotente. Incorporado también en 000-base-completa.sql (bloque 6d).

-- Borra el interés y, en cascada, sus mensajes, oferta y pago. Si estaba reservado,
-- el producto vuelve a disponible. No se puede si el pago ya fue confirmado.
create or replace function public.delete_interest(p_interest uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_product uuid; v_status public.interest_status;
begin
  if not public.is_member() then raise exception 'sin permiso'; end if;
  select product_id, status into v_product, v_status from public.interests where id = p_interest;
  if v_product is null then return; end if;
  if exists (select 1 from public.payments where interest_id = p_interest and status = 'pagado') then
    raise exception 'Este interesado ya pagó: no se puede eliminar';
  end if;
  delete from public.interests where id = p_interest;
  if v_status = 'reservado' then
    update public.products set status = 'disponible' where id = v_product and status = 'reservado';
  end if;
end $$;
grant execute on function public.delete_interest(uuid) to authenticated;
