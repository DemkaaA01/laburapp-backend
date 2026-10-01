-- =============================================================================
-- Foto de perfil, "Sobre mí" y galería de trabajos
-- =============================================================================
-- Las fotos de perfil y de la galería van en el bucket público "perfiles",
-- cada usuario en su carpeta ({su id}/...). Son públicas a propósito: es la
-- vidriera del trabajador. Las fotos de los pedidos siguen en el bucket privado.

-- Perfil ---------------------------------------------------------------------

alter table public.perfiles
  add column foto_path text check (char_length(foto_path) <= 300),
  add column sobre_mi text check (char_length(sobre_mi) <= 400),
  add constraint perfiles_foto_propia check (foto_path is null or foto_path like id::text || '/%');

grant update (foto_path, sobre_mi) on public.perfiles to authenticated;

-- Galería de trabajos (solo trabajadores, hasta 12 fotos) ---------------------

create table public.galeria (
  id uuid primary key default gen_random_uuid(),
  trabajador_id uuid not null default auth.uid() references public.perfiles (id) on delete cascade,
  foto_path text not null check (char_length(foto_path) <= 300),
  descripcion text check (char_length(descripcion) <= 200),
  created_at timestamptz not null default now(),

  constraint galeria_foto_propia check (foto_path like trabajador_id::text || '/%')
);

comment on table public.galeria is 'Fotos de trabajos que hizo el trabajador (su vidriera).';

create index galeria_trabajador on public.galeria (trabajador_id, created_at desc);

create function public.cantidad_fotos_galeria(p_trabajador_id uuid)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::integer from public.galeria where trabajador_id = p_trabajador_id
$$;

revoke execute on function public.cantidad_fotos_galeria(uuid) from public, anon;
grant execute on function public.cantidad_fotos_galeria(uuid) to authenticated;

alter table public.galeria enable row level security;

create policy "Usuarios con sesión ven las galerías"
  on public.galeria for select
  to authenticated
  using (true);

create policy "El trabajador suma fotos a su galería, hasta 12"
  on public.galeria for insert
  to authenticated
  with check (
    trabajador_id = (select auth.uid())
    and (select public.mi_rol()) = 'trabajador'
    and public.cantidad_fotos_galeria((select auth.uid())) < 12
  );

create policy "El trabajador edita sus fotos"
  on public.galeria for update
  to authenticated
  using (trabajador_id = (select auth.uid()))
  with check (trabajador_id = (select auth.uid()));

create policy "El trabajador borra sus fotos"
  on public.galeria for delete
  to authenticated
  using (trabajador_id = (select auth.uid()));

revoke all on public.galeria from anon;
revoke insert, update, delete on public.galeria from authenticated;
grant insert (foto_path, descripcion) on public.galeria to authenticated;
grant update (descripcion) on public.galeria to authenticated;
grant delete on public.galeria to authenticated;

-- Storage: bucket público "perfiles" -----------------------------------------

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('perfiles', 'perfiles', true, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

create policy "Subir a la carpeta propia de perfiles"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'perfiles'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy "Borrar de la carpeta propia de perfiles"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'perfiles'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

-- Para que el borrado funcione con la API de Storage hace falta poder ver el
-- archivo propio (el bucket es público igual para mostrarlas).
create policy "Ver la carpeta propia de perfiles"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'perfiles'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );
