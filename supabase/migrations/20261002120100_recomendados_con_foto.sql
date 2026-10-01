-- Los recomendados ahora devuelven también la foto de perfil y el "sobre mí".
drop function public.trabajadores_recomendados(integer);

create function public.trabajadores_recomendados(p_limite integer default 20)
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
  order by r.promedio desc nulls last, r.cantidad_opiniones desc, t.created_at
  limit least(greatest(p_limite, 1), 50)
$$;

revoke execute on function public.trabajadores_recomendados(integer) from public, anon;
grant execute on function public.trabajadores_recomendados(integer) to authenticated;
