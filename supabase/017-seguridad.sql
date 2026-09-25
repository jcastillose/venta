-- 017-seguridad.sql — Correcciones de la revisión de seguridad (2026-09-25). Re-ejecutable.
-- Se aplica sobre 000-base-completa.sql + 014-aviso-respuesta.sql.
-- Además, en el dashboard (no es SQL): Authentication → Providers → Email → desactivar "Allow new users to sign up",
-- y Authentication → Attack protection → activar "Leaked password protection".

-- ---------------------------------------------------------------------------
-- C1. Alta automática de miembros: solo si app_metadata lo indica.
--     user_metadata lo controla el cliente en signUp; app_metadata solo service_role.
--     cuentas.js y bootstrap-admin.sql insertan en members por su cuenta, así que el trigger queda como red de seguridad.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if coalesce((new.raw_app_meta_data->>'equipo')::boolean, false) then
    insert into public.members (id, name, email, role, status)
    values (new.id,
            coalesce(new.raw_user_meta_data->>'name', split_part(new.email, '@', 1)),
            new.email,
            coalesce((new.raw_app_meta_data->>'role')::public.member_role, 'editor'),
            coalesce((new.raw_app_meta_data->>'status')::public.member_status, 'invitado'))
    on conflict (id) do nothing;
  end if;
  return new;
end $$;
revoke execute on function public.handle_new_user() from public, anon, authenticated;
do $$ begin
  revoke execute on function public.aviso_webhook() from public, anon, authenticated;
exception when undefined_function then null; end $$;

-- ---------------------------------------------------------------------------
-- C2. members: el propio miembro (activo) solo puede cambiar name y last_seen.
--     Antes cualquier cuenta, incluso suspendida, podía ponerse role='admin' y status='activo'.
revoke update on public.members from anon, authenticated;
grant update (name, last_seen) on public.members to authenticated;
drop policy if exists "equipo: edita su perfil" on public.members;
create policy "equipo: edita su perfil" on public.members
  for update using (auth.uid() = id and public.is_member()) with check (auth.uid() = id);

-- ---------------------------------------------------------------------------
-- A1. No se puede volver a declarar un pago ya confirmado (antes lo devolvía a 'porconfirmar'
--     y con ello habilitaba borrar el hilo, el interés o el producto).
create or replace function public.declare_payment_by_token(p_token text, p_method public.pay_method, p_reference text default null)
returns public.payments language plpgsql security definer set search_path = public as $$
declare v_interest uuid; v_amount integer; v_pay public.payments;
begin
  select i.id, p.price_clp into v_interest, v_amount
  from public.interests i join public.products p on p.id = i.product_id
  where i.token = p_token;
  if v_interest is null then raise exception 'token inválido'; end if;
  if exists (select 1 from public.interests where id = v_interest and status = 'descartado') then
    raise exception 'Esta conversación fue cerrada por el equipo de venta'; end if;
  if exists (select 1 from public.payments where interest_id = v_interest and status = 'pagado') then
    raise exception 'Este pago ya fue confirmado por el equipo; escribe en el hilo si necesitas cambiar algo'; end if;
  if not exists (select 1 from public.payment_settings where method = p_method and enabled) then
    raise exception 'medio de pago no disponible';
  end if;

  insert into public.payments (interest_id, method, amount_clp, reference, status)
  values (v_interest, p_method, v_amount, nullif(p_reference, ''), 'porconfirmar')
  on conflict (interest_id) do update
    set method = excluded.method, reference = excluded.reference,
        status = 'porconfirmar', declared_at = now(), confirmed_at = null, confirmed_by = null
  returning * into v_pay;

  insert into public.messages (interest_id, sender, body)
  values (v_interest, 'interesado',
          'Pagué $' || to_char(v_amount, 'FM999G999G999') || ' por ' || p_method::text ||
          coalesce('. Referencia: ' || nullif(p_reference, ''), '') || '.');
  return v_pay;
end $$;

-- ---------------------------------------------------------------------------
-- A3. products: sin delete directo desde el cliente; el borrado pasa solo por delete_product(),
--     que protege los tratos con pago confirmado.
drop policy if exists "productos: equipo escribe" on public.products;
drop policy if exists "productos: equipo crea" on public.products;
drop policy if exists "productos: equipo edita" on public.products;
create policy "productos: equipo crea" on public.products
  for insert with check (public.is_member());
create policy "productos: equipo edita" on public.products
  for update using (public.is_member()) with check (public.is_member());

