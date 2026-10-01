-- =============================================================================
-- Datos de prueba (SOLO desarrollo)
-- =============================================================================
-- Se cargan con `supabase db reset` (local). Nunca en producción.
-- Todos los usuarios tienen la contraseña: laburapp123
--
--   Clientes:     marta@laburapp.test (Centro), kiosco@laburapp.test (Zona Norte, comercio)
--   Trabajadores: carlos@laburapp.test (Pintura, Albañilería · Centro, Zona Sur)
--                 lucia@laburapp.test  (Electricidad · Toda la ciudad)
--                 ramon@laburapp.test  (Plomería, Gas · Zona Norte, Centro)
--                 sergio@laburapp.test (Pintura, Otro: techista · Alrededores)

-- Usuarios (el trigger al_crear_usuario crea perfiles y datos_privados) --------

with usuarios (id, email, datos) as (
  values
    ('11111111-1111-4111-8111-111111111111'::uuid, 'marta@laburapp.test',
     '{"rol":"cliente","nombre":"Marta","apellido":"Gómez","whatsapp":"3364111111","sexo":"mujer","oficios":["Pintura","Electricidad","Plomería"],"zonas":["Centro"],"es_comercio":false}'::jsonb),
    ('22222222-2222-4222-8222-222222222222'::uuid, 'kiosco@laburapp.test',
     '{"rol":"cliente","nombre":"Diego","apellido":"Fernández","whatsapp":"3364222222","sexo":"varon","oficios":["Electricidad","Gas","Aire acondicionado"],"zonas":["Zona Norte"],"es_comercio":true}'::jsonb),
    ('33333333-3333-4333-8333-333333333333'::uuid, 'carlos@laburapp.test',
     '{"rol":"trabajador","nombre":"Carlos","apellido":"Ruiz","whatsapp":"3364333333","sexo":"varon","oficios":["Pintura","Albañilería"],"zonas":["Centro","Zona Sur"]}'::jsonb),
    ('44444444-4444-4444-8444-444444444444'::uuid, 'lucia@laburapp.test',
     '{"rol":"trabajador","nombre":"Lucía","apellido":"Benítez","whatsapp":"3364444444","sexo":"mujer","oficios":["Electricidad"],"zonas":["Toda la ciudad"]}'::jsonb),
    ('55555555-5555-4555-8555-555555555555'::uuid, 'ramon@laburapp.test',
     '{"rol":"trabajador","nombre":"Ramón","apellido":"Sosa","whatsapp":"3364555555","sexo":"varon","oficios":["Plomería","Gas"],"zonas":["Zona Norte","Centro"]}'::jsonb),
    ('66666666-6666-4666-8666-666666666666'::uuid, 'sergio@laburapp.test',
     '{"rol":"trabajador","nombre":"Sergio","apellido":"Paz","whatsapp":"3364666666","sexo":"prefiero_no_decir","oficios":["Pintura","Otro"],"oficio_otro":"Techista","zonas":["Alrededores"]}'::jsonb)
),
nuevos as (
  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, email_change, email_change_token_new, recovery_token
  )
  select
    '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated', email,
    extensions.crypt('laburapp123', extensions.gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}', datos, now(), now(),
    '', '', '', ''
  from usuarios
  returning id, email
)
insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
select gen_random_uuid(), id, id::text, jsonb_build_object('sub', id::text, 'email', email, 'email_verified', true),
  'email', now(), now(), now()
from nuevos;

-- Trabajos, uno en cada estado ------------------------------------------------

insert into public.trabajos (id, cliente_id, oficio, descripcion, zona, para_cuando, estado, created_at)
values
  ('a0000000-0000-4000-8000-000000000001', '11111111-1111-4111-8111-111111111111', 'Pintura',
   'Pintar living y comedor, unos 40 m2 de pared. Ya tengo la pintura.', 'Centro', 'esta_semana', 'abierto', now() - interval '2 hours'),
  ('a0000000-0000-4000-8000-000000000002', '11111111-1111-4111-8111-111111111111', 'Electricidad',
   'Se corta la luz cuando prendo el horno eléctrico. Revisar tablero.', 'Centro', 'lo_antes_posible', 'abierto', now() - interval '1 day'),
  ('a0000000-0000-4000-8000-000000000003', '22222222-2222-4222-8222-222222222222', 'Gas',
   'Instalar un calefactor tiro balanceado en el kiosco.', 'Zona Norte', 'este_mes', 'abierto', now() - interval '3 days'),
  ('a0000000-0000-4000-8000-000000000004', '11111111-1111-4111-8111-111111111111', 'Plomería',
   'Pierde agua la canilla de la cocina y el sifón del lavadero.', 'Centro', 'lo_antes_posible', 'abierto', now() - interval '10 days'),
  ('a0000000-0000-4000-8000-000000000005', '22222222-2222-4222-8222-222222222222', 'Electricidad',
   'Cambiar 6 tubos fluorescentes por paneles LED en el local.', 'Zona Norte', 'sin_apuro', 'abierto', now() - interval '20 days'),
  ('a0000000-0000-4000-8000-000000000006', '11111111-1111-4111-8111-111111111111', 'Albañilería',
   'Revocar una pared del patio que se está descascarando, 3 x 2 metros.', 'Centro', 'sin_apuro', 'abierto', now() - interval '7 days');

