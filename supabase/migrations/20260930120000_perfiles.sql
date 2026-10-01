-- =============================================================================
-- Perfiles de usuario (cliente o trabajador)
-- =============================================================================
-- El perfil se crea solo, con un trigger, cuando alguien se registra: la app
-- manda los datos en los metadatos del alta (supabase.auth.signUp). Así funciona
-- aunque el proyecto pida confirmar el mail (todavía no hay sesión).
--
-- Los datos se separan en dos tablas:
--   perfiles        → lo que ven los demás usuarios (nombre, oficios, zonas).
--   datos_privados  → WhatsApp y sexo. Solo los ve el dueño; el WhatsApp de la
--                     otra parte se obtiene con contacto_del_trabajo() cuando
--                     el cliente elige a un trabajador.

-- Catálogos (los mismos de la preinscripción y de la app) ---------------------

create function public.oficios_validos()
returns text[]
language sql
immutable
parallel safe
set search_path = ''
as $$
  select array[
    'Pintura', 'Electricidad', 'Plomería', 'Gas', 'Albañilería', 'Carpintería',
    'Herrería', 'Jardinería', 'Limpieza', 'Fletes', 'Aire acondicionado', 'Otro'
  ]
$$;

-- Zonas de un trabajo o de un cliente. El trabajador además puede elegir
-- 'Toda la ciudad', que cubre todas menos 'Alrededores'.
create function public.zonas_validas()
returns text[]
language sql
immutable
parallel safe
set search_path = ''
as $$
  select array['Centro', 'Zona Norte', 'Zona Sur', 'Zona Oeste', 'Costanera', 'Alrededores']
$$;

-- Actualiza updated_at en cada cambio.
create function public.tocar_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- Perfiles (públicos para usuarios con sesión) ------------------------------

create table public.perfiles (
  id uuid primary key references auth.users (id) on delete cascade,
  rol text not null check (rol in ('cliente', 'trabajador')),
  nombre text not null check (char_length(nombre) between 2 and 60),
  apellido text not null check (char_length(apellido) between 2 and 60),
  -- Trabajador: los oficios que hace. Cliente: los rubros que le interesan.
  oficios text[] not null check (oficios <@ public.oficios_validos()),
  oficio_otro text check (char_length(oficio_otro) between 2 and 60),
  -- Trabajador: una o varias (o 'Toda la ciudad'). Cliente: una sola.
  zonas text[] not null check (zonas <@ (public.zonas_validas() || 'Toda la ciudad'::text)),
  es_comercio boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint perfiles_oficios check (cardinality(oficios) > 0),
  constraint perfiles_zonas check (
    (rol = 'trabajador' and cardinality(zonas) > 0)
    or (rol = 'cliente' and cardinality(zonas) = 1 and not ('Toda la ciudad' = any (zonas)))
  ),
  constraint perfiles_otro check (('Otro' = any (oficios)) = (oficio_otro is not null)),
  constraint perfiles_comercio check (rol = 'cliente' or not es_comercio)
);

comment on table public.perfiles is 'Datos públicos de cada usuario. Se crea con el trigger al_crear_usuario.';

create index perfiles_trabajadores_oficios on public.perfiles using gin (oficios) where rol = 'trabajador';

create trigger perfiles_updated_at
  before update on public.perfiles
  for each row execute function public.tocar_updated_at();

alter table public.perfiles enable row level security;

create policy "Usuarios con sesión ven los perfiles"
  on public.perfiles for select
  to authenticated
  using (true);

create policy "Cada uno edita su perfil"
  on public.perfiles for update
  to authenticated
  using ((select auth.uid()) = id)
  with check ((select auth.uid()) = id);

-- Nadie inserta ni borra desde la app, y el rol no se cambia.
revoke insert, update, delete on public.perfiles from anon, authenticated;
grant update (nombre, apellido, oficios, oficio_otro, zonas, es_comercio) on public.perfiles to authenticated;

-- Datos privados (solo el dueño) ---------------------------------------------

create table public.datos_privados (
  id uuid primary key references public.perfiles (id) on delete cascade,
  -- Sin +54, sin 0 y sin 15: 10 u 11 dígitos.
  whatsapp text not null check (whatsapp ~ '^[0-9]{10,11}$'),
  sexo text not null check (sexo in ('mujer', 'varon', 'otro', 'prefiero_no_decir')),
  updated_at timestamptz not null default now()
);

comment on table public.datos_privados is 'WhatsApp y sexo. Solo los ve el dueño.';

create trigger datos_privados_updated_at
  before update on public.datos_privados
  for each row execute function public.tocar_updated_at();

alter table public.datos_privados enable row level security;

create policy "Cada uno ve sus datos privados"
  on public.datos_privados for select
  to authenticated
  using ((select auth.uid()) = id);

create policy "Cada uno edita sus datos privados"
  on public.datos_privados for update
  to authenticated
  using ((select auth.uid()) = id)
  with check ((select auth.uid()) = id);

revoke all on public.datos_privados from anon;
revoke insert, update, delete on public.datos_privados from authenticated;
grant update (whatsapp, sexo) on public.datos_privados to authenticated;

-- Rol del usuario actual (para usar en políticas) ---------------------------

create function public.mi_rol()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select rol from public.perfiles where id = (select auth.uid())
$$;

revoke execute on function public.mi_rol() from public, anon;
grant execute on function public.mi_rol() to authenticated;

-- Alta automática a partir de los metadatos del registro ---------------------
-- Si algún dato no cumple las reglas, falla y el registro no se completa.

create function public.crear_perfil_nuevo_usuario()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  datos jsonb := new.raw_user_meta_data;
begin
  insert into public.perfiles (id, rol, nombre, apellido, oficios, oficio_otro, zonas, es_comercio)
  values (
    new.id,
    datos ->> 'rol',
    trim(datos ->> 'nombre'),
    trim(datos ->> 'apellido'),
    coalesce(array(select jsonb_array_elements_text(datos -> 'oficios')), '{}'),
    nullif(trim(datos ->> 'oficio_otro'), ''),
    coalesce(array(select jsonb_array_elements_text(datos -> 'zonas')), '{}'),
    coalesce((datos ->> 'es_comercio')::boolean, false)
  );

  insert into public.datos_privados (id, whatsapp, sexo)
  values (new.id, datos ->> 'whatsapp', datos ->> 'sexo');

  return new;
end;
$$;

revoke execute on function public.crear_perfil_nuevo_usuario() from public, anon, authenticated;

create trigger al_crear_usuario
  after insert on auth.users
  for each row execute function public.crear_perfil_nuevo_usuario();
