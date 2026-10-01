-- =============================================================================
-- Borrar la cuenta propia
-- =============================================================================
-- Google Play exige que el usuario pueda borrar su cuenta desde la app.
-- Al borrar el usuario de auth se borra en cascada su perfil, sus datos
-- privados, sus trabajos publicados (con sus postulaciones), sus postulaciones
-- y las calificaciones donde participa. En los trabajos donde era el
-- trabajador elegido, queda sin trabajador (trabajador_elegido_id = null).

create function public.borrar_mi_cuenta()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_yo uuid := (select auth.uid());
begin
  if v_yo is null then
    raise exception 'Tenés que haber iniciado sesión.' using errcode = '42501';
  end if;

  delete from auth.users where id = v_yo;
end;
$$;

revoke execute on function public.borrar_mi_cuenta() from public, anon;
grant execute on function public.borrar_mi_cuenta() to authenticated;
