-- =============================================================================
-- Comprobante de pago
-- =============================================================================
-- Al avisar "Ya pagué", el cliente puede adjuntar la captura de la
-- transferencia. Bucket privado: lo ven solo el cliente que la subió y el
-- trabajador elegido de ese trabajo (con links firmados).

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('comprobantes', 'comprobantes', false, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

alter table public.trabajos add column pago_comprobante text;
comment on column public.trabajos.pago_comprobante is 'Ruta en el bucket comprobantes ({cliente_id}/archivo). Solo cambia con informar_pago().';

create policy "Subir comprobantes a la carpeta propia"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'comprobantes' and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy "Borrar comprobantes de la carpeta propia"
  on storage.objects for delete to authenticated
  using (bucket_id = 'comprobantes' and (storage.foldername(name))[1] = (select auth.uid())::text);

-- El cliente ve los suyos; el trabajador, el del trabajo en el que lo eligieron.
create policy "Ver comprobantes propios o de mis trabajos"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'comprobantes'
    and (
      (storage.foldername(name))[1] = (select auth.uid())::text
      or exists (
        select 1 from public.trabajos t
        where t.pago_comprobante = storage.objects.name
          and t.trabajador_elegido_id = (select auth.uid())
      )
    )
  );

-- informar_pago suma el comprobante (opcional). Al corregir el monto sin
-- adjuntar otro, queda el anterior.
drop function public.informar_pago(uuid, integer);

create function public.informar_pago(p_trabajo_id uuid, p_monto integer default null, p_comprobante text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_trabajo public.trabajos;
begin
  select * into v_trabajo from public.trabajos where id = p_trabajo_id for update;
  if not found or v_trabajo.cliente_id is distinct from (select auth.uid()) then
    raise exception 'Solo el cliente del trabajo puede avisar que pagó.' using errcode = '42501';
  end if;
  if v_trabajo.estado not in ('asignado', 'por_confirmar', 'terminado') then
    raise exception 'Primero elegí a un trabajador.' using errcode = 'P0001';
  end if;
  if v_trabajo.pago_estado = 'recibido' then
    raise exception 'El trabajador ya confirmó que recibió el pago.' using errcode = 'P0001';
  end if;
  if p_comprobante is not null and split_part(p_comprobante, '/', 1) <> v_trabajo.cliente_id::text then
    raise exception 'El comprobante tiene que ser tuyo.' using errcode = '42501';
  end if;

  update public.trabajos
  set pago_estado = 'informado',
      pago_monto = p_monto,
      pago_comprobante = coalesce(p_comprobante, pago_comprobante),
      pago_informado_at = now()
  where id = p_trabajo_id;

  perform public.notificar(
    v_trabajo.trabajador_elegido_id, 'pago_informado',
    coalesce((select nombre from public.perfiles where id = v_trabajo.cliente_id), 'El cliente') || ' dice que te pagó',
    coalesce(public.pesos(p_monto) || ' · ', '')
      || case when coalesce(p_comprobante, v_trabajo.pago_comprobante) is not null then 'Mandó el comprobante. ' else '' end
      || 'Fijate en tu cuenta y confirmá que lo recibiste.',
    p_trabajo_id
  );
end;
$$;

revoke execute on function public.informar_pago(uuid, integer, text) from public, anon;
grant execute on function public.informar_pago(uuid, integer, text) to authenticated;

-- Si el pago no llegó, el comprobante deja de valer.
create or replace function public.responder_pago(p_trabajo_id uuid, p_recibido boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_trabajo public.trabajos;
  v_nombre text;
begin
  select * into v_trabajo from public.trabajos where id = p_trabajo_id for update;
  if not found or v_trabajo.trabajador_elegido_id is distinct from (select auth.uid()) then
    raise exception 'Solo el trabajador elegido puede confirmar el pago.' using errcode = '42501';
  end if;
  if v_trabajo.pago_estado <> 'informado' then
    raise exception 'El cliente todavía no avisó que pagó.' using errcode = 'P0001';
  end if;

  v_nombre := coalesce((select nombre from public.perfiles where id = v_trabajo.trabajador_elegido_id), 'El trabajador');
  if p_recibido then
    update public.trabajos set pago_estado = 'recibido', pago_recibido_at = now() where id = p_trabajo_id;
    perform public.notificar(v_trabajo.cliente_id, 'pago_recibido', v_nombre || ' confirmó que recibió tu pago', 'Quedó registrado en el trabajo.', p_trabajo_id);
  else
    update public.trabajos
    set pago_estado = 'sin_pagar', pago_monto = null, pago_informado_at = null, pago_comprobante = null
    where id = p_trabajo_id;
    perform public.notificar(
      v_trabajo.cliente_id, 'pago_no_llego',
      v_nombre || ' dice que todavía no le llegó el pago',
      'Revisá la transferencia y el alias. Si ya está hecha, hablalo por el chat.',
      p_trabajo_id
    );
  end if;
end;
$$;
