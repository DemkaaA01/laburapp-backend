-- =============================================================================
-- Chat dentro de la app
-- =============================================================================
-- Una conversación por trabajo y trabajador: entre el cliente y quien le pasó
-- precio, fue invitado a un pedido directo o fue elegido. Solo la ven y
-- escriben esos dos. Si hay bloqueo o el trabajo se canceló, queda para leer.
-- Cada mensaje manda un push al otro (no va a la campanita: tiene su propio
-- contador de no leídos).

create table public.conversaciones (
  id uuid primary key default gen_random_uuid(),
  trabajo_id uuid not null references public.trabajos (id) on delete cascade,
  cliente_id uuid not null references public.perfiles (id) on delete cascade,
  trabajador_id uuid not null references public.perfiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  ultimo_mensaje_at timestamptz,
  constraint conversaciones_una_por_trabajador unique (trabajo_id, trabajador_id)
);

comment on table public.conversaciones is 'Chat entre el cliente y un trabajador sobre un trabajo. Se crea con abrir_conversacion().';

create index conversaciones_cliente on public.conversaciones (cliente_id, ultimo_mensaje_at desc nulls last);
create index conversaciones_trabajador on public.conversaciones (trabajador_id, ultimo_mensaje_at desc nulls last);

create table public.mensajes (
  id uuid primary key default gen_random_uuid(),
  conversacion_id uuid not null references public.conversaciones (id) on delete cascade,
  autor_id uuid not null default auth.uid() references public.perfiles (id) on delete cascade,
  texto text not null check (char_length(trim(texto)) between 1 and 1000),
  -- clock_timestamp: dos mensajes en la misma transacción quedan en orden.
  created_at timestamptz not null default clock_timestamp(),
  leido_at timestamptz
);

comment on table public.mensajes is 'Mensajes del chat. leido_at lo marca quien los recibe con marcar_mensajes_leidos().';

create index mensajes_conversacion on public.mensajes (conversacion_id, created_at desc);
create index mensajes_no_leidos on public.mensajes (conversacion_id) where leido_at is null;

-- ¿Este usuario participa de la conversación?
create function privado.participo_de(p_conversacion uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.conversaciones
    where id = p_conversacion and (select auth.uid()) in (cliente_id, trabajador_id)
  )
$$;

-- ¿Se puede escribir? Participa, no hay bloqueo y el trabajo no está cancelado.
create function privado.puedo_escribir(p_conversacion uuid)
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
      and t.estado <> 'cancelado'
      and not privado.hay_bloqueo(c.cliente_id, c.trabajador_id)
  )
$$;

alter table public.conversaciones enable row level security;
alter table public.mensajes enable row level security;

create policy "Ver mis conversaciones"
  on public.conversaciones for select to authenticated
  using ((select auth.uid()) in (cliente_id, trabajador_id));

create policy "Ver los mensajes de mis conversaciones"
  on public.mensajes for select to authenticated
  using (privado.participo_de(conversacion_id));

create policy "Escribir en mis conversaciones"
  on public.mensajes for insert to authenticated
  with check (autor_id = (select auth.uid()) and privado.puedo_escribir(conversacion_id));

revoke all on public.conversaciones, public.mensajes from anon;
revoke insert, update, delete on public.conversaciones, public.mensajes from authenticated;
grant insert (conversacion_id, texto) on public.mensajes to authenticated;

