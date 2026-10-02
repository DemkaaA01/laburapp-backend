-- Reparte en el tiempo los datos de demostración (solo cuentas @laburapp.test).
-- Si todo queda con fecha de hoy, los clientes de prueba llegan al límite de
-- 10 trabajos por día y no se puede probar publicar. Además queda más real.
-- Los trabajos de las pruebas automáticas ("E2E …") no se tocan.

with demo as (
  select id from auth.users where email like '%@laburapp.test'
)
-- Terminados: entre 3 y 27 días atrás, con cada paso un poco después.
update public.trabajos t
set created_at = x.inicio,
    asignado_at = x.inicio + interval '1 day',
    marcado_terminado_at = x.inicio + interval '2 days',
    terminado_at = x.inicio + interval '2 days 3 hours'
from (
  select id, now() - interval '1 day' * (3 + abs(hashtext(id::text)) % 25) as inicio
  from public.trabajos
) x
where x.id = t.id
  and t.estado = 'terminado'
  and t.created_at > now() - interval '1 day'
  and t.cliente_id in (select id from demo)
  and t.descripcion not like 'E2E%';

-- Abiertos: entre 2 y 72 horas atrás.
with demo as (
  select id from auth.users where email like '%@laburapp.test'
)
update public.trabajos t
set created_at = now() - interval '1 hour' * (2 + abs(hashtext(t.id::text)) % 70)
where t.estado = 'abierto'
  and t.created_at > now() - interval '1 day'
  and t.cliente_id in (select id from demo)
  and t.descripcion not like 'E2E%';

-- Precios: unas horas después de publicado el trabajo.
update public.postulaciones p
set created_at = least(now(), t.created_at + interval '1 hour' * (1 + abs(hashtext(p.id::text)) % 6))
from public.trabajos t
where t.id = p.trabajo_id
  and p.created_at > t.created_at + interval '1 day';

-- Calificaciones: unas horas después de terminado.
update public.opiniones o
set created_at = t.terminado_at + interval '3 hours'
from public.trabajos t
where t.id = o.trabajo_id
  and t.terminado_at is not null
  and o.created_at > t.terminado_at + interval '1 day';

update public.calificaciones_clientes c
set created_at = t.terminado_at + interval '5 hours'
from public.trabajos t
where t.id = c.trabajo_id
  and t.terminado_at is not null
  and c.created_at > t.terminado_at + interval '1 day';
