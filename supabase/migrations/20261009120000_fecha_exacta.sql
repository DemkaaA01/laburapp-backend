-- =============================================================================
-- Fecha exacta para un trabajo
-- =============================================================================
-- Además de "lo antes posible", "esta semana", etc., el cliente puede elegir
-- un día: para_cuando = 'fecha' y la fecha en la columna nueva.

alter table public.trabajos add column fecha date;

alter table public.trabajos drop constraint trabajos_para_cuando_check;
alter table public.trabajos add constraint trabajos_para_cuando_check
  check (para_cuando in ('lo_antes_posible', 'esta_semana', 'este_mes', 'sin_apuro', 'fecha'));

-- Con 'fecha' tiene que haber fecha, y sin 'fecha' no.
alter table public.trabajos add constraint trabajos_fecha
  check ((para_cuando = 'fecha') = (fecha is not null));

comment on column public.trabajos.fecha is 'Día exacto, solo si para_cuando = ''fecha''. Desde hoy y hasta un año (hora argentina).';

-- Desde hoy y hasta un año, con la hora de Argentina (al publicar o cambiarla).
create function privado.validar_fecha_trabajo()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_hoy date := (now() at time zone 'America/Argentina/Buenos_Aires')::date;
begin
  if new.fecha is not null and (tg_op = 'INSERT' or new.fecha is distinct from old.fecha) then
    if new.fecha < v_hoy then
      raise exception 'La fecha ya pasó. Elegí hoy o un día que venga.' using errcode = 'P0001';
    end if;
    if new.fecha > v_hoy + 366 then
      raise exception 'Elegí una fecha dentro del próximo año.' using errcode = 'P0001';
    end if;
  end if;
  return new;
end;
$$;

create trigger validar_fecha_trabajo
  before insert or update of fecha on public.trabajos
  for each row execute function privado.validar_fecha_trabajo();

grant insert (fecha) on public.trabajos to authenticated;
grant update (fecha) on public.trabajos to authenticated;

revoke execute on function privado.validar_fecha_trabajo() from public, anon;
grant execute on function privado.validar_fecha_trabajo() to authenticated;
