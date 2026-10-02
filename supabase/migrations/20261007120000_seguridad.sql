-- =============================================================================
-- Seguridad: helpers privados, perfiles de clientes privados, bloqueos,
-- reportes, fotos de pedidos y límites anti-spam
-- =============================================================================

-- 1. Helpers de las políticas, fuera de la API -------------------------------
-- Se usan dentro de las reglas (RLS) pero no tienen por qué poder llamarse
-- desde la app (/rest/v1/rpc/...). El schema "privado" no está expuesto.
-- Las políticas que ya los usan siguen funcionando: guardan la función, no el nombre.

create schema if not exists privado;
revoke all on schema privado from public, anon;
grant usage on schema privado to authenticated;

alter function public.mi_rol() set schema privado;
alter function public.soy_cliente_del_trabajo(uuid) set schema privado;
alter function public.me_postule(uuid) set schema privado;
alter function public.trabajo_abierto(uuid) set schema privado;
alter function public.puedo_postularme(uuid) set schema privado;
alter function public.cantidad_fotos_galeria(uuid) set schema privado;
alter function public.cantidad_servicios(uuid) set schema privado;
alter function public.es_mi_oficio(text) set schema privado;
alter function public.invitacion_valida(uuid, uuid) set schema privado;

-- 2. Bloqueos ----------------------------------------------------------------
-- Si A bloquea a B (o B a A): no se ven los trabajos abiertos ni los servicios
-- del otro, no se pueden pasar precio ni pedir presupuesto, y no se avisan.

create table public.bloqueos (
  bloqueador_id uuid not null default auth.uid() references public.perfiles (id) on delete cascade,
  bloqueado_id uuid not null references public.perfiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (bloqueador_id, bloqueado_id),
  constraint bloqueos_no_a_si_mismo check (bloqueador_id <> bloqueado_id)
);

comment on table public.bloqueos is 'Usuarios que cada uno bloqueó. Solo los ve quien bloqueó.';

alter table public.bloqueos enable row level security;

create policy "Cada uno ve a quién bloqueó"
  on public.bloqueos for select to authenticated
  using (bloqueador_id = (select auth.uid()));

create policy "Cada uno bloquea"
  on public.bloqueos for insert to authenticated
  with check (bloqueador_id = (select auth.uid()));

create policy "Cada uno desbloquea"
  on public.bloqueos for delete to authenticated
  using (bloqueador_id = (select auth.uid()));

revoke all on public.bloqueos from anon;
revoke insert, update, delete on public.bloqueos from authenticated;
grant insert (bloqueado_id) on public.bloqueos to authenticated;
grant delete on public.bloqueos to authenticated;

create function privado.hay_bloqueo(p_a uuid, p_b uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.bloqueos
    where (bloqueador_id = p_a and bloqueado_id = p_b) or (bloqueador_id = p_b and bloqueado_id = p_a)
  )
$$;

-- 3. Perfiles de clientes privados -------------------------------------------
-- Los trabajadores son públicos (es su vidriera). A un cliente lo ve él mismo
-- y quien tiene relación con un trabajo suyo: el elegido, el invitado, quien le
-- pasó precio, o un trabajador que ve su pedido abierto.

create function privado.puedo_ver_perfil(p_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select
    p_id = (select auth.uid())
    or exists (select 1 from public.perfiles where id = p_id and rol = 'trabajador')
    or exists (
      select 1
      from public.trabajos t
      where t.cliente_id = p_id
        and (
          t.trabajador_elegido_id = (select auth.uid())
          or t.trabajador_invitado_id = (select auth.uid())
          or exists (select 1 from public.postulaciones q where q.trabajo_id = t.id and q.trabajador_id = (select auth.uid()))
          or (
            t.estado = 'abierto'
            and t.trabajador_invitado_id is null
            and privado.mi_rol() = 'trabajador'
            and not privado.hay_bloqueo(p_id, (select auth.uid()))
          )
        )
    )
$$;

drop policy "Usuarios con sesión ven los perfiles" on public.perfiles;
create policy "Ver trabajadores, a uno mismo y a los clientes con los que hay trabajo"
  on public.perfiles for select to authenticated
  using (privado.puedo_ver_perfil(id));

-- Opiniones para mostrar en un perfil: el autor aparece como "Marta G."
-- (el perfil completo del cliente no es público).
create function public.opiniones_de(p_trabajador uuid, p_limite integer default 50)
returns table (id uuid, puntaje smallint, comentario text, created_at timestamptz, autor text)
language sql
stable
security definer
set search_path = ''
as $$
  select o.id, o.puntaje, o.comentario, o.created_at,
         coalesce(c.nombre || ' ' || left(c.apellido, 1) || '.', 'Un cliente')
  from public.opiniones o
  left join public.perfiles c on c.id = o.cliente_id
  where o.trabajador_id = p_trabajador
    and (select auth.uid()) is not null
  order by o.created_at desc
  limit least(greatest(p_limite, 1), 100)
$$;

revoke execute on function public.opiniones_de(uuid, integer) from public, anon;
grant execute on function public.opiniones_de(uuid, integer) to authenticated;

-- 4. Bloqueos en lo que ya existía -------------------------------------------

drop policy "Ver trabajos" on public.trabajos;
create policy "Ver trabajos"
  on public.trabajos for select to authenticated
  using (
    cliente_id = (select auth.uid())
    or trabajador_elegido_id = (select auth.uid())
    or trabajador_invitado_id = (select auth.uid())
    or (
      estado = 'abierto'
      and trabajador_invitado_id is null
      and (select privado.mi_rol()) = 'trabajador'
      and not privado.hay_bloqueo(cliente_id, (select auth.uid()))
    )
    or privado.me_postule(id)
  );

create or replace function privado.puedo_postularme(p_trabajo_id uuid)
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
      and not privado.hay_bloqueo(t.cliente_id, p.id)
      and (
        t.trabajador_invitado_id = p.id
        or (t.trabajador_invitado_id is null and public.trabajo_coincide_con(t.oficio, t.zona, p.oficios, p.zonas))
      )
  )
