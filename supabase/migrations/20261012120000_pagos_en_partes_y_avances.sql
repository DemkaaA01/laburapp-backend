-- =============================================================================
-- Pagos en partes y avances del trabajo
-- =============================================================================
-- Para trabajos largos o que se pagan por partes:
--   * pagos: cada pago es un registro (monto, nota, comprobante) que el
--     trabajador confirma. Reemplaza a las columnas pago_* de trabajos.
--   * avances: el cliente y el trabajador cuentan cómo va (texto y fotos); el
--     trabajador puede marcar un porcentaje.
-- Solo los ven el cliente y el trabajador elegido.

-- ¿Soy el cliente o el trabajador elegido de este trabajo?
create function privado.participo_del_trabajo(p_trabajo uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.trabajos
    where id = p_trabajo
      and trabajador_elegido_id is not null
      and (select auth.uid()) in (cliente_id, trabajador_elegido_id)
  )
$$;

-- 1. Pagos ---------------------------------------------------------------------

create table public.pagos (
  id uuid primary key default gen_random_uuid(),
  trabajo_id uuid not null references public.trabajos (id) on delete cascade,
  monto integer not null check (monto > 0 and monto <= 100000000),
  nota text check (char_length(trim(nota)) between 1 and 80),
  comprobante text check (char_length(comprobante) <= 300),
  estado text not null default 'informado' check (estado in ('informado', 'recibido', 'no_llego')),
  created_at timestamptz not null default clock_timestamp(),
  respondido_at timestamptz
);

comment on table public.pagos is 'Pagos del cliente al trabajador (por alias). Se crean con informar_pago() y se confirman con responder_pago().';
create index pagos_trabajo on public.pagos (trabajo_id, created_at);

alter table public.pagos enable row level security;
create policy "Ven los pagos el cliente y el trabajador elegido"
  on public.pagos for select to authenticated
  using (privado.participo_del_trabajo(trabajo_id));
revoke all on public.pagos from anon;
revoke insert, update, delete on public.pagos from authenticated;

-- Lo que ya se había informado con el sistema anterior pasa a la tabla nueva.
insert into public.pagos (trabajo_id, monto, comprobante, estado, created_at, respondido_at)
select id, coalesce(pago_monto, precio_acordado), pago_comprobante,
       case when pago_estado = 'recibido' then 'recibido' else 'informado' end,
       coalesce(pago_informado_at, now()), pago_recibido_at
from public.trabajos
where pago_estado <> 'sin_pagar' and coalesce(pago_monto, precio_acordado) is not null;

-- Comprobantes: ahora se buscan en pagos.
drop policy "Ver comprobantes propios o de mis trabajos" on storage.objects;
create policy "Ver comprobantes propios o de mis trabajos"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'comprobantes'
    and (
      (storage.foldername(name))[1] = (select auth.uid())::text
      or exists (select 1 from public.pagos p where p.comprobante = storage.objects.name)
    )
  );

drop function public.informar_pago(uuid, integer, text);
drop function public.responder_pago(uuid, boolean);
alter table public.trabajos
  drop column pago_estado,
  drop column pago_monto,
  drop column pago_informado_at,
  drop column pago_recibido_at,
  drop column pago_comprobante;