-- ---------------------------------------------------------------------------
-- A4. Un solo aviso por cambio de estado de cuenta. El trigger "resend" (creado desde la interfaz,
--     fuera del repo) duplicaba cada aviso y llevaba el secreto en su definición.
drop trigger if exists resend on public.members;
drop trigger if exists "aviso-cuenta" on public.members;
do $$ begin
  create trigger "aviso-cuenta" after update on public.members for each row
    when (old.status is distinct from new.status) execute function public.aviso_webhook();
exception when undefined_function then null; end $$;

-- ---------------------------------------------------------------------------
-- M1. payment_options solo expone el medio; RUT y cuenta viajan únicamente por payment_options_by_token (con token).
drop view if exists public.payment_options;
create view public.payment_options as
  select method from public.payment_settings where enabled;
grant select on public.payment_options to anon, authenticated;

-- M2. offer_summary: la leen catalog y las RPC como owner; el ajuste ofertas_publicas vuelve a mandar.
revoke all on public.offer_summary from anon, authenticated;

-- ---------------------------------------------------------------------------
-- B. Entradas defensivas en RPC del equipo y del interesado.
create or replace function public.close_deal(p_interest uuid, p_status public.product_status)
returns void language plpgsql security definer set search_path = public as $$
declare v_product uuid;
begin
  if not public.is_member() then raise exception 'no autorizado'; end if;
  if p_status not in ('reservado', 'vendido') then raise exception 'estado no permitido: %', p_status; end if;
  select i.product_id into v_product from public.interests i where i.id = p_interest;
  if v_product is null then raise exception 'interés inexistente'; end if;
  update public.products  set status = p_status, updated_at = now(), updated_by = auth.uid() where id = v_product;
  update public.interests set status = p_status::text::public.interest_status where id = p_interest;
end $$;

create or replace function public.confirm_payment(p_interest uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_member() then raise exception 'no autorizado'; end if;
  update public.payments set status = 'pagado', confirmed_at = now(), confirmed_by = auth.uid()
   where interest_id = p_interest;
  if not found then raise exception 'No hay pago avisado para este interés'; end if;
  insert into public.messages (interest_id, sender, body)
  values (p_interest, 'vendedor', 'Pago confirmado, ¡gracias! Coordinemos la entrega por aquí.');
  perform public.close_deal(p_interest, 'vendido');
end $$;

create or replace function public.send_message_by_token(p_token text, p_body text)
returns public.messages language plpgsql security definer set search_path = public as $$
declare v_interest uuid; v_status public.interest_status; v_msg public.messages;
begin
  if coalesce(trim(p_body), '') = '' then raise exception 'Mensaje vacío'; end if;
  select id, status into v_interest, v_status from public.interests where token = p_token;
  if v_interest is null then raise exception 'token inválido'; end if;
  if v_status = 'descartado' then raise exception 'Esta conversación fue cerrada por el equipo de venta'; end if;
  insert into public.messages (interest_id, sender, body) values (v_interest, 'interesado', trim(p_body)) returning * into v_msg;
  update public.interests set status = 'conversando' where id = v_interest and status = 'nuevo';
  return v_msg;
end $$;

-- ---------------------------------------------------------------------------
-- Advisors: las RPC del equipo no deben ser ejecutables por anónimos (ya validan is_member/is_admin por dentro).
revoke execute on function
  public.close_deal(uuid, public.product_status),
  public.confirm_payment(uuid),
  public.delete_category(text),
  public.delete_interest(uuid),
  public.delete_product(uuid),
  public.discard_interest(uuid, text),
  public.reopen_interest(uuid),
  public.set_offers_for_all(boolean),
  public.visits_summary(timestamptz, timestamptz, boolean),
  public.activar_invitacion()
from public, anon;

-- ---------------------------------------------------------------------------
-- Informe
select 'members update cols' as chequeo,
       string_agg(column_name, ',' order by column_name) as valor
from information_schema.column_privileges
where table_schema = 'public' and table_name = 'members' and grantee = 'authenticated' and privilege_type = 'UPDATE'
union all
select 'products policies', string_agg(policyname || ':' || cmd, ' | ' order by policyname) from pg_policies where tablename = 'products'
union all
select 'members triggers', string_agg(tgname, ',') from pg_trigger t join pg_class c on c.oid = t.tgrelid where c.relname = 'members' and not t.tgisinternal
union all
select 'payment_options cols', string_agg(column_name, ',') from information_schema.columns where table_name = 'payment_options'
union all
select 'offer_summary anon', coalesce(string_agg(privilege_type, ','), 'sin acceso') from information_schema.role_table_grants where table_name = 'offer_summary' and grantee = 'anon'
union all
select 'close_deal anon exec', coalesce(string_agg(privilege_type, ','), 'sin acceso') from information_schema.role_routine_grants where routine_name = 'close_deal' and grantee = 'anon';
