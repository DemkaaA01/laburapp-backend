-- =============================================================================
-- Ranking por calificaciones y calificaciones pendientes
-- =============================================================================
-- Para ordenar a los trabajadores no alcanza el promedio: alguien con una sola
-- reseña de 5★ quedaría arriba de alguien con 20 reseñas de 4,8★. Se usa un
-- promedio "bayesiano": se arranca como si todos tuvieran 5 reseñas de 3,5★ y
-- cada reseña real va pesando más. Así suben los que tienen más reseñas y
-- mejores.
--   puntaje = (5 × 3,5 + suma de estrellas) / (5 + cantidad de reseñas)

create or replace view public.reputacion_trabajadores
with (security_invoker = true)
as
select
  p.id as trabajador_id,
  count(o.id)::integer as cantidad_opiniones,
  round(avg(o.puntaje), 1) as promedio,
  round((5 * 3.5 + coalesce(sum(o.puntaje), 0)) / (5 + count(o.id)), 3) as puntaje,
  count(o.id) filter (where o.puntaje = 5)::integer as estrellas_5,
  count(o.id) filter (where o.puntaje = 4)::integer as estrellas_4,
  count(o.id) filter (where o.puntaje = 3)::integer as estrellas_3,
  count(o.id) filter (where o.puntaje = 2)::integer as estrellas_2,
  count(o.id) filter (where o.puntaje = 1)::integer as estrellas_1
from public.perfiles p
left join public.opiniones o on o.trabajador_id = p.id
where p.rol = 'trabajador'
group by p.id;

-- Recomendados y servicios: primero los de mejor puntaje.
create or replace function public.trabajadores_recomendados(p_limite integer default 20)
returns table (
  id uuid,
  nombre text,
  apellido text,
  oficios text[],
  oficio_otro text,
  zonas text[],
  foto_path text,
  sobre_mi text,
  promedio numeric,
  cantidad_opiniones integer
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
    and (yo.zonas[1] = any (t.zonas) or ('Toda la ciudad' = any (t.zonas) and yo.zonas[1] <> 'Alrededores'))
  order by r.puntaje desc, r.cantidad_opiniones desc, t.created_at
  limit least(greatest(p_limite, 1), 50)
$$;

create or replace function public.servicios_para_mi(p_oficio text default null)
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
  order by r.puntaje desc, r.cantidad_opiniones desc, s.created_at desc
  limit 50
$$;

-- Trabajos terminados que el usuario todavía no calificó -----------------------
-- Cliente: los que no tienen su opinión. Trabajador: los que no calificó al cliente.
create function public.pendientes_de_calificar()
returns table (trabajo_id uuid, oficio text, nombre text, apellido text, foto_path text, terminado_at timestamptz)
language sql
stable
set search_path = ''
as $$
  select t.id, t.oficio, p.nombre, p.apellido, p.foto_path, t.terminado_at
  from public.trabajos t
  join public.perfiles p on p.id = t.trabajador_elegido_id
  where t.cliente_id = (select auth.uid())
    and t.estado = 'terminado'
    and not exists (select 1 from public.opiniones o where o.trabajo_id = t.id)
  union all
  select t.id, t.oficio, p.nombre, p.apellido, p.foto_path, t.terminado_at
  from public.trabajos t
  join public.perfiles p on p.id = t.cliente_id
  where t.trabajador_elegido_id = (select auth.uid())
    and t.estado = 'terminado'
    and not exists (select 1 from public.calificaciones_clientes c where c.trabajo_id = t.id)
  order by terminado_at desc nulls last
$$;

revoke execute on function public.pendientes_de_calificar() from public, anon;
grant execute on function public.pendientes_de_calificar() to authenticated;