-- El cliente registra un pago (puede haber varios: seña, materiales, saldo…).
create function public.informar_pago(
  p_trabajo_id uuid,
  p_monto integer,
  p_nota text default null,
  p_comprobante text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_trabajo public.trabajos;
  v_id uuid;
begin
  select * into v_trabajo from public.trabajos where id = p_trabajo_id;
  if not found or v_trabajo.cliente_id is distinct from (select auth.uid()) then
    raise exception 'Solo el cliente del trabajo puede avisar que pagó.' using errcode = '42501';
  end if;
  if v_trabajo.estado not in ('asignado', 'por_confirmar', 'terminado') then
    raise exception 'Primero elegí a un trabajador.' using errcode = 'P0001';
  end if;
  if p_comprobante is not null and split_part(p_comprobante, '/', 1) <> v_trabajo.cliente_id::text then
    raise exception 'El comprobante tiene que ser tuyo.' using errcode = '42501';
  end if;
  perform privado.limitar(
    (select count(*) from public.pagos where trabajo_id = p_trabajo_id and created_at > now() - interval '1 day'),
    20, 'Ya registraste muchos pagos hoy en este trabajo.'
  );

  insert into public.pagos (trabajo_id, monto, nota, comprobante)
  values (p_trabajo_id, p_monto, nullif(trim(p_nota), ''), p_comprobante)
  returning id into v_id;

  perform public.notificar(
    v_trabajo.trabajador_elegido_id, 'pago_informado',
    coalesce((select nombre from public.perfiles where id = v_trabajo.cliente_id), 'El cliente')
      || ' dice que te pagó ' || public.pesos(p_monto),
    coalesce(nullif(trim(p_nota), '') || ' · ', '')
      || case when p_comprobante is not null then 'Mandó el comprobante. ' else '' end
      || 'Fijate en tu cuenta y confirmá que lo recibiste.',
    p_trabajo_id
  );
  return v_id;
end;
$$;

-- El trabajador confirma un pago, o avisa que no le llegó.
create function public.responder_pago(p_pago_id uuid, p_recibido boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pago public.pagos;
  v_trabajo public.trabajos;
  v_nombre text;
begin
  select * into v_pago from public.pagos where id = p_pago_id for update;
  select * into v_trabajo from public.trabajos where id = v_pago.trabajo_id;
  if v_pago.id is null or v_trabajo.trabajador_elegido_id is distinct from (select auth.uid()) then
    raise exception 'Solo el trabajador elegido puede confirmar el pago.' using errcode = '42501';
  end if;
  if v_pago.estado <> 'informado' then
    raise exception 'Ese pago ya fue respondido.' using errcode = 'P0001';
  end if;

  update public.pagos
  set estado = case when p_recibido then 'recibido' else 'no_llego' end, respondido_at = now()
  where id = p_pago_id;

  v_nombre := coalesce((select nombre from public.perfiles where id = v_trabajo.trabajador_elegido_id), 'El trabajador');
  if p_recibido then
    perform public.notificar(
      v_trabajo.cliente_id, 'pago_recibido',
      v_nombre || ' confirmó que recibió ' || public.pesos(v_pago.monto),
      'Quedó registrado en el trabajo.', v_trabajo.id
    );
  else
    perform public.notificar(
      v_trabajo.cliente_id, 'pago_no_llego',
      v_nombre || ' dice que no le llegó el pago de ' || public.pesos(v_pago.monto),
      'Revisá la transferencia y el alias. Si ya está hecha, hablalo por el chat.', v_trabajo.id
    );
  end if;
end;
$$;

revoke execute on function public.informar_pago(uuid, integer, text, text), public.responder_pago(uuid, boolean)
  from public, anon;
grant execute on function public.informar_pago(uuid, integer, text, text), public.responder_pago(uuid, boolean)
  to authenticated;

-- 2. Avances -------------------------------------------------------------------

create table public.avances (
  id uuid primary key default gen_random_uuid(),
  trabajo_id uuid not null references public.trabajos (id) on delete cascade,
  autor_id uuid not null default auth.uid() references public.perfiles (id) on delete cascade,
  texto text not null check (char_length(trim(texto)) between 1 and 1000),
  fotos text[] not null default '{}',
  -- Solo el trabajador: cuánto le parece que lleva hecho.
  porcentaje integer check (porcentaje between 0 and 100),
  created_at timestamptz not null default clock_timestamp(),
  constraint avances_fotos check (public.fotos_validas(autor_id, fotos))
);

comment on table public.avances is 'Cómo va un trabajo largo, contado por el cliente y el trabajador elegido.';
create index avances_trabajo on public.avances (trabajo_id, created_at);

alter table public.avances enable row level security;

create policy "Ven los avances el cliente y el trabajador elegido"
  on public.avances for select to authenticated
  using (privado.participo_del_trabajo(trabajo_id));

-- Se cargan mientras el trabajo está en curso. El porcentaje, solo el trabajador.
create policy "Cargan avances el cliente y el trabajador elegido"
  on public.avances for insert to authenticated
  with check (
    autor_id = (select auth.uid())
    and privado.participo_del_trabajo(trabajo_id)
    and exists (select 1 from public.trabajos t where t.id = trabajo_id and t.estado in ('asignado', 'por_confirmar'))
    and (
      porcentaje is null
      or exists (select 1 from public.trabajos t where t.id = trabajo_id and t.trabajador_elegido_id = (select auth.uid()))
    )
  );

-- Cada uno borra los suyos (por si se equivocó).
create policy "Cada uno borra sus avances"
  on public.avances for delete to authenticated
  using (autor_id = (select auth.uid()));

revoke all on public.avances from anon;
revoke insert, update, delete on public.avances from authenticated;
grant insert (trabajo_id, texto, fotos, porcentaje) on public.avances to authenticated;
grant delete on public.avances to authenticated;

-- Aviso al otro.
create function privado.avisar_avance()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_trabajo public.trabajos;
begin
  select * into v_trabajo from public.trabajos where id = new.trabajo_id;
  perform public.notificar(
    case when new.autor_id = v_trabajo.cliente_id then v_trabajo.trabajador_elegido_id else v_trabajo.cliente_id end,
    'avance',
    coalesce((select nombre from public.perfiles where id = new.autor_id), 'Alguien') || ' contó cómo va el trabajo'
      || coalesce(' (' || new.porcentaje || ' %)', ''),
    public.resumen(new.texto),
    new.trabajo_id
  );
  return new;
end;
$$;

create trigger avisar_avance
  after insert on public.avances
  for each row execute function privado.avisar_avance();

-- Anti-spam: hasta 30 avances por día por persona.
create function privado.limite_avances()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  perform privado.limitar(
    (select count(*) from public.avances where autor_id = new.autor_id and created_at > now() - interval '1 day'),
    30, 'Cargaste muchos avances hoy. Probá de nuevo mañana.'
  );
  return new;
end;
$$;

create trigger limite_avances
  before insert on public.avances
  for each row execute function privado.limite_avances();

-- Fotos de avances: van al bucket de pedidos, en la carpeta de quien las sube.
-- Las ve también el otro participante.
drop policy "Ver fotos de trabajos que puedo ver" on storage.objects;
create policy "Ver fotos de trabajos que puedo ver"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'fotos-trabajos'
    and (
      (storage.foldername(name))[1] = (select auth.uid())::text
      or exists (select 1 from public.trabajos t where storage.objects.name = any (t.fotos))
      or exists (select 1 from public.avances a where storage.objects.name = any (a.fotos))
    )
  );

revoke execute on all functions in schema privado from public, anon;
grant execute on all functions in schema privado to authenticated;
