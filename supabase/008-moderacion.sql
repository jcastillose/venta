-- 008 · Moderación del equipo: borrar mensajes y descartar interesados.
-- Idempotente. Incorporado también en 000-base-completa.sql.

-- Cualquier cuenta activa (admin o editor) borra mensajes de un hilo.
drop policy if exists "mensajes: equipo borra" on public.messages;
create policy "mensajes: equipo borra" on public.messages for delete using (public.is_member());

-- Descartar: el hilo queda cerrado para la persona (no puede escribir ni ofertar ni pagar),
-- su oferta se retira del ranking público y, si estaba reservado, el producto vuelve a disponible.
create or replace function public.discard_interest(p_interest uuid, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_product uuid; v_status public.interest_status;
begin
  if not public.is_member() then raise exception 'sin permiso'; end if;
  select product_id, status into v_product, v_status from public.interests where id = p_interest;
  if v_product is null then raise exception 'interés inexistente'; end if;
  if v_status = 'vendido' then raise exception 'Este trato ya se cerró como vendido'; end if;

  update public.interests set status = 'descartado' where id = p_interest;
  delete from public.offers where interest_id = p_interest;
  update public.payments set status = 'anulado' where interest_id = p_interest and status <> 'pagado';
  if v_status = 'reservado' then
    update public.products set status = 'disponible' where id = v_product and status = 'reservado';
  end if;
  insert into public.messages (interest_id, sender, body)
  values (p_interest, 'vendedor', coalesce(nullif(trim(p_reason), ''), 'Esta conversación fue cerrada por el equipo de venta.'));
end $$;

-- Reabrir por si se descartó por error.
create or replace function public.reopen_interest(p_interest uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_member() then raise exception 'sin permiso'; end if;
  update public.interests set status = 'conversando' where id = p_interest and status = 'descartado';
end $$;

grant execute on function public.discard_interest(uuid, text), public.reopen_interest(uuid) to authenticated;

-- El interesado descartado no puede escribir ni ofertar.
create or replace function public.send_message_by_token(p_token text, p_body text)
returns public.messages
language plpgsql security definer set search_path = public as $$
declare v_interest uuid; v_status public.interest_status; v_msg public.messages;
begin
  select id, status into v_interest, v_status from public.interests where token = p_token;
  if v_interest is null then raise exception 'token inválido'; end if;
  if v_status = 'descartado' then raise exception 'Esta conversación fue cerrada por el equipo de venta'; end if;
  insert into public.messages (interest_id, sender, body) values (v_interest, 'interesado', p_body) returning * into v_msg;
  update public.interests set status = 'conversando' where id = v_interest and status = 'nuevo';
  return v_msg;
end $$;
