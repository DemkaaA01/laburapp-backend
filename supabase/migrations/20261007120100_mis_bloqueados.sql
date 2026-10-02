-- Lista de usuarios bloqueados para Ajustes. Hace falta una función porque, al
-- bloquear a un cliente, su perfil deja de verse por las reglas normales.
create function public.mis_bloqueados()
returns table (id uuid, nombre text, apellido text, foto_path text, rol text, created_at timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select p.id, p.nombre, p.apellido, p.foto_path, p.rol, b.created_at
  from public.bloqueos b
  join public.perfiles p on p.id = b.bloqueado_id
  where b.bloqueador_id = (select auth.uid())
  order by b.created_at desc
$$;

revoke execute on function public.mis_bloqueados() from public, anon;
grant execute on function public.mis_bloqueados() to authenticated;