insert into public.postulaciones (trabajo_id, trabajador_id, precio, mensaje)
values
  ('a0000000-0000-4000-8000-000000000001', '33333333-3333-4333-8333-333333333333', 180000, 'Lo hago en dos días, incluye enduido de detalles.'),
  ('a0000000-0000-4000-8000-000000000002', '44444444-4444-4444-8444-444444444444', 25000, 'Paso a revisar mañana a la tarde.'),
  ('a0000000-0000-4000-8000-000000000004', '55555555-5555-4555-8555-555555555555', 30000, 'Llevo repuestos.'),
  ('a0000000-0000-4000-8000-000000000005', '44444444-4444-4444-8444-444444444444', 60000, null),
  ('a0000000-0000-4000-8000-000000000006', '33333333-3333-4333-8333-333333333333', 90000, 'Incluye materiales.');

-- Plomería de Marta: asignado a Ramón.
update public.trabajos
set estado = 'asignado', trabajador_elegido_id = '55555555-5555-4555-8555-555555555555',
    precio_acordado = 30000, asignado_at = now() - interval '9 days'
where id = 'a0000000-0000-4000-8000-000000000004';

-- Revoque de Marta: Carlos lo marcó como terminado, falta que Marta confirme.
update public.trabajos
set estado = 'por_confirmar', trabajador_elegido_id = '33333333-3333-4333-8333-333333333333',
    precio_acordado = 90000, asignado_at = now() - interval '6 days', marcado_terminado_at = now() - interval '1 day'
where id = 'a0000000-0000-4000-8000-000000000006';

-- LED del kiosco: terminado por Lucía, calificados los dos.
update public.trabajos
set estado = 'terminado', trabajador_elegido_id = '44444444-4444-4444-8444-444444444444',
    precio_acordado = 60000, asignado_at = now() - interval '19 days', terminado_at = now() - interval '15 days'
where id = 'a0000000-0000-4000-8000-000000000005';

insert into public.opiniones (trabajo_id, cliente_id, trabajador_id, puntaje, comentario)
values ('a0000000-0000-4000-8000-000000000005', '22222222-2222-4222-8222-222222222222',
        '44444444-4444-4444-8444-444444444444', 5, 'Muy prolija y puntual. La recomiendo.');

insert into public.calificaciones_clientes (trabajo_id, trabajador_id, cliente_id, puntaje)
values ('a0000000-0000-4000-8000-000000000005', '44444444-4444-4444-8444-444444444444',
        '22222222-2222-4222-8222-222222222222', 5);

-- Servicios publicados por trabajadores.
insert into public.servicios (trabajador_id, oficio, titulo, descripcion, precio_desde, precio_unidad, zonas)
values
  ('33333333-3333-4333-8333-333333333333', 'Pintura', 'Pintura de interiores y frentes',
   'Pinto livings, dormitorios, cocinas y frentes. Enduido, lijado y dos manos. Dejo todo limpio.', 3500, 'm2', '{Centro,Zona Sur}'),
  ('44444444-4444-4444-8444-444444444444', 'Electricidad', 'Electricista matriculada',
   'Instalaciones nuevas, tableros, disyuntores, cambio de luminarias a LED. Presupuesto sin cargo.', 15000, 'visita', '{Toda la ciudad}'),
  ('55555555-5555-4555-8555-555555555555', 'Plomería', 'Plomería y destapaciones',
   'Pérdidas, canillas, sifones, termotanques y destapaciones. Voy en el día.', null, null, '{Zona Norte,Centro}');