-- Abrir (o encontrar) la conversación de un trabajo con un trabajador.
-- El cliente la abre con cualquier trabajador relacionado con su trabajo; el
-- trabajador, solo la suya.
create function public.abrir_conversacion(p_trabajo_id uuid, p_trabajador_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_yo uuid := (select auth.uid());
  v_trabajo public.trabajos;
  v_id uuid;
begin
  select * into v_trabajo from public.trabajos where id = p_trabajo_id;
  if not found or v_yo not in (v_trabajo.cliente_id, p_trabajador_id) then
    raise exception 'No podés chatear sobre este trabajo.' using errcode = '42501';
  end if;
  -- coalesce: sin elegido o sin invitado, "=" da null y "not null" dejaría pasar a cualquiera.
  if not coalesce(
    v_trabajo.trabajador_elegido_id = p_trabajador_id
    or v_trabajo.trabajador_invitado_id = p_trabajador_id
    or exists (select 1 from public.postulaciones where trabajo_id = p_trabajo_id and trabajador_id = p_trabajador_id),
    false
  ) then
    raise exception 'El chat se abre cuando el trabajador pasa precio o le piden presupuesto.' using errcode = '42501';
  end if;
  if privado.hay_bloqueo(v_trabajo.cliente_id, p_trabajador_id) then
    raise exception 'No podés chatear con esta persona.' using errcode = '42501';
  end if;

  insert into public.conversaciones (trabajo_id, cliente_id, trabajador_id)
  values (p_trabajo_id, v_trabajo.cliente_id, p_trabajador_id)
  on conflict (trabajo_id, trabajador_id) do nothing;

  select id into v_id from public.conversaciones where trabajo_id = p_trabajo_id and trabajador_id = p_trabajador_id;
  return v_id;
end;
$$;

create function public.marcar_mensajes_leidos(p_conversacion uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.mensajes
  set leido_at = now()
  where conversacion_id = p_conversacion
    and leido_at is null
    and autor_id <> (select auth.uid())
    and privado.participo_de(p_conversacion)
$$;

-- Lista de chats con el otro, el trabajo, el último mensaje y los no leídos.
create function public.mis_conversaciones()
returns table (
  id uuid,
  trabajo_id uuid,
  oficio text,
  otro_id uuid,
  otro_nombre text,
  otro_apellido text,
  otro_foto text,
  ultimo_texto text,
  ultimo_es_mio boolean,
  ultimo_at timestamptz,
  no_leidos integer,
  puedo_escribir boolean
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    c.id, c.trabajo_id, t.oficio, o.id, o.nombre, o.apellido, o.foto_path,
    u.texto, u.autor_id = (select auth.uid()), coalesce(u.created_at, c.created_at),
    (select count(*)::integer from public.mensajes m
       where m.conversacion_id = c.id and m.leido_at is null and m.autor_id <> (select auth.uid())),
    privado.puedo_escribir(c.id)
  from public.conversaciones c
  join public.trabajos t on t.id = c.trabajo_id
  join public.perfiles o on o.id = case when c.cliente_id = (select auth.uid()) then c.trabajador_id else c.cliente_id end
  left join lateral (
    select m.texto, m.autor_id, m.created_at from public.mensajes m
    where m.conversacion_id = c.id order by m.created_at desc limit 1
  ) u on true
  where (select auth.uid()) in (c.cliente_id, c.trabajador_id)
  order by coalesce(u.created_at, c.created_at) desc
$$;

create function public.mensajes_sin_leer()
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::integer
  from public.mensajes m
  join public.conversaciones c on c.id = m.conversacion_id
  where (select auth.uid()) in (c.cliente_id, c.trabajador_id)
    and m.autor_id <> (select auth.uid())
    and m.leido_at is null
$$;

revoke execute on function
  public.abrir_conversacion(uuid, uuid),
  public.marcar_mensajes_leidos(uuid),
  public.mis_conversaciones(),
  public.mensajes_sin_leer()
from public, anon;
grant execute on function
  public.abrir_conversacion(uuid, uuid),
  public.marcar_mensajes_leidos(uuid),
  public.mis_conversaciones(),
  public.mensajes_sin_leer()
to authenticated;

-- Push y orden de la lista al llegar un mensaje -------------------------------

-- Manda un push a los teléfonos de un usuario (sin pasar por la campanita).
create function privado.mandar_push(p_usuario uuid, p_titulo text, p_cuerpo text, p_datos jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_mensajes jsonb;
begin
  select jsonb_agg(jsonb_build_object(
    'to', d.token, 'title', p_titulo, 'body', p_cuerpo, 'sound', 'default', 'channelId', 'default', 'data', p_datos
  ))
  into v_mensajes
  from public.dispositivos d
  where d.usuario_id = p_usuario;

  if v_mensajes is null then
    return;
  end if;
  begin
    perform net.http_post(
      url := 'https://exp.host/--/api/v2/push/send',
      body := v_mensajes,
      headers := '{"Content-Type": "application/json", "Accept": "application/json"}'::jsonb
    );
  exception when others then
    raise warning 'No se pudo mandar el push: %', sqlerrm;
  end;
end;
$$;

create function privado.al_llegar_mensaje()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_conversacion public.conversaciones;
  v_destino uuid;
begin
  select * into v_conversacion from public.conversaciones where id = new.conversacion_id;
  update public.conversaciones set ultimo_mensaje_at = new.created_at where id = new.conversacion_id;
  v_destino := case when new.autor_id = v_conversacion.cliente_id then v_conversacion.trabajador_id else v_conversacion.cliente_id end;
  perform privado.mandar_push(
    v_destino,
    coalesce((select nombre from public.perfiles where id = new.autor_id), 'Laburapp'),
    public.resumen(new.texto),
    jsonb_build_object('url', '/chat/' || new.conversacion_id)
  );
  return new;
end;
$$;

create trigger al_llegar_mensaje
  after insert on public.mensajes
  for each row execute function privado.al_llegar_mensaje();

-- Anti-spam: hasta 60 mensajes cada 10 minutos (solo usuarios de la app).
create function privado.limite_mensajes()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  perform privado.limitar(
    (select count(*) from public.mensajes where autor_id = new.autor_id and created_at > now() - interval '10 minutes'),
    60, 'Mandaste muchos mensajes seguidos. Esperá unos minutos.'
  );
  return new;
end;
$$;

create trigger limite_mensajes
  before insert on public.mensajes
  for each row execute function privado.limite_mensajes();

revoke execute on all functions in schema privado from public, anon;
grant execute on all functions in schema privado to authenticated;

-- Realtime: los mensajes llegan al instante (respeta las reglas de arriba).
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.mensajes;
  end if;
end
$$;
