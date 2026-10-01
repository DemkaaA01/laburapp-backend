-- =============================================================================
-- Calificaciones y reputación
-- =============================================================================
-- Con el trabajo terminado (confirmado por el cliente) se califican entre sí,
-- una sola vez por trabajo:
--   opiniones                → el cliente al trabajador: estrellas 1–5 y descripción.
--   calificaciones_clientes  → el trabajador al cliente: solo estrellas 1–5.
-- Son públicas para usuarios con sesión y no se editan ni se borran desde la app.

-- Del cliente al trabajador --------------------------------------------------

create table public.opiniones (
  id uuid primary key default gen_random_uuid(),
  trabajo_id uuid not null unique references public.trabajos (id) on delete cascade,
  cliente_id uuid not null default auth.uid() references public.perfiles (id) on delete cascade,
  trabajador_id uuid not null references public.perfiles (id) on delete cascade,
  puntaje smallint not null check (puntaje between 1 and 5),
  comentario text not null check (char_length(trim(comentario)) between 10 and 500),
  created_at timestamptz not null default now()
);

comment on table public.opiniones is 'Opinión del cliente sobre el trabajador (estrellas y descripción), una por trabajo.';

create index opiniones_trabajador on public.opiniones (trabajador_id, created_at desc);

alter table public.opiniones enable row level security;

create policy "Usuarios con sesión ven las opiniones"
  on public.opiniones for select
  to authenticated
  using (true);

create policy "El cliente opina sobre el trabajador que eligió, con el trabajo terminado"
  on public.opiniones for insert
  to authenticated
  with check (
    cliente_id = (select auth.uid())
    and exists (
      select 1
      from public.trabajos t
      where t.id = opiniones.trabajo_id
        and t.cliente_id = (select auth.uid())
        and t.estado = 'terminado'
        and t.trabajador_elegido_id = opiniones.trabajador_id
    )
  );

revoke insert, update, delete on public.opiniones from anon, authenticated;
grant insert (trabajo_id, trabajador_id, puntaje, comentario) on public.opiniones to authenticated;

-- Del trabajador al cliente --------------------------------------------------

create table public.calificaciones_clientes (
  id uuid primary key default gen_random_uuid(),
  trabajo_id uuid not null unique references public.trabajos (id) on delete cascade,
  trabajador_id uuid not null default auth.uid() references public.perfiles (id) on delete cascade,
  cliente_id uuid not null references public.perfiles (id) on delete cascade,
  puntaje smallint not null check (puntaje between 1 and 5),
  created_at timestamptz not null default now()
);

comment on table public.calificaciones_clientes is 'Estrellas que el trabajador le pone al cliente, una por trabajo.';

create index calificaciones_clientes_cliente on public.calificaciones_clientes (cliente_id, created_at desc);

alter table public.calificaciones_clientes enable row level security;

create policy "Usuarios con sesión ven las calificaciones de clientes"
  on public.calificaciones_clientes for select
  to authenticated
  using (true);

-- El trabajador elegido ve el trabajo por RLS, así que la consulta funciona.
create policy "El trabajador elegido califica al cliente, con el trabajo terminado"
  on public.calificaciones_clientes for insert
  to authenticated
  with check (
    trabajador_id = (select auth.uid())
    and exists (
      select 1
      from public.trabajos t
      where t.id = calificaciones_clientes.trabajo_id
        and t.trabajador_elegido_id = (select auth.uid())
        and t.estado = 'terminado'
        and t.cliente_id = calificaciones_clientes.cliente_id
    )
  );

revoke insert, update, delete on public.calificaciones_clientes from anon, authenticated;
grant insert (trabajo_id, cliente_id, puntaje) on public.calificaciones_clientes to authenticated;

-- Reputación -----------------------------------------------------------------

create view public.reputacion_trabajadores
with (security_invoker = true)
as
select
  p.id as trabajador_id,
  count(o.id)::integer as cantidad_opiniones,
  round(avg(o.puntaje), 1) as promedio
from public.perfiles p
left join public.opiniones o on o.trabajador_id = p.id
where p.rol = 'trabajador'
group by p.id;

create view public.reputacion_clientes
with (security_invoker = true)
as
select
  p.id as cliente_id,
  count(c.id)::integer as cantidad_calificaciones,
  round(avg(c.puntaje), 1) as promedio
from public.perfiles p
left join public.calificaciones_clientes c on c.cliente_id = p.id
where p.rol = 'cliente'
group by p.id;

revoke all on public.reputacion_trabajadores, public.reputacion_clientes from anon;

-- Trabajadores recomendados para el cliente: los de los rubros que le
-- interesan y que trabajan en su zona, mejor puntuados primero.
create function public.trabajadores_recomendados(p_limite integer default 20)
returns table (
  id uuid,
  nombre text,
  apellido text,
  oficios text[],
  oficio_otro text,
  zonas text[],
  promedio numeric,
  cantidad_opiniones integer
)
language sql
stable
set search_path = ''
as $$
  select t.id, t.nombre, t.apellido, t.oficios, t.oficio_otro, t.zonas, r.promedio, r.cantidad_opiniones
  from public.perfiles yo
  join public.perfiles t on t.rol = 'trabajador' and t.oficios && yo.oficios
  join public.reputacion_trabajadores r on r.trabajador_id = t.id
  where yo.id = (select auth.uid())
    and yo.rol = 'cliente'
    and (yo.zonas[1] = any (t.zonas) or ('Toda la ciudad' = any (t.zonas) and yo.zonas[1] <> 'Alrededores'))
  order by r.promedio desc nulls last, r.cantidad_opiniones desc, t.created_at
  limit least(greatest(p_limite, 1), 50)
$$;

revoke execute on function public.trabajadores_recomendados(integer) from public, anon;
grant execute on function public.trabajadores_recomendados(integer) to authenticated;
