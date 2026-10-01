-- =============================================================================
-- Servicios publicados por trabajadores y pedidos directos
-- =============================================================================
-- El trabajador publica avisos de lo que hace ("Pinto interiores y frentes,
-- desde $X el m²"). El cliente los ve y le pide presupuesto: eso crea un
-- trabajo dirigido solo a ese trabajador (trabajador_invitado_id), que sigue el
-- flujo de siempre (precio → elegir → WhatsApp → terminado → calificaciones).

-- Servicios ------------------------------------------------------------------

create table public.servicios (
  id uuid primary key default gen_random_uuid(),
  trabajador_id uuid not null default auth.uid() references public.perfiles (id) on delete cascade,
  oficio text not null check (oficio = any (public.oficios_validos())),
  titulo text not null check (char_length(trim(titulo)) between 5 and 80),
  descripcion text not null check (char_length(trim(descripcion)) between 10 and 1000),
  -- Precio de referencia (opcional): "desde $X por m²".
  precio_desde integer check (precio_desde between 1 and 100000000),
  precio_unidad text check (precio_unidad in ('trabajo', 'hora', 'dia', 'm2', 'visita')),
  zonas text[] not null check (
    cardinality(zonas) > 0 and zonas <@ (public.zonas_validas() || 'Toda la ciudad'::text)
  ),
  -- Fotos en el bucket público "perfiles", carpeta del trabajador. De 0 a 5.
  fotos text[] not null default '{}',
  activo boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint servicios_precio check ((precio_desde is null) = (precio_unidad is null)),
  constraint servicios_fotos check (public.fotos_validas(trabajador_id, fotos))
);

comment on table public.servicios is 'Avisos de los trabajadores: qué hacen, dónde y desde qué precio.';

create index servicios_activos on public.servicios (oficio, created_at desc) where activo;
create index servicios_trabajador on public.servicios (trabajador_id, created_at desc);

create trigger servicios_updated_at
  before update on public.servicios
  for each row execute function public.tocar_updated_at();

-- ¿El oficio está entre los del trabajador que está usando la app?
create function public.es_mi_oficio(p_oficio text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.perfiles
    where id = (select auth.uid()) and rol = 'trabajador' and p_oficio = any (oficios)
  )
$$;

create function public.cantidad_servicios(p_trabajador_id uuid)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::integer from public.servicios where trabajador_id = p_trabajador_id
$$;

revoke execute on function public.es_mi_oficio(text), public.cantidad_servicios(uuid) from public, anon;
grant execute on function public.es_mi_oficio(text), public.cantidad_servicios(uuid) to authenticated;

alter table public.servicios enable row level security;

create policy "Ver servicios activos y los propios"
  on public.servicios for select
  to authenticated
  using (activo or trabajador_id = (select auth.uid()));

create policy "El trabajador publica servicios de sus oficios, hasta 10"
  on public.servicios for insert
  to authenticated
  with check (
    trabajador_id = (select auth.uid())
    and public.es_mi_oficio(oficio)
    and public.cantidad_servicios((select auth.uid())) < 10
  );

create policy "El trabajador edita sus servicios"
  on public.servicios for update
  to authenticated
  using (trabajador_id = (select auth.uid()))
  with check (trabajador_id = (select auth.uid()) and public.es_mi_oficio(oficio));

create policy "El trabajador borra sus servicios"
  on public.servicios for delete
  to authenticated
  using (trabajador_id = (select auth.uid()));

revoke all on public.servicios from anon;
revoke insert, update, delete on public.servicios from authenticated;
grant insert (oficio, titulo, descripcion, precio_desde, precio_unidad, zonas, fotos) on public.servicios to authenticated;
grant update (oficio, titulo, descripcion, precio_desde, precio_unidad, zonas, fotos, activo) on public.servicios to authenticated;
grant delete on public.servicios to authenticated;

-- Pedidos directos -----------------------------------------------------------

alter table public.trabajos
  add column trabajador_invitado_id uuid references public.perfiles (id) on delete set null,
  add column servicio_id uuid references public.servicios (id) on delete set null;

create index trabajos_invitado on public.trabajos (trabajador_invitado_id) where trabajador_invitado_id is not null;

grant insert (trabajador_invitado_id, servicio_id) on public.trabajos to authenticated;

-- El invitado tiene que ser un trabajador, y el servicio (si hay) suyo y activo.
create function public.invitacion_valida(p_invitado uuid, p_servicio uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select
    p_invitado is null and p_servicio is null
    or (
      exists (select 1 from public.perfiles where id = p_invitado and rol = 'trabajador')
      and (
        p_servicio is null
        or exists (
          select 1 from public.servicios where id = p_servicio and trabajador_id = p_invitado and activo
        )
      )
    )
$$;

revoke execute on function public.invitacion_valida(uuid, uuid) from public, anon;
grant execute on function public.invitacion_valida(uuid, uuid) to authenticated;

drop policy "Los clientes publican trabajos" on public.trabajos;
create policy "Los clientes publican trabajos"
  on public.trabajos for insert
  to authenticated
  with check (
    cliente_id = (select auth.uid())
    and (select public.mi_rol()) = 'cliente'
    and estado = 'abierto'
    and trabajador_elegido_id is null
    and public.invitacion_valida(trabajador_invitado_id, servicio_id)
  );

-- Un pedido directo solo lo ven el cliente y el trabajador invitado.
drop policy "Ver trabajos" on public.trabajos;
create policy "Ver trabajos"
  on public.trabajos for select
  to authenticated
  using (
    cliente_id = (select auth.uid())
    or trabajador_elegido_id = (select auth.uid())
    or trabajador_invitado_id = (select auth.uid())
    or (estado = 'abierto' and trabajador_invitado_id is null and (select public.mi_rol()) = 'trabajador')
    or public.me_postule(id)
  );

-- En un pedido directo solo se postula el invitado (sin importar oficio y zona).
create or replace function public.puedo_postularme(p_trabajo_id uuid)
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
      and (
        t.trabajador_invitado_id = p.id
        or (t.trabajador_invitado_id is null and public.trabajo_coincide_con(t.oficio, t.zona, p.oficios, p.zonas))
      )
  )
$$;

-- Trabajos para el trabajador: los abiertos de sus oficios y zonas, más los
-- que le pidieron a él directamente.
create or replace function public.trabajos_para_mi()
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
    and (
      t.trabajador_invitado_id = p.id
      or (t.trabajador_invitado_id is null and public.trabajo_coincide_con(t.oficio, t.zona, p.oficios, p.zonas))
    )
  order by (t.trabajador_invitado_id = p.id) desc nulls last, t.created_at desc
$$;

-- Servicios para el cliente -------------------------------------------------
-- Activos, que llegan a su zona; opcionalmente de un oficio. Mejor puntuados primero.
create function public.servicios_para_mi(p_oficio text default null)
returns table (
  id uuid,
  trabajador_id uuid,
  oficio text,
  titulo text,
  descripcion text,
  precio_desde integer,
  precio_unidad text,
  zonas text[],
  fotos text[],
  created_at timestamptz,
  nombre text,
  apellido text,
  foto_path text,
  promedio numeric,
  cantidad_opiniones integer
)
language sql
stable
set search_path = ''
as $$
  select s.id, s.trabajador_id, s.oficio, s.titulo, s.descripcion, s.precio_desde, s.precio_unidad,
         s.zonas, s.fotos, s.created_at, t.nombre, t.apellido, t.foto_path, r.promedio, r.cantidad_opiniones
  from public.perfiles yo
  join public.servicios s on s.activo
  join public.perfiles t on t.id = s.trabajador_id
  join public.reputacion_trabajadores r on r.trabajador_id = t.id
  where yo.id = (select auth.uid())
    and yo.rol = 'cliente'
    and (p_oficio is null or s.oficio = p_oficio)
    and (yo.zonas[1] = any (s.zonas) or ('Toda la ciudad' = any (s.zonas) and yo.zonas[1] <> 'Alrededores'))
  order by r.promedio desc nulls last, r.cantidad_opiniones desc, s.created_at desc
  limit 50
$$;

revoke execute on function public.servicios_para_mi(text) from public, anon;
grant execute on function public.servicios_para_mi(text) to authenticated;

-- Fotos de servicios: van en el bucket público "perfiles", que ya permite subir
-- solo a la carpeta propia ({id}/servicios/...).
