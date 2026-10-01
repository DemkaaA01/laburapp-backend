-- =============================================================================
-- Notificaciones (dentro de la app y push al teléfono)
-- =============================================================================
-- Cada cosa importante que pasa crea una fila en `notificaciones` (la campanita
-- de la app). Al insertarse, si el usuario tiene teléfonos registrados en
-- `dispositivos`, se manda un push con el servicio de Expo usando pg_net.
-- Si el push falla, la notificación igual queda en la app.

do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_net') then
    create extension if not exists pg_net;
  end if;
end
$$;

-- Teléfonos de cada usuario (token de Expo) ---------------------------------

create table public.dispositivos (
  token text primary key check (token ~ '^Expo(nent)?PushToken\[.+\]$'),
  usuario_id uuid not null references public.perfiles (id) on delete cascade,
  plataforma text check (plataforma in ('ios', 'android', 'web')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.dispositivos is 'Tokens de push de Expo. Se manejan solo con registrar_dispositivo() y olvidar_dispositivo().';

create index dispositivos_usuario on public.dispositivos (usuario_id);

alter table public.dispositivos enable row level security;
revoke all on public.dispositivos from anon, authenticated;

-- Si el teléfono pasa a otra cuenta (cerró sesión y entró otro), el token se
-- reasigna: por eso se hace con una función y no con un insert directo.
create function public.registrar_dispositivo(p_token text, p_plataforma text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null then
    raise exception 'Tenés que haber iniciado sesión.' using errcode = '42501';
  end if;
  insert into public.dispositivos (token, usuario_id, plataforma)
  values (p_token, (select auth.uid()), p_plataforma)
  on conflict (token) do update
    set usuario_id = excluded.usuario_id, plataforma = excluded.plataforma, updated_at = now();
end;
$$;

-- Al cerrar sesión: ese teléfono deja de recibir avisos de esta cuenta.
create function public.olvidar_dispositivo(p_token text)
returns void
language sql
security definer
set search_path = ''
as $$
  delete from public.dispositivos where token = p_token and usuario_id = (select auth.uid())
$$;

revoke execute on function public.registrar_dispositivo(text, text), public.olvidar_dispositivo(text) from public, anon;
grant execute on function public.registrar_dispositivo(text, text), public.olvidar_dispositivo(text) to authenticated;

-- Notificaciones -------------------------------------------------------------

create table public.notificaciones (
  id uuid primary key default gen_random_uuid(),
  usuario_id uuid not null references public.perfiles (id) on delete cascade,
  tipo text not null,
  titulo text not null,
  cuerpo text not null,
  trabajo_id uuid references public.trabajos (id) on delete cascade,
  leida boolean not null default false,
  created_at timestamptz not null default now()
);

comment on table public.notificaciones is 'Avisos para cada usuario (campanita). Las crean los triggers, no la app.';

create index notificaciones_usuario on public.notificaciones (usuario_id, created_at desc);
create index notificaciones_no_leidas on public.notificaciones (usuario_id) where not leida;

alter table public.notificaciones enable row level security;

create policy "Cada uno ve sus notificaciones"
  on public.notificaciones for select
  to authenticated
  using (usuario_id = (select auth.uid()));

create policy "Cada uno marca sus notificaciones como leídas"
  on public.notificaciones for update
  to authenticated
  using (usuario_id = (select auth.uid()))
  with check (usuario_id = (select auth.uid()));

revoke all on public.notificaciones from anon;
revoke insert, update, delete on public.notificaciones from authenticated;
grant update (leida) on public.notificaciones to authenticated;

create function public.marcar_notificaciones_leidas()
returns void
language sql
security definer
set search_path = ''
as $$
  update public.notificaciones set leida = true where usuario_id = (select auth.uid()) and not leida
$$;

revoke execute on function public.marcar_notificaciones_leidas() from public, anon;
grant execute on function public.marcar_notificaciones_leidas() to authenticated;

-- Push con Expo --------------------------------------------------------------

create function public.enviar_push()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_mensajes jsonb;
begin
  select jsonb_agg(
    jsonb_build_object(
      'to', d.token,
      'title', new.titulo,
      'body', new.cuerpo,
      'sound', 'default',
      'channelId', 'default',
      'data', jsonb_build_object(
        'notificacion_id', new.id,
        'url', case when new.trabajo_id is not null then '/trabajo/' || new.trabajo_id else '/notificaciones' end
      )
    )
  )
  into v_mensajes
  from public.dispositivos d
  where d.usuario_id = new.usuario_id;

  if v_mensajes is null then
    return new;
  end if;

  -- Si el envío falla, no se cae lo que disparó la notificación.
  begin
    perform net.http_post(
      url := 'https://exp.host/--/api/v2/push/send',
      body := v_mensajes,
      headers := '{"Content-Type": "application/json", "Accept": "application/json"}'::jsonb
    );
  exception when others then
    raise warning 'No se pudo mandar el push: %', sqlerrm;
  end;
  return new;
end;
$$;

create trigger al_crear_notificacion
  after insert on public.notificaciones
  for each row execute function public.enviar_push();

-- Ayudas ---------------------------------------------------------------------

create function public.notificar(p_usuario uuid, p_tipo text, p_titulo text, p_cuerpo text, p_trabajo uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.notificaciones (usuario_id, tipo, titulo, cuerpo, trabajo_id)
  values (p_usuario, p_tipo, p_titulo, p_cuerpo, p_trabajo)
$$;

-- "$ 180.000"
create function public.pesos(p_valor integer)
returns text
language sql
immutable
set search_path = ''
as $$
  select '$ ' || replace(to_char(p_valor, 'FM999,999,999'), ',', '.')
$$;

-- Primeras palabras de la descripción, para el cuerpo del aviso.
create function public.resumen(p_texto text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case when char_length(p_texto) > 70 then left(p_texto, 67) || '…' else p_texto end
$$;

revoke execute on function public.notificar(uuid, text, text, text, uuid) from public, anon, authenticated;

-- Qué avisa cada cosa ---------------------------------------------------------

-- Trabajo nuevo: a los trabajadores de ese oficio y esa zona, o al invitado si es directo.
create function public.avisar_trabajo_nuevo()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cliente text := coalesce((select nombre from public.perfiles where id = new.cliente_id), 'Un vecino');
begin
  if new.trabajador_invitado_id is not null then
    perform public.notificar(
      new.trabajador_invitado_id, 'pedido_directo',
      v_cliente || ' te pidió presupuesto',
      new.oficio || ' en ' || new.zona || ': ' || public.resumen(new.descripcion),
      new.id
    );
  else
    perform public.notificar(
      p.id, 'trabajo_nuevo',
      'Trabajo nuevo de ' || lower(new.oficio) || ' en ' || new.zona,
      public.resumen(new.descripcion),
      new.id
    )
    from public.perfiles p
    where p.rol = 'trabajador'
      and p.id <> new.cliente_id
      and public.trabajo_coincide_con(new.oficio, new.zona, p.oficios, p.zonas);
  end if;
  return new;
end;
$$;

create trigger avisar_trabajo_nuevo
  after insert on public.trabajos
  for each row when (new.estado = 'abierto')
  execute function public.avisar_trabajo_nuevo();

-- Precio nuevo: al cliente.
create function public.avisar_precio_nuevo()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_trabajo public.trabajos;
  v_trabajador text := coalesce((select nombre from public.perfiles where id = new.trabajador_id), 'Un trabajador');
begin
  select * into v_trabajo from public.trabajos where id = new.trabajo_id;
  perform public.notificar(
    v_trabajo.cliente_id, 'precio_nuevo',
    v_trabajador || ' te pasó precio: ' || public.pesos(new.precio),
    'Para tu trabajo de ' || lower(v_trabajo.oficio) || '. Entrá para ver y elegir.',
    v_trabajo.id
  );
  return new;
end;
$$;

create trigger avisar_precio_nuevo
  after insert on public.postulaciones
  for each row execute function public.avisar_precio_nuevo();

-- Cambios de estado del trabajo.
create function public.avisar_cambio_de_estado()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cliente text := coalesce((select nombre from public.perfiles where id = new.cliente_id), 'El cliente');
  v_trabajador text := coalesce((select nombre from public.perfiles where id = new.trabajador_elegido_id), 'El trabajador');
  v_oficio text := lower(new.oficio);
begin
  if old.estado = 'abierto' and new.estado = 'asignado' then
    perform public.notificar(
      new.trabajador_elegido_id, 'elegido',
      '¡' || v_cliente || ' te eligió!',
      'Para el trabajo de ' || v_oficio || coalesce(' por ' || public.pesos(new.precio_acordado), '')
        || '. Escribile por WhatsApp para coordinar.',
      new.id
    );
    perform public.notificar(
      p.trabajador_id, 'no_elegido',
      v_cliente || ' eligió a otro trabajador',
      'Para el trabajo de ' || v_oficio || '. ¡Seguí pasando precios!',
      new.id
    )
    from public.postulaciones p
    where p.trabajo_id = new.id and p.trabajador_id <> new.trabajador_elegido_id;

  elsif old.estado = 'asignado' and new.estado = 'por_confirmar' then
    perform public.notificar(
      new.cliente_id, 'marcado_terminado',
      v_trabajador || ' terminó el trabajo',
      'Confirmá que el trabajo de ' || v_oficio || ' está terminado.',
      new.id
    );

  elsif old.estado = 'por_confirmar' and new.estado = 'terminado' then
    perform public.notificar(
      new.trabajador_elegido_id, 'confirmado',
      v_cliente || ' confirmó el trabajo',
      '¡Bien ahí! Contá cómo te fue con ' || v_cliente || '.',
      new.id
    );

  elsif old.estado = 'por_confirmar' and new.estado = 'asignado' then
    perform public.notificar(
      new.trabajador_elegido_id, 'rechazado',
      v_cliente || ' dice que todavía no está terminado',
      'Escribile por WhatsApp para ver qué falta.',
      new.id
    );

  elsif new.estado = 'cancelado' and old.estado <> 'cancelado' then
    perform public.notificar(
      p.trabajador_id, 'cancelado',
      v_cliente || ' canceló el trabajo',
      'El trabajo de ' || v_oficio || ' ya no está disponible.',
      new.id
    )
    from public.postulaciones p
    where p.trabajo_id = new.id;
  end if;
  return new;
end;
$$;

create trigger avisar_cambio_de_estado
  after update of estado on public.trabajos
  for each row when (old.estado is distinct from new.estado)
  execute function public.avisar_cambio_de_estado();

-- Calificaciones.
create function public.avisar_opinion()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.notificar(
    new.trabajador_id, 'opinion',
    (select nombre from public.perfiles where id = new.cliente_id) || ' te calificó con ' || new.puntaje || ' ★',
    public.resumen(new.comentario),
    new.trabajo_id
  );
  return new;
end;
$$;

create trigger avisar_opinion
  after insert on public.opiniones
  for each row execute function public.avisar_opinion();

create function public.avisar_calificacion_cliente()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.notificar(
    new.cliente_id, 'calificacion',
    (select nombre from public.perfiles where id = new.trabajador_id) || ' te calificó con ' || new.puntaje || ' ★',
    'Gracias por usar Laburapp.',
    new.trabajo_id
  );
  return new;
end;
$$;

create trigger avisar_calificacion_cliente
  after insert on public.calificaciones_clientes
  for each row execute function public.avisar_calificacion_cliente();

revoke execute on function
  public.enviar_push(),
  public.avisar_trabajo_nuevo(),
  public.avisar_precio_nuevo(),
  public.avisar_cambio_de_estado(),
  public.avisar_opinion(),
  public.avisar_calificacion_cliente()
from public, anon, authenticated;
