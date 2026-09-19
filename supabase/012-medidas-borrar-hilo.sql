-- 012 · Medidas por producto y borrado de conversación por el interesado.
-- Idempotente. Incorporado también en 000-base-completa.sql.

-- (b) Medidas: texto libre por dimensión, se muestran solo si tienen valor.
alter table public.products add column if not exists width_cm  numeric(7,1);
alter table public.products add column if not exists height_cm numeric(7,1);
alter table public.products add column if not exists depth_cm  numeric(7,1);
alter table public.products add column if not exists weight_kg numeric(7,1);

-- La vista catalog se recrea con p.* así que expone las columnas nuevas.
drop view if exists public.catalog;
create view public.catalog as
  select p.*, m.name as published_by,
         (select count(*) from public.interests i where i.product_id = p.id) as interested_count,
         case when public.setting_on('ofertas_publicas') then o.top_offer_clp end as top_offer_clp,
         case when public.setting_on('ofertas_publicas') then coalesce(o.offer_count, 0) else 0 end as offer_count
  from public.products p
  join public.members m on m.id = p.created_by
  left join public.offer_summary o on o.product_id = p.id
  where p.is_public;
grant select on public.catalog to anon, authenticated;

-- (c) El interesado borra su propia conversación con su token. Se elimina el hilo
-- completo (mensajes, oferta y pago en cascada); si estaba reservado, el producto
-- vuelve a disponible. No se permite si el pago ya fue confirmado ni si está vendido.
create or replace function public.delete_thread_by_token(p_token text)
returns void language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_product uuid; v_status public.interest_status;
begin
  select id, product_id, status into v_id, v_product, v_status from public.interests where token = p_token;
  if v_id is null then return; end if;
  if v_status = 'vendido' then raise exception 'Este trato ya se cerró: no se puede borrar'; end if;
  if exists (select 1 from public.payments where interest_id = v_id and status = 'pagado') then
    raise exception 'Hay un pago confirmado: escribe al equipo para cerrar la conversación';
  end if;
  delete from public.interests where id = v_id;
  if v_status = 'reservado' then
    update public.products set status = 'disponible' where id = v_product and status = 'reservado';
  end if;
end $$;
grant execute on function public.delete_thread_by_token(text) to anon, authenticated;
