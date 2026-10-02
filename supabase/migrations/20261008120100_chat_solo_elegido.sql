-- Una vez elegido un trabajador, los demás que habían pasado precio ya no
-- pueden escribirle al cliente (pueden leer lo que hablaron).
create or replace function privado.puedo_escribir(p_conversacion uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.conversaciones c
    join public.trabajos t on t.id = c.trabajo_id
    where c.id = p_conversacion
      and (select auth.uid()) in (c.cliente_id, c.trabajador_id)
      and (t.estado = 'abierto' or (t.estado <> 'cancelado' and t.trabajador_elegido_id = c.trabajador_id))
      and not privado.hay_bloqueo(c.cliente_id, c.trabajador_id)
  )
$$;
