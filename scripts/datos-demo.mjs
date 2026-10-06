// =============================================================================
// Datos de demostración para el proyecto de DESARROLLO (nunca producción)
// =============================================================================
// Carga trabajadores y clientes de prueba con foto, servicios, galería,
// trabajos terminados con calificaciones y trabajos abiertos con precios, para
// probar el flujo real en la app. Todo pasa por la API como en la app (con los
// permisos de cada usuario); solo el alta de usuarios se hace por SQL, como el
// seed, para no tener que confirmar mails.
//
// Uso (desde backend/, con el proyecto vinculado con `supabase link`):
//   SUPABASE_URL=https://xxxx.supabase.co SUPABASE_PUBLISHABLE_KEY=sb_publishable_… npm run demo
//
// Todos los usuarios: contraseña laburapp123, mail <usuario>@laburapp.test.
// Se puede correr más de una vez: lo que ya existe no se duplica.

import { execFileSync } from 'node:child_process';
import { readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const URL_SUPABASE = process.env.SUPABASE_URL;
const CLAVE = process.env.SUPABASE_PUBLISHABLE_KEY;
const PROYECTO_PREINSCRIPCION = 'mfunhprdvdabtfolhycy';
const CONTRASENA = 'laburapp123';

// --- Seguridad: solo contra el proyecto de desarrollo vinculado ----------------
const vinculado = readFileSync(new URL('../supabase/.temp/project-ref', import.meta.url), 'utf8').trim();
if (!URL_SUPABASE || !CLAVE) throw new Error('Faltan SUPABASE_URL y SUPABASE_PUBLISHABLE_KEY.');
if (!URL_SUPABASE.includes(vinculado)) throw new Error(`La URL no es la del proyecto vinculado (${vinculado}).`);
if (vinculado === PROYECTO_PREINSCRIPCION) throw new Error('Este es el proyecto de la preinscripción: no se toca.');

// La consulta va en un archivo: pasada como argumento, en Windows el shell la corta en los espacios.
// La CLI a veces tarda en conectar ("request timed out"): se reintenta hasta 3 veces.
function sql(consulta) {
  const archivo = join(tmpdir(), `laburapp-demo-${process.pid}.sql`);
  writeFileSync(archivo, consulta);
  try {
    for (let intento = 1; ; intento++) {
      try {
        const salida = execFileSync(
          'npx',
          ['supabase', 'db', 'query', '--linked', '--agent', 'no', '-o', 'json', '-f', archivo],
          { encoding: 'utf8', shell: process.platform === 'win32', stdio: ['ignore', 'pipe', 'pipe'], timeout: 180_000 },
        );
        const inicio = salida.indexOf('[');
        return inicio >= 0 ? JSON.parse(salida.slice(inicio)) : [];
      } catch (error) {
        if (intento === 3) throw new Error(`SQL falló 3 veces: ${String(error.stderr ?? error.message).slice(0, 300)}`);
        console.log(`  (la base no respondió, reintento ${intento}/2)`);
      }
    }
  } finally {
    rmSync(archivo, { force: true });
  }
}

// fetch con tiempo límite y reintentos (las fotos vienen de servicios externos).
async function traer(url, opciones = {}) {
  for (let intento = 1; ; intento++) {
    try {
      return await fetch(url, { ...opciones, signal: AbortSignal.timeout(30_000) });
    } catch (error) {
      if (intento === 3) throw error;
    }
  }
}

// --- Gente -------------------------------------------------------------------

const trabajadores = [
  { u: 'jorge', nombre: 'Jorge', apellido: 'Medina', sexo: 'varon', oficios: ['Electricidad', 'Gas'], zonas: ['Centro', 'Zona Oeste'], sobre: 'Electricista y gasista matriculado. Hace 20 años que trabajo en San Nicolás.', estrellas: [5, 5, 5, 4, 5, 5] },
  { u: 'andrea', nombre: 'Andrea', apellido: 'Ríos', sexo: 'mujer', oficios: ['Limpieza'], zonas: ['Toda la ciudad'], sobre: 'Limpieza de casas, oficinas y final de obra. Llevo mis productos.', estrellas: [5, 5, 4, 5] },
  { u: 'hugo', nombre: 'Hugo', apellido: 'Ferreyra', sexo: 'varon', oficios: ['Albañilería', 'Pintura'], zonas: ['Zona Norte', 'Zona Oeste'], sobre: 'Albañil. Revoques, contrapisos, cerámicos y arreglos en general.', estrellas: [4, 3, 4] },
  { u: 'pablo', nombre: 'Pablo', apellido: 'Domínguez', sexo: 'varon', oficios: ['Carpintería'], zonas: ['Centro', 'Costanera'], sobre: 'Muebles a medida, placares y arreglo de aberturas de madera.', estrellas: [5, 5, 5] },
  { u: 'mariano', nombre: 'Mariano', apellido: 'Acosta', sexo: 'varon', oficios: ['Herrería'], zonas: ['Zona Sur', 'Alrededores'], sobre: 'Rejas, portones y estructuras. Soldadura en el lugar.', estrellas: [3, 4, 2] },
  { u: 'gustavo', nombre: 'Gustavo', apellido: 'Paredes', sexo: 'varon', oficios: ['Jardinería'], zonas: ['Toda la ciudad', 'Alrededores'], sobre: 'Corte de pasto, poda y mantenimiento de jardines. Tengo cortadora y bordeadora.', estrellas: [5, 4, 5, 5, 5] },
  { u: 'daniel', nombre: 'Daniel', apellido: 'Correa', sexo: 'varon', oficios: ['Fletes'], zonas: ['Toda la ciudad', 'Alrededores'], sobre: 'Fletes y mudanzas chicas con camioneta. Te ayudo a cargar.', estrellas: [4, 5] },
  { u: 'nicolas', nombre: 'Nicolás', apellido: 'Funes', sexo: 'varon', oficios: ['Aire acondicionado', 'Electricidad'], zonas: ['Centro', 'Zona Norte', 'Costanera'], sobre: 'Instalación y service de aires acondicionados. Carga de gas.', estrellas: [5, 5, 4, 5, 5, 4, 5] },
  { u: 'rosa', nombre: 'Rosa', apellido: 'Villalba', sexo: 'mujer', oficios: ['Limpieza', 'Pintura'], zonas: ['Zona Sur', 'Zona Oeste'], sobre: 'Limpieza profunda y pintura de interiores. Responsable y puntual.', estrellas: [5] },
  { u: 'walter', nombre: 'Walter', apellido: 'Ojeda', sexo: 'varon', oficios: ['Plomería', 'Gas'], zonas: ['Zona Oeste', 'Zona Sur'], sobre: 'Plomero. Pérdidas, termotanques y destapaciones.', estrellas: [2, 3] },
  { u: 'esteban', nombre: 'Esteban', apellido: 'Luna', sexo: 'varon', oficios: ['Albañilería'], zonas: ['Toda la ciudad'], sobre: 'Recién empiezo en Laburapp. Hago todo tipo de trabajos de albañilería.', estrellas: [] },
  { u: 'fernando', nombre: 'Fernando', apellido: 'Quiroga', sexo: 'varon', oficios: ['Otro'], otro: 'Techista', zonas: ['Toda la ciudad'], sobre: 'Techista. Membranas, chapas y canaletas. Arreglo goteras.', estrellas: [5, 4] },
];

const clientes = [
  { u: 'silvia', nombre: 'Silvia', apellido: 'Moreno', sexo: 'mujer', oficios: ['Limpieza', 'Pintura', 'Jardinería'], zona: 'Centro' },
  { u: 'roberto', nombre: 'Roberto', apellido: 'Giménez', sexo: 'varon', oficios: ['Electricidad', 'Plomería', 'Albañilería'], zona: 'Zona Norte' },
  { u: 'panaderia', nombre: 'Claudia', apellido: 'Torres', sexo: 'mujer', oficios: ['Aire acondicionado', 'Electricidad', 'Limpieza'], zona: 'Costanera', comercio: true },
  { u: 'laura', nombre: 'Laura', apellido: 'Sánchez', sexo: 'mujer', oficios: ['Herrería', 'Carpintería', 'Pintura'], zona: 'Zona Sur' },
  { u: 'martin', nombre: 'Martín', apellido: 'Herrera', sexo: 'varon', oficios: ['Fletes', 'Albañilería', 'Plomería'], zona: 'Zona Oeste' },
  { u: 'valeria', nombre: 'Valeria', apellido: 'Castro', sexo: 'mujer', oficios: ['Jardinería', 'Herrería', 'Fletes'], zona: 'Alrededores' },
];

const comentarios = {
  5: ['Excelente trabajo, muy prolijo y puntual.', 'Impecable. Lo recomiendo sin dudar.', 'Muy buena atención y precio justo.', 'Resolvió todo en el día. Un genio.', 'Súper responsable, dejó todo limpio.'],
  4: ['Buen trabajo, tardó un poco más de lo previsto.', 'Cumplió con lo que habíamos hablado. Lo volvería a llamar.', 'Bien en general, faltó un detalle que después arregló.'],
  3: ['Quedó bien, pero llegó tarde dos días.', 'El trabajo está bien, la comunicación podría mejorar.'],
  2: ['Tuvo que volver dos veces para terminarlo.', 'Al final cobró más de lo que habíamos acordado.'],
  1: ['No terminó el trabajo como habíamos hablado.'],
};

// Trabajos abiertos (cliente, oficio, descripción, para cuándo, cantidad de fotos).
const abiertos = [
  ['silvia', 'Limpieza', 'Limpieza profunda de un departamento de 2 ambientes antes de mudarme.', 'esta_semana', 2],
  ['silvia', 'Pintura', 'Pintar el balcón y las rejas, unos 15 m2.', 'este_mes', 1],
  ['silvia', 'Jardinería', 'Cortar el pasto y podar dos arbustos del patio.', 'sin_apuro', 0],
  ['roberto', 'Electricidad', 'Instalar un ventilador de techo en el dormitorio.', 'lo_antes_posible', 0],
  ['roberto', 'Plomería', 'Cambiar la canilla de la cocina por una monocomando (ya la compré).', 'esta_semana', 1],
  ['roberto', 'Albañilería', 'Hacer un contrapiso en el patio, 4 x 3 metros.', 'este_mes', 2],
  ['panaderia', 'Aire acondicionado', 'Service del aire del local: limpieza de filtros y carga de gas.', 'lo_antes_posible', 1],
  ['panaderia', 'Electricidad', 'Agregar dos tomas para la heladera nueva del mostrador.', 'esta_semana', 0],
  ['laura', 'Herrería', 'Arreglar la bisagra del portón del garage que se cayó.', 'lo_antes_posible', 2],
  ['laura', 'Carpintería', 'Hacer un placard a medida en el dormitorio, 2 m de ancho.', 'este_mes', 1],
  ['martin', 'Fletes', 'Llevar una heladera y un lavarropas a Zona Norte.', 'esta_semana', 0],
  ['martin', 'Plomería', 'Pierde el inodoro por abajo, hay que cambiar el flexible.', 'lo_antes_posible', 1],
  ['valeria', 'Jardinería', 'Mantenimiento mensual del parque de la quinta (500 m2).', 'sin_apuro', 2],
  ['valeria', 'Herrería', 'Hacer una reja para la ventana del frente, 1,20 x 1 m.', 'este_mes', 1],
  ['valeria', 'Otro', 'Revisar el techo de chapa: hay goteras cuando llueve fuerte.', 'lo_antes_posible', 1],
  // Para que cada trabajador tenga algo en su Inicio:
  ['silvia', 'Gas', 'Conectar una cocina nueva a gas natural.', 'esta_semana', 1],
  ['martin', 'Electricidad', 'Cambiar el tablero viejo por uno con disyuntor.', 'este_mes', 1],
  ['panaderia', 'Carpintería', 'Hacer estantes de madera para exhibir el pan, 3 metros.', 'este_mes', 2],
  ['laura', 'Limpieza', 'Limpieza de fin de obra después de pintar toda la casa.', 'esta_semana', 1],
  ['roberto', 'Otro', 'Cambiar dos chapas del techo del galpón y la canaleta.', 'lo_antes_posible', 2],
];

// --- API ---------------------------------------------------------------------

const sesiones = new Map();
async function sesion(u) {
  if (sesiones.has(u)) return sesiones.get(u);
  const r = await fetch(`${URL_SUPABASE}/auth/v1/token?grant_type=password`, {
    method: 'POST',
    headers: { apikey: CLAVE, 'Content-Type': 'application/json' },
    body: JSON.stringify({ email: `${u}@laburapp.test`, password: CONTRASENA }),
  });
  const j = await r.json();
  if (!j.access_token) throw new Error(`No pude entrar como ${u}: ${JSON.stringify(j)}`);
  const s = { token: j.access_token, id: j.user.id };
  sesiones.set(u, s);
  return s;
}

async function api(u, metodo, ruta, cuerpo) {
  const s = await sesion(u);
  const r = await fetch(`${URL_SUPABASE}/rest/v1/${ruta}`, {
    method: metodo,
    headers: { apikey: CLAVE, Authorization: `Bearer ${s.token}`, 'Content-Type': 'application/json', Prefer: 'return=representation' },
    body: cuerpo ? JSON.stringify(cuerpo) : undefined,
  });
  const t = await r.text();
  if (!r.ok) throw new Error(`${u} ${metodo} ${ruta}: ${r.status} ${t}`);
  return t ? JSON.parse(t) : null;
}

async function subirImagen(u, bucket, ruta, urlImagen) {
  const s = await sesion(u);
  const img = await traer(urlImagen);
  if (!img.ok) throw new Error(`No pude bajar ${urlImagen}`);
  const r = await fetch(`${URL_SUPABASE}/storage/v1/object/${bucket}/${ruta}`, {
    method: 'POST',
    headers: { apikey: CLAVE, Authorization: `Bearer ${s.token}`, 'Content-Type': img.headers.get('content-type') ?? 'image/jpeg' },
    body: Buffer.from(await img.arrayBuffer()),
  });
  // Si ya estaba (de una corrida anterior), se usa la que hay: Storage no deja pisar archivos.
  if (!r.ok) {
    const texto = await r.text();
    if (!/Duplicate|already exists/i.test(texto)) throw new Error(`No pude subir ${ruta}: ${r.status} ${texto}`);
  }
  return ruta;
}

const avatar = (semilla) => `https://api.dicebear.com/9.x/avataaars/png?seed=${encodeURIComponent(semilla)}&size=256&backgroundColor=e3f1f2`;
const foto = (semilla, ancho = 1000, alto = 750) => `https://picsum.photos/seed/${encodeURIComponent(semilla)}/${ancho}/${alto}`;
const elegir = (lista, i) => lista[i % lista.length];

// Misma regla que trabajo_coincide_con() en la base.
function coincide(oficio, zona, t) {
  return t.oficios.includes(oficio) && (t.zonas.includes(zona) || (t.zonas.includes('Toda la ciudad') && zona !== 'Alrededores'));
}

// --- 1. Usuarios (SQL, como el seed) -------------------------------------------

function crearUsuarios() {
  const filas = [
    ...trabajadores.map((t, i) => ({
      email: `${t.u}@laburapp.test`,
      datos: { rol: 'trabajador', nombre: t.nombre, apellido: t.apellido, sexo: t.sexo, whatsapp: `33640010${String(i).padStart(2, '0')}`, oficios: t.oficios, oficio_otro: t.otro ?? null, zonas: t.zonas, alias_pago: `demo.trabajador${i}`, titular_pago: `${t.nombre} ${t.apellido}` },
    })),
    ...clientes.map((c, i) => ({
      email: `${c.u}@laburapp.test`,
      datos: { rol: 'cliente', nombre: c.nombre, apellido: c.apellido, sexo: c.sexo, whatsapp: `33640020${String(i).padStart(2, '0')}`, oficios: c.oficios, zonas: [c.zona], es_comercio: Boolean(c.comercio) },
    })),
  ];
  const valores = filas.map((f) => `('${f.email}', '${JSON.stringify(f.datos).replaceAll("'", "''")}'::jsonb)`).join(',\n');
  sql(`
    with nuevos_datos (email, datos) as (values ${valores}),
    nuevos as (
      insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
        raw_app_meta_data, raw_user_meta_data, created_at, updated_at, confirmation_token, email_change, email_change_token_new, recovery_token)
      select '00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated', n.email,
        extensions.crypt('${CONTRASENA}', extensions.gen_salt('bf')), now(),
        '{"provider":"email","providers":["email"]}', n.datos, now(), now(), '', '', '', ''
      from nuevos_datos n
      where not exists (select 1 from auth.users u where u.email = n.email)
      returning id, email
    )
    insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
    select gen_random_uuid(), id, id::text, jsonb_build_object('sub', id::text, 'email', email, 'email_verified', true), 'email', now(), now(), now()
    from nuevos;
  `);
  console.log(`Usuarios: ${filas.length} (los que ya existían no se tocaron)`);
}

// --- 2. Perfiles: foto, sobre mí, servicios y galería --------------------------

async function completarPerfiles() {
  for (const p of [...trabajadores, ...clientes]) {
    const s = await sesion(p.u);
    const [perfil] = await api(p.u, 'GET', `perfiles?id=eq.${s.id}&select=foto_path`);
    if (!perfil.foto_path) {
      const ruta = await subirImagen(p.u, 'perfiles', `${s.id}/avatar-demo.png`, avatar(p.u));
      await api(p.u, 'PATCH', `perfiles?id=eq.${s.id}`, { foto_path: ruta, sobre_mi: p.sobre ?? null });
    }
  }
  for (const [i, t] of trabajadores.entries()) {
    const s = await sesion(t.u);
    const servicios = await api(t.u, 'GET', `servicios?trabajador_id=eq.${s.id}&select=id`);
    if (servicios.length === 0) {
      const oficio = t.oficios[0];
      const fotos = [];
      for (let n = 0; n < 3; n++) fotos.push(await subirImagen(t.u, 'perfiles', `${s.id}/servicios/demo-${n}.jpg`, foto(`${t.u}-servicio-${n}`)));
      await api(t.u, 'POST', 'servicios', {
        oficio,
        titulo: `${oficio === 'Otro' ? t.otro : oficio} en ${t.zonas[0] === 'Toda la ciudad' ? 'toda la ciudad' : t.zonas.join(' y ')}`,
        descripcion: t.sobre,
        precio_desde: [8000, 12000, 15000, 20000, 25000][i % 5],
        precio_unidad: ['visita', 'hora', 'trabajo', 'dia', 'm2'][i % 5],
        zonas: t.zonas,
        fotos,
      });
    }
    const galeria = await api(t.u, 'GET', `galeria?trabajador_id=eq.${s.id}&select=id`);
    if (galeria.length === 0) {
      for (let n = 0; n < 3; n++) {
        const ruta = await subirImagen(t.u, 'perfiles', `${s.id}/galeria/demo-${n}.jpg`, foto(`${t.u}-galeria-${n}`, 900, 900));
        await api(t.u, 'POST', 'galeria', { foto_path: ruta });
      }
    }
  }
  console.log('Perfiles completos: fotos, sobre mí, servicios y galerías');
}

// --- 3. Trabajos terminados y calificados (flujo completo) ---------------------

async function calificaciones() {
  let k = 0;
  for (const t of trabajadores) {
    const s = await sesion(t.u);
    const ya = await api(t.u, 'GET', `opiniones?trabajador_id=eq.${s.id}&select=id`);
    for (const estrellas of t.estrellas.slice(ya.length)) {
      const c = elegir(clientes, k++);
      const oficio = t.oficios[0];
      const [trabajo] = await api(c.u, 'POST', 'trabajos', {
        oficio,
        descripcion: `Trabajo de ${(oficio === 'Otro' ? t.otro : oficio).toLowerCase()} en mi casa.`,
        zona: c.zona,
        para_cuando: 'esta_semana',
        trabajador_invitado_id: s.id,
      });
      const [precio] = await api(t.u, 'POST', 'postulaciones', { trabajo_id: trabajo.id, precio: 20000 + (k % 6) * 15000 });
      await api(c.u, 'POST', 'rpc/elegir_postulacion', { p_postulacion_id: precio.id });
      await api(t.u, 'POST', 'rpc/marcar_terminado', { p_trabajo_id: trabajo.id });
      await api(c.u, 'POST', 'rpc/confirmar_terminado', { p_trabajo_id: trabajo.id });
      await api(c.u, 'POST', 'opiniones', { trabajo_id: trabajo.id, trabajador_id: s.id, puntaje: estrellas, comentario: elegir(comentarios[estrellas], k) });
      await api(t.u, 'POST', 'calificaciones_clientes', { trabajo_id: trabajo.id, cliente_id: (await sesion(c.u)).id, puntaje: estrellas >= 3 ? 5 : 4 });
    }
  }
  console.log(`Trabajos terminados y calificados: ${k}`);
}

// --- 4. Trabajos abiertos con fotos y precios ------------------------------------

async function trabajosAbiertos() {
  let creados = 0;
  for (const [i, [cu, oficio, descripcion, para_cuando, cantidadFotos]] of abiertos.entries()) {
    const c = clientes.find((x) => x.u === cu);
    const s = await sesion(cu);
    const yaEsta = await api(cu, 'GET', `trabajos?cliente_id=eq.${s.id}&descripcion=eq.${encodeURIComponent(descripcion)}&select=id`);
    if (yaEsta.length) continue;
    const fotos = [];
    for (let n = 0; n < cantidadFotos; n++) fotos.push(await subirImagen(cu, 'fotos-trabajos', `${s.id}/demo-abierto-${i}-${n}.jpg`, foto(`${cu}-abierto-${i}-${n}`)));
    const [trabajo] = await api(cu, 'POST', 'trabajos', { oficio, descripcion, zona: c.zona, para_cuando, fotos });
    creados++;
    // Hasta 3 trabajadores que coinciden le pasan precio (no a todos, para que haya de los dos).
    const interesados = trabajadores.filter((t) => coincide(oficio, c.zona, t)).slice(0, i % 4);
    for (const [j, t] of interesados.entries()) {
      await api(t.u, 'POST', 'postulaciones', {
        trabajo_id: trabajo.id,
        precio: 18000 + j * 7000 + (i % 3) * 5000,
        mensaje: elegir(['Puedo ir mañana a la tarde.', 'Incluye materiales.', 'Paso a ver y te confirmo.', null], i + j),
      });
    }
  }
  console.log(`Trabajos abiertos nuevos: ${creados}`);
}

// --- Correr ---------------------------------------------------------------------

// Mientras se cargan los datos, los teléfonos registrados no reciben avisos (si
// no, llegarían decenas). Se guardan en un archivo por si algo falla a mitad de
// camino; igual, la app vuelve a registrar el teléfono al abrirse.
const respaldo = join(tmpdir(), 'laburapp-demo-dispositivos.json');
const dispositivos = sql('select token, usuario_id, plataforma from dispositivos');
writeFileSync(respaldo, JSON.stringify(dispositivos));
sql('delete from dispositivos');
let fallo = null;
try {
  crearUsuarios();
  await completarPerfiles();
  await calificaciones();
  await trabajosAbiertos();
} catch (error) {
  fallo = error;
  console.error('Falló la carga:', error.message);
}
const valores = dispositivos
  .map((d) => `('${d.token}', '${d.usuario_id}', '${d.plataforma}')`)
  .join(', ');
if (valores) {
  sql(`insert into dispositivos (token, usuario_id, plataforma) values ${valores} on conflict (token) do nothing`);
}
rmSync(respaldo, { force: true });
console.log(`Teléfonos registrados restaurados: ${dispositivos.length}`);
// Fechas repartidas en el tiempo: si todo es de hoy, los clientes de prueba
// llegan al límite diario de trabajos y no se puede probar publicar.
sql(readFileSync(new URL('./repartir-fechas.sql', import.meta.url), 'utf8'));
console.log('Fechas repartidas en las últimas semanas');
// Los avisos de la carga quedan como leídos para no llenar la campanita.
sql(`update notificaciones set leida = true where not leida and usuario_id in (select id from auth.users where email like '%@laburapp.test')`);
if (fallo) process.exit(1);
console.log('Listo.');
