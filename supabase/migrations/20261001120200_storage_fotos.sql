-- =============================================================================
-- Fotos de los trabajos (Storage)
-- =============================================================================
-- Bucket privado: cada cliente sube a su propia carpeta ({su id}/archivo.jpg) y
-- los usuarios con sesión pueden verlas (la app pide URLs firmadas).

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('fotos-trabajos', 'fotos-trabajos', false, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

create policy "Ver fotos de trabajos"
  on storage.objects for select
  to authenticated
  using (bucket_id = 'fotos-trabajos');

create policy "Subir fotos a la carpeta propia"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'fotos-trabajos'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy "Borrar fotos de la carpeta propia"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'fotos-trabajos'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );
