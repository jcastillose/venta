-- 019 · Límites al marcar interés y una sola reserva por producto. Re-ejecutable.
-- Cierra los hallazgos A2 (spam de intereses y correos) y M3 (reservas múltiples) de la revisión.

-- Longitudes acotadas (antes: sin límite).
alter table public.interests drop constraint if exists interests_buyer_name_len;
alter table public.interests add constraint interests_buyer_name_len check (length(buyer_name) between 1 and 120);
alter table public.interests drop constraint if exists interests_buyer_contact_len;
alter table public.interests add constraint interests_buyer_contact_len check (length(buyer_contact) between 3 and 200);

-- Búsquedas por contacto (topes y recuperación de conversaciones).
create index if not exists interests_contact_idx on public.interests (lower(buyer_contact), created_at desc);

-- Una sola reserva o venta activa por producto.
create unique index if not exists interests_una_reserva on public.interests (product_id)
  where status in ('reservado', 'vendido');

-- create_interest con topes: 1 hilo abierto por contacto y producto, 5 intereses por contacto y hora,
-- 30 por producto cada 10 minutos.
create or replace function public.create_interest(p_product uuid, p_name text, p_contact text, p_message text default null, p_offer integer default null)
returns text language plpgsql security definer set search_path = public as $$
declare v_token text; v_id uuid; v_on boolean; v_public boolean;
begin
  p_name := trim(coalesce(p_name, ''));
  p_contact := trim(coalesce(p_contact, ''));
  if p_name = '' or p_contact = '' then
    raise exception 'Nombre y contacto son obligatorios';
  end if;
  if length(p_name) > 120 or length(p_contact) > 200 or length(p_contact) < 3 then
    raise exception 'Revisa el nombre y el contacto: son demasiado largos o demasiado cortos';
  end if;
  select accepts_offers, is_public into v_on, v_public from public.products where id = p_product and status <> 'vendido';
  if v_on is null or not v_public then raise exception 'Producto no disponible'; end if;

  if exists (select 1 from public.interests
             where product_id = p_product and lower(buyer_contact) = lower(p_contact) and status <> 'descartado') then
    raise exception 'Ya hay una conversación abierta sobre este producto con ese contacto. Usa el enlace que recibiste o recupéralo en /mis-conversaciones';
  end if;
  if (select count(*) from public.interests
      where lower(buyer_contact) = lower(p_contact) and created_at > now() - interval '1 hour') >= 5 then
    raise exception 'Demasiadas solicitudes en poco tiempo con ese contacto. Inténtalo más tarde';
  end if;
  if (select count(*) from public.interests
      where product_id = p_product and created_at > now() - interval '10 minutes') >= 30 then
    raise exception 'Este producto está recibiendo muchas solicitudes ahora mismo. Inténtalo en unos minutos';
  end if;

  if not v_on then p_offer := null; end if;
  if p_offer is not null and p_offer <= 0 then
    raise exception 'La oferta debe ser mayor que cero';
  end if;

  insert into public.interests (product_id, buyer_name, buyer_contact)
  values (p_product, p_name, p_contact)
  returning id, token into v_id, v_token;

  if p_offer is not null then
    insert into public.offers (interest_id, product_id, amount_clp) values (v_id, p_product, p_offer);
    insert into public.messages (interest_id, sender, body)
    values (v_id, 'interesado', 'Ofrezco $' || to_char(p_offer, 'FM999G999G999') || '.');
  end if;
  if coalesce(trim(p_message), '') <> '' then
    insert into public.messages (interest_id, sender, body) values (v_id, 'interesado', left(trim(p_message), 2000));
  end if;
  return v_token;
end $$;

-- close_deal: no reservar ni vender si otro interés del mismo producto ya está reservado o vendido.
create or replace function public.close_deal(p_interest uuid, p_status public.product_status)
returns void language plpgsql security definer set search_path = public as $$
declare v_product uuid;
begin
  if not public.is_member() then raise exception 'no autorizado'; end if;
  if p_status not in ('reservado', 'vendido') then raise exception 'estado no permitido: %', p_status; end if;
  select i.product_id into v_product from public.interests i where i.id = p_interest;
  if v_product is null then raise exception 'interés inexistente'; end if;
  if exists (select 1 from public.interests
             where product_id = v_product and id <> p_interest and status in ('reservado', 'vendido')) then
    raise exception 'Este producto ya está reservado o vendido para otra persona. Reabre ese interés antes de cambiarlo';
  end if;
  update public.products  set status = p_status, updated_at = now(), updated_by = auth.uid() where id = v_product;
  update public.interests set status = p_status::text::public.interest_status where id = p_interest;
end $$;

-- Verificación
select 'constraints' as chequeo, string_agg(conname, ', ') as valor from pg_constraint where conrelid = 'public.interests'::regclass and conname like 'interests_buyer_%'
union all
select 'índice única reserva', count(*)::text from pg_indexes where indexname = 'interests_una_reserva'
union all
select 'create_interest con topes', case when prosrc like '%interval ''1 hour''%' then 'sí' else 'no' end from pg_proc where proname = 'create_interest';