$$;

create or replace function privado.invitacion_valida(p_invitado uuid, p_servicio uuid)
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
      and not privado.hay_bloqueo((select auth.uid()), p_invitado)
      and (
        p_servicio is null
        or exists (select 1 from public.servicios where id = p_servicio and trabajador_id = p_invitado and activo)
      )
    )
$$;

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
    and not privado.hay_bloqueo(t.cliente_id, p.id)
    and (
      t.trabajador_invitado_id = p.id
      or (t.trabajador_invitado_id is null and public.trabajo_coincide_con(t.oficio, t.zona, p.oficios, p.zonas))
    )
  order by (t.trabajador_invitado_id = p.id) desc nulls last, t.created_at desc
$$;

create or replace function public.trabajadores_recomendados(p_limite integer default 20)
returns table (
  id uuid, nombre text, apellido text, oficios text[], oficio_otro text, zonas text[],
  foto_path text, sobre_mi text, promedio numeric, cantidad_opiniones integer
)
language sql
stable
set search_path = ''
as $$
  select t.id, t.nombre, t.apellido, t.oficios, t.oficio_otro, t.zonas, t.foto_path, t.sobre_mi,
         r.promedio, r.cantidad_opiniones
  from public.perfiles yo
  join public.perfiles t on t.rol = 'trabajador' and t.oficios && yo.oficios
  join public.reputacion_trabajadores r on r.trabajador_id = t.id
  where yo.id = (select auth.uid())
    and yo.rol = 'cliente'
    and not privado.hay_bloqueo(yo.id, t.id)
    and (yo.zonas[1] = any (t.zonas) or ('Toda la ciudad' = any (t.zonas) and yo.zonas[1] <> 'Alrededores'))
  order by r.puntaje desc, r.cantidad_opiniones desc, t.created_at
  limit least(greatest(p_limite, 1), 50)
$$;

create or replace function public.servicios_para_mi(p_oficio text default null)
returns table (
  id uuid, trabajador_id uuid, oficio text, titulo text, descripcion text, precio_desde integer,
  precio_unidad text, zonas text[], fotos text[], created_at timestamptz, nombre text, apellido text,
  foto_path text, promedio numeric, cantidad_opiniones integer
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
    and not privado.hay_bloqueo(yo.id, t.id)
    and (p_oficio is null or s.oficio = p_oficio)
    and (yo.zonas[1] = any (s.zonas) or ('Toda la ciudad' = any (s.zonas) and yo.zonas[1] <> 'Alrededores'))
  order by r.puntaje desc, r.cantidad_opiniones desc, s.created_at desc
  limit 50
$$;

-- Los trabajos nuevos no se avisan a quien bloqueó o fue bloqueado por el cliente.
create or replace function public.avisar_trabajo_nuevo()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cliente text := coalesce((select nombre from public.perfiles where id = new.cliente_id), 'Un vecino');
begin
  if new.trabajador_invitado_id is not null then
    perform public.notificar(
      new.trabajador_invitado_id, 'pedido_directo',
      v_cliente || ' te pidió presupuesto',
      new.oficio || ' en ' || new.zona || ': ' || public.resumen(new.descripcion),
      new.id
    );
  else
    perform public.notificar(
      p.id, 'trabajo_nuevo',
      'Trabajo nuevo de ' || lower(new.oficio) || ' en ' || new.zona,
      public.resumen(new.descripcion),
      new.id
    )
    from public.perfiles p
    where p.rol = 'trabajador'
      and p.id <> new.cliente_id
      and not privado.hay_bloqueo(new.cliente_id, p.id)
      and public.trabajo_coincide_con(new.oficio, new.zona, p.oficios, p.zonas);
  end if;
  return new;
end;
$$;

-- 5. Fotos de pedidos: solo si podés ver ese trabajo -------------------------
-- Antes cualquier usuario con sesión podía listar todas las fotos del bucket.

drop policy "Ver fotos de trabajos" on storage.objects;
create policy "Ver fotos de trabajos que puedo ver"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'fotos-trabajos'
    and (
      (storage.foldername(name))[1] = (select auth.uid())::text
      or exists (select 1 from public.trabajos t where storage.objects.name = any (t.fotos))
    )
  );

