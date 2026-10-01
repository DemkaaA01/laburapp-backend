-- =============================================================================
-- Trabajos y postulaciones
-- =============================================================================
-- Flujo: el cliente publica un trabajo (abierto) → los trabajadores de ese
-- oficio y esa zona se postulan con su precio → el cliente elige una
-- postulación (asignado) y ven el WhatsApp del otro → el trabajador lo marca
-- como terminado (por_confirmar) → el cliente lo confirma (terminado) o lo
-- rechaza (vuelve a asignado) → se califican. El cliente puede cancelarlo
-- mientras esté abierto o asignado.
--
-- Los cambios de estado se hacen solo con funciones (elegir_postulacion,
-- marcar_terminado, confirmar_terminado, rechazar_terminado, cancelar_trabajo),
-- que validan todo del lado del servidor.

-- Trabajos -------------------------------------------------------------------

-- Fotos: rutas en Storage (bucket fotos-trabajos), todas en la carpeta del cliente.
create function public.fotos_validas(p_cliente_id uuid, p_fotos text[])
returns boolean
language sql
immutable
set search_path = ''
as $$
  select cardinality(p_fotos) <= 5
    and coalesce(
      (select bool_and(f like p_cliente_id::text || '/%' and char_length(f) <= 300) from unnest(p_fotos) as f),
      true
    )
$$;

