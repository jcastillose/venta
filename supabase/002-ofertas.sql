-- Migración: ofertas de interesados.
-- Re-ejecutable. Correr completo en el SQL Editor después de schema.sql.

-- Una oferta por interés (la persona puede mejorarla; se guarda la última).
create table if not exists public.offers (
  id           uuid primary key default gen_random_uuid(),
  interest_id  uuid not null unique references public.interests(id) on delete cascade,
  product_id   uuid not null references public.products(id) on delete cascade,
  amount_clp   integer not null check (amount_clp > 0),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index if not exists offers_producto_monto on public.offers (product_id, amount_clp desc);

alter table public.offers enable row level security;

drop policy if exists "ofertas: equipo lee" on public.offers;
create policy "ofertas: equipo lee" on public.offers for select using (public.is_member());

-- Resumen público por producto: solo el monto más alto y la cantidad, nunca quién.
create or replace view public.offer_summary as
  select product_id,
         max(amount_clp)          as top_offer_clp,
         count(*)                 as offer_count,
         max(updated_at)          as last_offer_at
  from public.offers
  group by product_id;

grant select on public.offer_summary to anon, authenticated;
grant all on public.offers to authenticated, service_role;

-- El catálogo incluye la oferta más alta.
create or replace view public.catalog as
  select p.*, m.name as published_by,
         (select count(*) from public.interests i where i.product_id = p.id) as interested_count,
         o.top_offer_clp, coalesce(o.offer_count, 0) as offer_count
  from public.products p
  join public.members m on m.id = p.created_by
  left join public.offer_summary o on o.product_id = p.id;
grant select on public.catalog to anon, authenticated;

-- Marcar interés con oferta opcional.
create or replace function public.create_interest(
  p_product uuid, p_name text, p_contact text, p_message text default null, p_offer integer default null)
returns text
language plpgsql security definer set search_path = public as $$
declare v_token text; v_id uuid;
begin
  if coalesce(trim(p_name), '') = '' or coalesce(trim(p_contact), '') = '' then
    raise exception 'Nombre y contacto son obligatorios';
  end if;
  if not exists (select 1 from public.products where id = p_product and status <> 'vendido') then
    raise exception 'Producto no disponible';
  end if;
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

-- Hacer o mejorar una oferta desde el hilo privado.
create or replace function public.place_offer_by_token(p_token text, p_amount integer)
returns table (my_offer_clp integer, top_offer_clp integer, offer_count bigint)
language plpgsql security definer set search_path = public as $$
declare v_interest uuid; v_product uuid; v_status public.product_status;
begin
  if p_amount is null or p_amount <= 0 then raise exception 'La oferta debe ser mayor que cero'; end if;
  select i.id, i.product_id, p.status into v_interest, v_product, v_status
  from public.interests i join public.products p on p.id = i.product_id where i.token = p_token;
  if v_interest is null then raise exception 'token inválido'; end if;
  if v_status = 'vendido' then raise exception 'El producto ya fue vendido'; end if;

  insert into public.offers (interest_id, product_id, amount_clp)
  values (v_interest, v_product, p_amount)
  on conflict (interest_id) do update set amount_clp = excluded.amount_clp, updated_at = now();

  insert into public.messages (interest_id, sender, body)
  values (v_interest, 'interesado', 'Ofrezco $' || to_char(p_amount, 'FM999G999G999') || '.');
  update public.interests set status = 'conversando' where id = v_interest and status = 'nuevo';

  return query
    select p_amount, s.top_offer_clp, s.offer_count
    from public.offer_summary s where s.product_id = v_product;
end $$;

-- El hilo devuelve además la oferta propia y la más alta.
drop function if exists public.thread_by_token(text);
create or replace function public.thread_by_token(p_token text)
returns table (interest_id uuid, product_id uuid, product_title text, price_clp integer,
               product_status public.product_status, interest_status public.interest_status,
               published_by text, buyer_name text,
               payment_method public.pay_method, payment_status public.payment_status,
               payment_reference text,
               my_offer_clp integer, top_offer_clp integer, offer_count bigint)
language sql security definer set search_path = public stable as $$
  select i.id, p.id, p.title, p.price_clp, p.status, i.status, m.name, i.buyer_name,
         y.method, y.status, y.reference,
         o.amount_clp, s.top_offer_clp, coalesce(s.offer_count, 0)
  from public.interests i
  join public.products p on p.id = i.product_id
  join public.members  m on m.id = p.created_by
  left join public.payments y on y.interest_id = i.id
  left join public.offers   o on o.interest_id = i.id
  left join public.offer_summary s on s.product_id = p.id
  where i.token = p_token;
$$;

grant execute on function
  public.create_interest(uuid, text, text, text, integer),
  public.place_offer_by_token(text, integer),
  public.thread_by_token(text)
  to anon, authenticated;

do $$ begin
  execute 'alter publication supabase_realtime add table public.offers';
exception when duplicate_object then null; end $$;
