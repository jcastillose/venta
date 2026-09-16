-- Migración: ofertas activables por producto. Re-ejecutable.
-- `ofertas_habilitadas` (global) pasa a ser un interruptor masivo: al cambiarlo se
-- actualiza `accepts_offers` en todos los productos y se usa como valor por defecto
-- para los nuevos. Lo que rige en cada producto es su propio `accepts_offers`.

alter table public.products add column if not exists accepts_offers boolean not null default true;

-- El catálogo expone la columna nueva. La vista se recrea (p.* se expandió al
-- crearla y `create or replace` no puede insertar columnas en medio).
drop view if exists public.catalog;
create view public.catalog as
  select p.*, m.name as published_by,
         (select count(*) from public.interests i where i.product_id = p.id) as interested_count,
         case when public.setting_on('ofertas_publicas') then o.top_offer_clp end as top_offer_clp,
         case when public.setting_on('ofertas_publicas') then coalesce(o.offer_count, 0) else 0 end as offer_count
  from public.products p
  join public.members m on m.id = p.created_by
  left join public.offer_summary o on o.product_id = p.id;
grant select on public.catalog to anon, authenticated;

-- Interruptor global: cambia el ajuste y el estado de todos los productos a la vez.
create or replace function public.set_offers_for_all(p_on boolean) returns integer
language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if not public.is_admin() then raise exception 'Solo un administrador puede cambiar este ajuste'; end if;
  insert into public.site_settings (key, value, updated_by, updated_at)
  values ('ofertas_habilitadas', to_jsonb(p_on), auth.uid(), now())
  on conflict (key) do update set value = excluded.value, updated_by = excluded.updated_by, updated_at = now();
  update public.products set accepts_offers = p_on where accepts_offers <> p_on;
  get diagnostics n = row_count;
  return n;
end $$;
grant execute on function public.set_offers_for_all(boolean) to authenticated;

-- Ofertar desde el hilo: rige el interruptor del producto.
create or replace function public.place_offer_by_token(p_token text, p_amount integer)
returns table (my_offer_clp integer, top_offer_clp integer, offer_count bigint)
language plpgsql security definer set search_path = public as $$
declare v_interest uuid; v_product uuid; v_status public.product_status; v_on boolean;
begin
  if p_amount is null or p_amount <= 0 then raise exception 'La oferta debe ser mayor que cero'; end if;
  select i.id, i.product_id, p.status, p.accepts_offers into v_interest, v_product, v_status, v_on
  from public.interests i join public.products p on p.id = i.product_id where i.token = p_token;
  if v_interest is null then raise exception 'token inválido'; end if;
  if not v_on then raise exception 'Las ofertas están desactivadas para este producto'; end if;
  if v_status = 'vendido' then raise exception 'El producto ya fue vendido'; end if;

  insert into public.offers (interest_id, product_id, amount_clp)
  values (v_interest, v_product, p_amount)
  on conflict (interest_id) do update set amount_clp = excluded.amount_clp, updated_at = now();

  insert into public.messages (interest_id, sender, body)
  values (v_interest, 'interesado', 'Ofrezco $' || to_char(p_amount, 'FM999G999G999') || '.');
  update public.interests set status = 'conversando' where id = v_interest and status = 'nuevo';

  return query
    select p_amount,
           case when public.setting_on('ofertas_publicas') then s.top_offer_clp end,
           case when public.setting_on('ofertas_publicas') then s.offer_count else 0::bigint end
    from public.offer_summary s where s.product_id = v_product;
end $$;

-- Marcar interés: la oferta solo se registra si el producto la acepta.
create or replace function public.create_interest(
  p_product uuid, p_name text, p_contact text, p_message text default null, p_offer integer default null)
returns text
language plpgsql security definer set search_path = public as $$
declare v_token text; v_id uuid; v_on boolean;
begin
  if coalesce(trim(p_name), '') = '' or coalesce(trim(p_contact), '') = '' then
    raise exception 'Nombre y contacto son obligatorios';
  end if;
  select accepts_offers into v_on from public.products where id = p_product and status <> 'vendido';
  if v_on is null then raise exception 'Producto no disponible'; end if;
  if not v_on then p_offer := null; end if;
  if p_offer is not null and p_offer <= 0 then
    raise exception 'La oferta debe ser mayor que cero';
  end if;

  insert into public.interests (product_id, buyer_name, buyer_contact)
  values (p_product, trim(p_name), trim(p_contact))
  returning id, token into v_id, v_token;

  if p_offer is not null then
    insert into public.offers (interest_id, product_id, amount_clp) values (v_id, p_product, p_offer);
    insert into public.messages (interest_id, sender, body)
    values (v_id, 'interesado', 'Ofrezco $' || to_char(p_offer, 'FM999G999G999') || '.');
  end if;
  if coalesce(trim(p_message), '') <> '' then
    insert into public.messages (interest_id, sender, body) values (v_id, 'interesado', trim(p_message));
  end if;
  return v_token;
end $$;

-- El hilo informa si ese producto acepta ofertas.
drop function if exists public.thread_by_token(text);
create or replace function public.thread_by_token(p_token text)
returns table (interest_id uuid, product_id uuid, product_title text, price_clp integer,
               product_status public.product_status, interest_status public.interest_status,
               published_by text, buyer_name text,
               payment_method public.pay_method, payment_status public.payment_status,
               payment_reference text,
               my_offer_clp integer, top_offer_clp integer, offer_count bigint,
               offers_enabled boolean)
language sql security definer set search_path = public stable as $$
  select i.id, p.id, p.title, p.price_clp, p.status, i.status, m.name, i.buyer_name,
         y.method, y.status, y.reference,
         o.amount_clp,
         case when public.setting_on('ofertas_publicas') then s.top_offer_clp end,
         case when public.setting_on('ofertas_publicas') then coalesce(s.offer_count, 0) else 0::bigint end,
         p.accepts_offers
  from public.interests i
  join public.products p on p.id = i.product_id
  join public.members  m on m.id = p.created_by
  left join public.payments y on y.interest_id = i.id
  left join public.offers   o on o.interest_id = i.id
  left join public.offer_summary s on s.product_id = p.id
  where i.token = p_token;
$$;

grant execute on function public.thread_by_token(text),
  public.place_offer_by_token(text, integer), public.create_interest(uuid, text, text, text, integer)
  to anon, authenticated;