create table public.trabajos (
  id uuid primary key default gen_random_uuid(),
  cliente_id uuid not null default auth.uid() references public.perfiles (id) on delete cascade,
  oficio text not null check (oficio = any (public.oficios_validos())),
  descripcion text not null check (char_length(trim(descripcion)) between 10 and 1000),
  zona text not null check (zona = any (public.zonas_validas())),
  para_cuando text not null check (para_cuando in ('lo_antes_posible', 'esta_semana', 'este_mes', 'sin_apuro')),
  -- De 0 a 5 fotos (opcionales).
  fotos text[] not null default '{}',
  estado text not null default 'abierto'
    check (estado in ('abierto', 'asignado', 'por_confirmar', 'terminado', 'cancelado')),
  trabajador_elegido_id uuid references public.perfiles (id) on delete set null,
  precio_acordado integer check (precio_acordado > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  asignado_at timestamptz,
  -- Cuando el trabajador lo marcó como terminado (espera confirmación del cliente).
  marcado_terminado_at timestamptz,
  terminado_at timestamptz,
  cancelado_at timestamptz,

  constraint trabajos_abierto_sin_elegido check (estado <> 'abierto' or trabajador_elegido_id is null),
  constraint trabajos_fotos check (public.fotos_validas(cliente_id, fotos))
);

comment on table public.trabajos is 'Trabajos que publican los clientes.';

create index trabajos_abiertos on public.trabajos (oficio, zona, created_at desc) where estado = 'abierto';
create index trabajos_cliente on public.trabajos (cliente_id, created_at desc);
create index trabajos_elegido on public.trabajos (trabajador_elegido_id) where trabajador_elegido_id is not null;

create trigger trabajos_updated_at
  before update on public.trabajos
  for each row execute function public.tocar_updated_at();

-- Postulaciones --------------------------------------------------------------

create table public.postulaciones (
  id uuid primary key default gen_random_uuid(),
  trabajo_id uuid not null references public.trabajos (id) on delete cascade,
  trabajador_id uuid not null default auth.uid() references public.perfiles (id) on delete cascade,
  -- En pesos, sin centavos.
  precio integer not null check (precio between 1 and 100000000),
  mensaje text check (char_length(mensaje) <= 500),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint postulaciones_una_por_trabajo unique (trabajo_id, trabajador_id)
);

comment on table public.postulaciones is 'Precio que ofrece un trabajador para un trabajo.';

create index postulaciones_trabajador on public.postulaciones (trabajador_id, created_at desc);

create trigger postulaciones_updated_at
  before update on public.postulaciones
  for each row execute function public.tocar_updated_at();

-- Funciones auxiliares para las políticas ------------------------------------
-- Son security definer para que las políticas de trabajos y postulaciones no
-- se llamen entre sí en bucle.

create function public.soy_cliente_del_trabajo(p_trabajo_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.trabajos where id = p_trabajo_id and cliente_id = (select auth.uid())
  )
$$;

create function public.me_postule(p_trabajo_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.postulaciones where trabajo_id = p_trabajo_id and trabajador_id = (select auth.uid())
  )
$$;

create function public.trabajo_abierto(p_trabajo_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.trabajos where id = p_trabajo_id and estado = 'abierto')
$$;

-- ¿El oficio y la zona del trabajo coinciden con los del trabajador?
create function public.trabajo_coincide_con(p_oficio text, p_zona text, p_oficios text[], p_zonas text[])
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_oficio = any (p_oficios)
    and (p_zona = any (p_zonas) or ('Toda la ciudad' = any (p_zonas) and p_zona <> 'Alrededores'))
$$;

create function public.puedo_postularme(p_trabajo_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.trabajos t
    join public.perfiles p on p.id = (select auth.uid())
    where t.id = p_trabajo_id
      and t.estado = 'abierto'
      and p.rol = 'trabajador'
      and t.cliente_id <> p.id
      and public.trabajo_coincide_con(t.oficio, t.zona, p.oficios, p.zonas)
  )
$$;

revoke execute on function
  public.soy_cliente_del_trabajo(uuid),
  public.me_postule(uuid),
  public.trabajo_abierto(uuid),
  public.puedo_postularme(uuid)
from public, anon;
grant execute on function
  public.soy_cliente_del_trabajo(uuid),
  public.me_postule(uuid),
  public.trabajo_abierto(uuid),
  public.puedo_postularme(uuid)
to authenticated;

-- Seguridad: trabajos --------------------------------------------------------

alter table public.trabajos enable row level security;

-- El cliente ve los suyos; los trabajadores ven los abiertos, los que se
-- postularon y los que les asignaron.
create policy "Ver trabajos"
  on public.trabajos for select
  to authenticated
  using (
    cliente_id = (select auth.uid())
    or trabajador_elegido_id = (select auth.uid())
    or (estado = 'abierto' and (select public.mi_rol()) = 'trabajador')
    or public.me_postule(id)
  );

create policy "Los clientes publican trabajos"
  on public.trabajos for insert
  to authenticated
  with check (
    cliente_id = (select auth.uid())
    and (select public.mi_rol()) = 'cliente'
    and estado = 'abierto'
    and trabajador_elegido_id is null
  );

create policy "El cliente edita su trabajo mientras está abierto"
  on public.trabajos for update
  to authenticated
  using (cliente_id = (select auth.uid()) and estado = 'abierto')
  with check (cliente_id = (select auth.uid()) and estado = 'abierto');

revoke insert, update, delete on public.trabajos from anon, authenticated;
grant insert (oficio, descripcion, zona, para_cuando, fotos) on public.trabajos to authenticated;
grant update (descripcion, para_cuando, fotos) on public.trabajos to authenticated;

-- Seguridad: postulaciones ---------------------------------------------------

alter table public.postulaciones enable row level security;

create policy "Ver postulaciones propias o de mis trabajos"
  on public.postulaciones for select
  to authenticated
  using (trabajador_id = (select auth.uid()) or public.soy_cliente_del_trabajo(trabajo_id));

create policy "Los trabajadores se postulan"
  on public.postulaciones for insert
  to authenticated
  with check (trabajador_id = (select auth.uid()) and public.puedo_postularme(trabajo_id));

create policy "El trabajador cambia su postulación mientras el trabajo está abierto"
  on public.postulaciones for update
  to authenticated
  using (trabajador_id = (select auth.uid()) and public.trabajo_abierto(trabajo_id))
  with check (trabajador_id = (select auth.uid()) and public.trabajo_abierto(trabajo_id));

create policy "El trabajador retira su postulación mientras el trabajo está abierto"
  on public.postulaciones for delete
  to authenticated
  using (trabajador_id = (select auth.uid()) and public.trabajo_abierto(trabajo_id));

revoke insert, update, delete on public.postulaciones from anon, authenticated;
grant insert (trabajo_id, precio, mensaje) on public.postulaciones to authenticated;
grant update (precio, mensaje) on public.postulaciones to authenticated;
grant delete on public.postulaciones to authenticated;

-- Cambios de estado ----------------------------------------------------------

create function public.elegir_postulacion(p_postulacion_id uuid)
returns public.trabajos
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_postulacion public.postulaciones;
  v_trabajo public.trabajos;
begin
  select * into v_postulacion from public.postulaciones where id = p_postulacion_id;
  if not found then
    raise exception 'La postulación no existe.' using errcode = 'P0002';
  end if;

  -- Bloquea el trabajo para que no se elijan dos a la vez.
  select * into v_trabajo from public.trabajos where id = v_postulacion.trabajo_id for update;
  if v_trabajo.cliente_id is distinct from (select auth.uid()) then
    raise exception 'Solo quien publicó el trabajo puede elegir.' using errcode = '42501';
  end if;
  if v_trabajo.estado <> 'abierto' then
    raise exception 'Este trabajo ya no está abierto.' using errcode = 'P0001';
  end if;

  update public.trabajos
  set estado = 'asignado',
      trabajador_elegido_id = v_postulacion.trabajador_id,
      precio_acordado = v_postulacion.precio,
      asignado_at = now()
  where id = v_trabajo.id
  returning * into v_trabajo;

  return v_trabajo;
end;
$$;

-- El trabajador elegido avisa que terminó; queda esperando que el cliente confirme.
create function public.marcar_terminado(p_trabajo_id uuid)
returns public.trabajos
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_trabajo public.trabajos;
begin
  select * into v_trabajo from public.trabajos where id = p_trabajo_id for update;
  if not found or v_trabajo.trabajador_elegido_id is distinct from (select auth.uid()) then
    raise exception 'Solo el trabajador elegido puede marcar el trabajo como terminado.' using errcode = '42501';
  end if;
  if v_trabajo.estado <> 'asignado' then
    raise exception 'Solo se puede marcar como terminado un trabajo en curso.' using errcode = 'P0001';
  end if;

  update public.trabajos
  set estado = 'por_confirmar', marcado_terminado_at = now()
  where id = p_trabajo_id
  returning * into v_trabajo;

  return v_trabajo;
end;
$$;

-- El cliente confirma que el trabajo está terminado (habilita las calificaciones).
create function public.confirmar_terminado(p_trabajo_id uuid)
returns public.trabajos
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_trabajo public.trabajos;
begin
  select * into v_trabajo from public.trabajos where id = p_trabajo_id for update;
  if not found or v_trabajo.cliente_id is distinct from (select auth.uid()) then
    raise exception 'Solo quien publicó el trabajo puede confirmar que está terminado.' using errcode = '42501';
  end if;
  if v_trabajo.estado <> 'por_confirmar' then
    raise exception 'El trabajador todavía no marcó el trabajo como terminado.' using errcode = 'P0001';
  end if;

  update public.trabajos
  set estado = 'terminado', terminado_at = now()
  where id = p_trabajo_id
  returning * into v_trabajo;

  return v_trabajo;
end;
$$;

-- El cliente dice que todavía no está terminado: vuelve a estar en curso.
create function public.rechazar_terminado(p_trabajo_id uuid)
returns public.trabajos
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_trabajo public.trabajos;
begin
  select * into v_trabajo from public.trabajos where id = p_trabajo_id for update;
  if not found or v_trabajo.cliente_id is distinct from (select auth.uid()) then
    raise exception 'Solo quien publicó el trabajo puede responder.' using errcode = '42501';
  end if;
  if v_trabajo.estado <> 'por_confirmar' then
    raise exception 'El trabajador todavía no marcó el trabajo como terminado.' using errcode = 'P0001';
  end if;

  update public.trabajos
  set estado = 'asignado', marcado_terminado_at = null
  where id = p_trabajo_id
  returning * into v_trabajo;

  return v_trabajo;
end;
$$;

create function public.cancelar_trabajo(p_trabajo_id uuid)
returns public.trabajos
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_trabajo public.trabajos;
begin
  select * into v_trabajo from public.trabajos where id = p_trabajo_id for update;
  if not found or v_trabajo.cliente_id is distinct from (select auth.uid()) then
    raise exception 'Solo quien publicó el trabajo puede cancelarlo.' using errcode = '42501';
  end if;
  if v_trabajo.estado not in ('abierto', 'asignado') then
    raise exception 'Este trabajo ya no se puede cancelar.' using errcode = 'P0001';
  end if;

  update public.trabajos
  set estado = 'cancelado', cancelado_at = now()
  where id = p_trabajo_id
  returning * into v_trabajo;

  return v_trabajo;
end;
$$;

-- WhatsApp de la otra parte, solo cuando el cliente ya eligió al trabajador.
create function public.contacto_del_trabajo(p_trabajo_id uuid)
returns table (nombre text, apellido text, whatsapp text)
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

  return query
  select p.nombre, p.apellido, d.whatsapp
  from public.perfiles p
  join public.datos_privados d on d.id = p.id
  where p.id = v_otro;
end;
$$;

-- Trabajos abiertos de mis oficios y mis zonas (para el trabajador).
create function public.trabajos_para_mi()
returns setof public.trabajos
language sql
stable
set search_path = ''
as $$
  select t.*
  from public.trabajos t
  join public.perfiles p on p.id = (select auth.uid())
  where t.estado = 'abierto'
    and p.rol = 'trabajador'
    and public.trabajo_coincide_con(t.oficio, t.zona, p.oficios, p.zonas)
  order by t.created_at desc
$$;

revoke execute on function
  public.elegir_postulacion(uuid),
  public.marcar_terminado(uuid),
  public.confirmar_terminado(uuid),
  public.rechazar_terminado(uuid),
  public.cancelar_trabajo(uuid),
  public.contacto_del_trabajo(uuid),
  public.trabajos_para_mi()
from public, anon;
grant execute on function
  public.elegir_postulacion(uuid),
  public.marcar_terminado(uuid),
  public.confirmar_terminado(uuid),
  public.rechazar_terminado(uuid),
  public.cancelar_trabajo(uuid),
  public.contacto_del_trabajo(uuid),
  public.trabajos_para_mi()
to authenticated;
