-- =============================================================================
-- Pago directo por alias
-- =============================================================================
-- Laburapp no toca la plata: el cliente le transfiere directo al trabajador.
-- El trabajador carga su alias o CVU/CBU (obligatorio para pasar precio), el
-- cliente lo ve cuando lo elige, avisa "Ya pagué" y el trabajador confirma
-- "Recibí el pago". Por ahora sin comisión.

-- 1. Datos para cobrar ----------------------------------------------------------

alter table public.datos_privados
  add column alias_pago text check (alias_pago ~ '^([a-z0-9.-]{6,20}|[0-9]{22})$'),
  add column titular_pago text check (char_length(trim(titular_pago)) between 3 and 80),
  add constraint datos_privados_pago_completo check ((alias_pago is null) = (titular_pago is null));

comment on column public.datos_privados.alias_pago is 'Alias (6 a 20 letras, números, puntos o guiones, en minúscula) o CVU/CBU de 22 dígitos.';
comment on column public.datos_privados.titular_pago is 'A nombre de quién está la cuenta, para que el cliente lo verifique al transferir.';

grant update (alias_pago, titular_pago) on public.datos_privados to authenticated;

-- Un trabajador que ya cargó su alias no puede borrarlo (sí cambiarlo).
create function privado.no_borrar_alias()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.alias_pago is not null and new.alias_pago is null then
    raise exception 'El alias para cobrar es obligatorio. Podés cambiarlo, pero no borrarlo.' using errcode = 'P0001';
  end if;
  return new;
end;
$$;

create trigger no_borrar_alias
  before update of alias_pago on public.datos_privados
  for each row execute function privado.no_borrar_alias();

-- Registro: el trabajador manda el alias junto con el resto de sus datos.
create or replace function public.crear_perfil_nuevo_usuario()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  datos jsonb := new.raw_user_meta_data;
begin
  insert into public.perfiles (id, rol, nombre, apellido, oficios, oficio_otro, zonas, es_comercio)
  values (
    new.id,
    datos ->> 'rol',
    trim(datos ->> 'nombre'),
    trim(datos ->> 'apellido'),
    coalesce(array(select jsonb_array_elements_text(datos -> 'oficios')), '{}'),
    nullif(trim(datos ->> 'oficio_otro'), ''),
    coalesce(array(select jsonb_array_elements_text(datos -> 'zonas')), '{}'),
    coalesce((datos ->> 'es_comercio')::boolean, false)
  );

  -- El trabajador cobra por alias: sin alias no se completa el registro.
  if datos ->> 'rol' = 'trabajador' and coalesce(trim(datos ->> 'alias_pago'), '') = '' then
    raise exception 'Falta el alias o CVU para cobrar.' using errcode = 'P0001';
  end if;

  insert into public.datos_privados (id, whatsapp, sexo, alias_pago, titular_pago)
  values (
    new.id,
    datos ->> 'whatsapp',
    datos ->> 'sexo',
    nullif(lower(trim(datos ->> 'alias_pago')), ''),
    nullif(trim(datos ->> 'titular_pago'), '')
  );

  return new;
end;
$$;

-- Sin alias no se pasa precio (los trabajadores anteriores lo cargan antes).
create function privado.exigir_alias()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- Solo para trabajadores: a los demás ya los frenan las reglas de postulaciones.
  if exists (select 1 from public.perfiles where id = new.trabajador_id and rol = 'trabajador')
     and not exists (select 1 from public.datos_privados where id = new.trabajador_id and alias_pago is not null) then
    raise exception 'Cargá tu alias o CVU para cobrar antes de pasar precio.' using errcode = 'P0001';
  end if;
  return new;
end;
$$;

create trigger exigir_alias
  before insert on public.postulaciones
  for each row execute function privado.exigir_alias();

-- 2. Contacto: el cliente también ve los datos para pagar ---------------------

drop function public.contacto_del_trabajo(uuid);

create function public.contacto_del_trabajo(p_trabajo_id uuid)
returns table (nombre text, apellido text, whatsapp text, alias_pago text, titular_pago text)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_trabajo public.trabajos;
  v_yo uuid := (select auth.uid());
  v_otro uuid;
begin
  select * into v_trabajo from public.trabajos where id = p_trabajo_id;
  if not found or v_trabajo.estado not in ('asignado', 'por_confirmar', 'terminado') then
    raise exception 'El contacto se ve cuando el cliente elige a un trabajador.' using errcode = '42501';
  end if;

  if v_yo = v_trabajo.cliente_id then
    v_otro := v_trabajo.trabajador_elegido_id;
  elsif v_yo = v_trabajo.trabajador_elegido_id then
    v_otro := v_trabajo.cliente_id;
  else
    raise exception 'No participás de este trabajo.' using errcode = '42501';
  end if;

  -- Los datos para pagar solo van del trabajador al cliente.
  return query
  select p.nombre, p.apellido, d.whatsapp,
         case when v_yo = v_trabajo.cliente_id then d.alias_pago end,
         case when v_yo = v_trabajo.cliente_id then d.titular_pago end
  from public.perfiles p
  join public.datos_privados d on d.id = p.id
  where p.id = v_otro;
end;
$$;

revoke execute on function public.contacto_del_trabajo(uuid) from public, anon;
grant execute on function public.contacto_del_trabajo(uuid) to authenticated;

-- 3. Estado del pago en el trabajo --------------------------------------------

alter table public.trabajos
  add column pago_estado text not null default 'sin_pagar'
    check (pago_estado in ('sin_pagar', 'informado', 'recibido')),
  add column pago_monto integer check (pago_monto > 0 and pago_monto <= 100000000),
  add column pago_informado_at timestamptz,
  add column pago_recibido_at timestamptz;

comment on column public.trabajos.pago_estado is 'sin_pagar → informado (el cliente dice que pagó) → recibido (el trabajador lo confirma). Solo cambia con funciones.';

-- El cliente avisa que pagó (con el monto, si quiere). Se puede corregir
-- mientras el trabajador no lo confirmó.
create function public.informar_pago(p_trabajo_id uuid, p_monto integer default null)
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

  update public.trabajos
  set pago_estado = 'informado', pago_monto = p_monto, pago_informado_at = now()
  where id = p_trabajo_id;

  perform public.notificar(
    v_trabajo.trabajador_elegido_id, 'pago_informado',
    coalesce((select nombre from public.perfiles where id = v_trabajo.cliente_id), 'El cliente') || ' dice que te pagó',
    coalesce(public.pesos(p_monto) || ' · ', '') || 'Fijate en tu cuenta y confirmá que lo recibiste.',
    p_trabajo_id
  );
end;
$$;

-- El trabajador confirma que le llegó (o avisa que no le llegó).
create function public.responder_pago(p_trabajo_id uuid, p_recibido boolean)
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
    set pago_estado = 'sin_pagar', pago_monto = null, pago_informado_at = null
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

revoke execute on function public.informar_pago(uuid, integer), public.responder_pago(uuid, boolean) from public, anon;
grant execute on function public.informar_pago(uuid, integer), public.responder_pago(uuid, boolean) to authenticated;

revoke execute on function privado.no_borrar_alias(), privado.exigir_alias() from public, anon;
grant execute on function privado.no_borrar_alias(), privado.exigir_alias() to authenticated;