-- 6. Reportes ----------------------------------------------------------------
-- Quedan para revisar desde el panel de Supabase. Quien reporta solo ve los suyos.

create table public.reportes (
  id uuid primary key default gen_random_uuid(),
  autor_id uuid default auth.uid() references public.perfiles (id) on delete set null,
  reportado_id uuid not null references public.perfiles (id) on delete cascade,
  trabajo_id uuid references public.trabajos (id) on delete set null,
  motivo text not null check (motivo in ('no_se_presento', 'mal_trato', 'estafa', 'spam', 'contenido_inapropiado', 'otro')),
  detalle text check (char_length(detalle) <= 1000),
  estado text not null default 'pendiente' check (estado in ('pendiente', 'revisado', 'descartado')),
  created_at timestamptz not null default now(),
  constraint reportes_no_a_si_mismo check (autor_id is distinct from reportado_id)
);

comment on table public.reportes is 'Reportes de usuarios. Se revisan desde el panel (service role).';

create index reportes_pendientes on public.reportes (created_at desc) where estado = 'pendiente';

alter table public.reportes enable row level security;

create policy "Cada uno ve sus reportes"
  on public.reportes for select to authenticated
  using (autor_id = (select auth.uid()));

create policy "Cada uno reporta"
  on public.reportes for insert to authenticated
  with check (autor_id = (select auth.uid()));

revoke all on public.reportes from anon;
revoke insert, update, delete on public.reportes from authenticated;
grant insert (reportado_id, trabajo_id, motivo, detalle) on public.reportes to authenticated;

-- 7. Límites anti-spam ---------------------------------------------------------
-- Solo para usuarios de la app (el seed y el panel no tienen límite).
-- SECURITY INVOKER a propósito: así current_user es el de la app y cuenta
-- solo lo que el usuario puede ver (lo propio).

create function privado.limitar(p_cantidad bigint, p_maximo integer, p_mensaje text)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if current_user = 'authenticated' and p_cantidad >= p_maximo then
    raise exception '%', p_mensaje using errcode = 'P0001';
  end if;
end;
$$;

create function privado.limite_trabajos()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  perform privado.limitar(
    (select count(*) from public.trabajos where cliente_id = new.cliente_id and created_at > now() - interval '1 day'),
    10, 'Llegaste al máximo de 10 trabajos por día. Probá de nuevo mañana.'
  );
  perform privado.limitar(
    (select count(*) from public.trabajos where cliente_id = new.cliente_id and estado = 'abierto'),
    20, 'Tenés 20 trabajos abiertos. Cerrá o cancelá alguno para publicar otro.'
  );
  return new;
end;
$$;

create trigger limite_trabajos
  before insert on public.trabajos
  for each row execute function privado.limite_trabajos();

create function privado.limite_postulaciones()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  perform privado.limitar(
    (select count(*) from public.postulaciones where trabajador_id = new.trabajador_id and created_at > now() - interval '1 day'),
    40, 'Llegaste al máximo de 40 precios por día. Probá de nuevo mañana.'
  );
  return new;
end;
$$;

create trigger limite_postulaciones
  before insert on public.postulaciones
  for each row execute function privado.limite_postulaciones();

create function privado.limite_reportes()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  perform privado.limitar(
    (select count(*) from public.reportes where autor_id = new.autor_id and created_at > now() - interval '1 day'),
    10, 'Llegaste al máximo de 10 reportes por día.'
  );
  return new;
end;
$$;

create trigger limite_reportes
  before insert on public.reportes
  for each row execute function privado.limite_reportes();

-- Permisos del schema privado: lo necesario para que funcionen las reglas.
revoke execute on all functions in schema privado from public, anon;
grant execute on all functions in schema privado to authenticated;
