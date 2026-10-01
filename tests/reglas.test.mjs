// Tests de las reglas de la base (RLS, permisos y funciones).
// Corren con PGlite (Postgres en Node), sin Docker: `npm test`.
// Cada test arranca de los datos de supabase/seed.sql y deshace sus cambios.

import { PGlite } from '@electric-sql/pglite';
import { pgcrypto } from '@electric-sql/pglite/contrib/pgcrypto';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import { after, before, beforeEach, afterEach, describe, test } from 'node:test';

const leer = (ruta) => readFileSync(new URL(ruta, import.meta.url), 'utf8');

const MARTA = '11111111-1111-4111-8111-111111111111'; // cliente, Centro
const DIEGO = '22222222-2222-4222-8222-222222222222'; // cliente, Zona Norte
const CARLOS = '33333333-3333-4333-8333-333333333333'; // Pintura, Albañilería · Centro, Zona Sur
const LUCIA = '44444444-4444-4444-8444-444444444444'; // Electricidad · Toda la ciudad
const RAMON = '55555555-5555-4555-8555-555555555555'; // Plomería, Gas · Zona Norte, Centro
const SERGIO = '66666666-6666-4666-8666-666666666666'; // Pintura, Otro · Alrededores

const PINTURA_MARTA = 'a0000000-0000-4000-8000-000000000001';
const ELECTRICIDAD_MARTA = 'a0000000-0000-4000-8000-000000000002';
const GAS_DIEGO = 'a0000000-0000-4000-8000-000000000003';
const PLOMERIA_MARTA_ASIGNADO = 'a0000000-0000-4000-8000-000000000004';
const LED_DIEGO_TERMINADO = 'a0000000-0000-4000-8000-000000000005';
const REVOQUE_MARTA_POR_CONFIRMAR = 'a0000000-0000-4000-8000-000000000006';

let db;

before(async () => {
  db = await PGlite.create({ extensions: { pgcrypto } });
  await db.exec(leer('./supabase-simulado.sql'));
  const carpeta = new URL('../supabase/migrations/', import.meta.url);
  for (const archivo of readdirSync(carpeta).sort()) {
    await db.exec(readFileSync(new URL(archivo, carpeta), 'utf8'));
  }
  await db.exec(leer('../supabase/seed.sql'));
});

after(() => db.close());

beforeEach(() => db.exec('begin'));
afterEach(() => db.exec('rollback'));

// Actúa como un usuario con sesión (o como anónimo si no hay id).
async function como(usuarioId) {
  await db.exec('reset role');
  await db.query(`select set_config('request.jwt.claims', $1, true)`, [
    JSON.stringify(usuarioId ? { sub: usuarioId, role: 'authenticated' } : { role: 'anon' }),
  ]);
  await db.exec(`set local role ${usuarioId ? 'authenticated' : 'anon'}`);
}

async function filas(sql, params = []) {
  return (await db.query(sql, params)).rows;
}

// Espera que la consulta falle; usa un savepoint para seguir usando la transacción.
async function falla(sql, params = [], patron = /./) {
  await db.exec('savepoint intento');
  try {
    await db.query(sql, params);
  } catch (error) {
    await db.exec('rollback to savepoint intento');
    assert.match(error.message, patron);
    return;
  }
  await db.exec('release savepoint intento');
  assert.fail(`Se esperaba un error y no hubo: ${sql}`);
}

function registrar(datos) {
  return db.query(`insert into auth.users (id, email, raw_user_meta_data) values (gen_random_uuid(), $1, $2)`, [
    `${Math.random().toString(36).slice(2)}@laburapp.test`,
    datos,
  ]);
}

const TRABAJADOR_OK = {
  rol: 'trabajador',
  nombre: 'Ana',
  apellido: 'López',
  whatsapp: '3364999999',
  sexo: 'mujer',
  oficios: ['Limpieza'],
  zonas: ['Centro'],
};

describe('registro y perfiles', () => {
  test('los datos de prueba crean perfiles y datos privados', async () => {
    const [{ perfiles, privados }] = await filas(
      `select (select count(*) from perfiles)::int as perfiles, (select count(*) from datos_privados)::int as privados`,
    );
    assert.equal(perfiles, 6);
    assert.equal(privados, 6);
  });

  test('un registro válido crea el perfil', async () => {
    await registrar(TRABAJADOR_OK);
    const [p] = await filas(`select nombre, rol from perfiles where nombre = 'Ana'`);
    assert.deepEqual(p, { nombre: 'Ana', rol: 'trabajador' });
  });

  test('un registro con WhatsApp mal escrito no se completa', async () => {
    await falla(`insert into auth.users (id, email, raw_user_meta_data) values (gen_random_uuid(), 'x@laburapp.test', $1)`, [
      { ...TRABAJADOR_OK, whatsapp: '0336154123456' },
    ], /datos_privados_whatsapp_check/);
  });

  test('un cliente no puede elegir "Toda la ciudad"', async () => {
    await falla(`insert into auth.users (id, email, raw_user_meta_data) values (gen_random_uuid(), 'y@laburapp.test', $1)`, [
      { ...TRABAJADOR_OK, rol: 'cliente', zonas: ['Toda la ciudad'] },
    ], /perfiles_zonas/);
  });

  test('"Otro" exige decir cuál', async () => {
    await falla(`insert into auth.users (id, email, raw_user_meta_data) values (gen_random_uuid(), 'z@laburapp.test', $1)`, [
      { ...TRABAJADOR_OK, oficios: ['Otro'] },
    ], /perfiles_otro/);
  });

  test('sin sesión no se ve nada', async () => {
    await como(null);
    assert.equal((await filas('select * from perfiles')).length, 0);
    await falla('select * from datos_privados', [], /permission denied/);
    await falla('select * from reputacion_trabajadores', [], /permission denied/);
  });

  test('con sesión se ven todos los perfiles, pero solo los datos privados propios', async () => {
    await como(MARTA);
    assert.equal((await filas('select id from perfiles')).length, 6);
    const privados = await filas('select id, whatsapp from datos_privados');
    assert.deepEqual(privados, [{ id: MARTA, whatsapp: '3364111111' }]);
  });

  test('cada uno edita su perfil, pero no el rol ni el de otro', async () => {
    await como(MARTA);
    await db.query(`update perfiles set nombre = 'Martita' where id = $1`, [MARTA]);
    assert.equal((await filas(`select nombre from perfiles where id = $1`, [MARTA]))[0].nombre, 'Martita');

    const { affectedRows } = await db.query(`update perfiles set nombre = 'Hackeado' where id = $1`, [CARLOS]);
    assert.equal(affectedRows, 0);

    await falla(`update perfiles set rol = 'trabajador' where id = $1`, [MARTA], /permission denied/);
  });
});

describe('trabajos', () => {
  const PUBLICAR = `insert into trabajos (oficio, descripcion, zona, para_cuando) values ($1, $2, $3, $4) returning *`;

  test('el cliente publica un trabajo a su nombre', async () => {
    await como(MARTA);
    const [t] = await filas(PUBLICAR, ['Jardinería', 'Cortar el pasto del fondo, unos 100 m2.', 'Centro', 'sin_apuro']);
    assert.equal(t.cliente_id, MARTA);
    assert.equal(t.estado, 'abierto');
  });

  test('un trabajador no puede publicar trabajos', async () => {
    await como(CARLOS);
    await falla(PUBLICAR, ['Pintura', 'Pintar una reja de 3 metros.', 'Centro', 'sin_apuro'], /row-level security/);
  });

  test('no se puede publicar a nombre de otro ni ya asignado', async () => {
    await como(MARTA);
    await falla(
      `insert into trabajos (cliente_id, oficio, descripcion, zona, para_cuando) values ($1, 'Gas', 'Revisar pérdida de gas.', 'Centro', 'lo_antes_posible')`,
      [DIEGO],
      /permission denied/,
    );
    await falla(
      `insert into trabajos (oficio, descripcion, zona, para_cuando, estado) values ('Gas', 'Revisar pérdida de gas.', 'Centro', 'lo_antes_posible', 'terminado')`,
      [],
      /permission denied/,
    );
  });

  test('no se puede cambiar el estado a mano', async () => {
    await como(MARTA);
    await falla(`update trabajos set estado = 'terminado' where id = $1`, [PINTURA_MARTA], /permission denied/);
  });

  test('un cliente no ve los trabajos de otro cliente', async () => {
    await como(DIEGO);
    const ids = (await filas('select id from trabajos')).map((t) => t.id).sort();
    assert.deepEqual(ids, [GAS_DIEGO, LED_DIEGO_TERMINADO]);
  });

  test('cada trabajador ve los trabajos abiertos de sus oficios y zonas', async () => {
    const paraMi = async (quien) => {
      await como(quien);
      return (await filas('select id from trabajos_para_mi()')).map((t) => t.id).sort();
    };
    assert.deepEqual(await paraMi(CARLOS), [PINTURA_MARTA]);
    assert.deepEqual(await paraMi(LUCIA), [ELECTRICIDAD_MARTA]); // "Toda la ciudad" incluye Centro
    assert.deepEqual(await paraMi(RAMON), [GAS_DIEGO]);
    assert.deepEqual(await paraMi(SERGIO), []); // Alrededores no está en ninguno
    assert.deepEqual(await paraMi(MARTA), []); // un cliente no recibe trabajos
  });
});

describe('postulaciones', () => {
  const POSTULAR = `insert into postulaciones (trabajo_id, precio, mensaje) values ($1, $2, $3) returning *`;

  test('un trabajador se postula a un trabajo de su oficio y zona', async () => {
    await como(RAMON);
    const [p] = await filas(POSTULAR, [GAS_DIEGO, 45000, 'Voy el jueves.']);
    assert.equal(p.trabajador_id, RAMON);
  });

  test('no se puede postular fuera de su oficio o su zona', async () => {
    await como(CARLOS);
    await falla(POSTULAR, [ELECTRICIDAD_MARTA, 10000, null], /row-level security/);
    await como(SERGIO); // Pintura, pero en Alrededores
    await falla(POSTULAR, [PINTURA_MARTA, 10000, null], /row-level security/);
  });

  test('no se puede postular dos veces ni a un trabajo que no está abierto', async () => {
    await como(CARLOS);
    await falla(POSTULAR, [PINTURA_MARTA, 150000, null], /postulaciones_una_por_trabajo/);
    await como(LUCIA);
    await falla(POSTULAR, [LED_DIEGO_TERMINADO, 50000, null], /row-level security/);
  });

  test('un cliente no puede postularse', async () => {
    await como(DIEGO);
    await falla(POSTULAR, [PINTURA_MARTA, 1000, null], /row-level security/);
  });

  test('el cliente ve las postulaciones de su trabajo; otros trabajadores no', async () => {
    await como(MARTA);
    assert.equal((await filas('select * from postulaciones where trabajo_id = $1', [PINTURA_MARTA])).length, 1);
    await como(LUCIA);
    assert.equal((await filas('select * from postulaciones where trabajo_id = $1', [PINTURA_MARTA])).length, 0);
    await como(DIEGO);
    assert.equal((await filas('select * from postulaciones where trabajo_id = $1', [PINTURA_MARTA])).length, 0);
  });

  test('el trabajador cambia o retira su precio mientras el trabajo está abierto', async () => {
    await como(CARLOS);
    await db.query('update postulaciones set precio = 170000 where trabajo_id = $1', [PINTURA_MARTA]);
    assert.equal((await filas('select precio from postulaciones where trabajo_id = $1', [PINTURA_MARTA]))[0].precio, 170000);

    await como(RAMON); // trabajo de plomería ya asignado
    const { affectedRows } = await db.query('update postulaciones set precio = 1 where trabajo_id = $1', [
      PLOMERIA_MARTA_ASIGNADO,
    ]);
    assert.equal(affectedRows, 0);
  });
});

describe('elegir, contacto, terminar y cancelar', () => {
  const postulacionDe = async (trabajoId, trabajadorId) => {
    await db.exec('reset role');
    const [p] = await filas('select id from postulaciones where trabajo_id = $1 and trabajador_id = $2', [
      trabajoId,
      trabajadorId,
    ]);
    return p.id;
  };

  test('el cliente elige una postulación y el trabajo queda asignado', async () => {
    const id = await postulacionDe(PINTURA_MARTA, CARLOS);
    await como(MARTA);
    const [t] = await filas('select * from elegir_postulacion($1)', [id]);
    assert.equal(t.estado, 'asignado');
    assert.equal(t.trabajador_elegido_id, CARLOS);
    assert.equal(t.precio_acordado, 180000);
    await falla('select elegir_postulacion($1)', [id], /ya no está abierto/);
  });

  test('otro usuario no puede elegir en un trabajo ajeno', async () => {
    const id = await postulacionDe(PINTURA_MARTA, CARLOS);
    await como(DIEGO);
    await falla('select elegir_postulacion($1)', [id], /Solo quien publicó/);
    await como(CARLOS);
    await falla('select elegir_postulacion($1)', [id], /Solo quien publicó/);
  });

  test('el WhatsApp de la otra parte se ve solo después de elegir', async () => {
    await como(MARTA);
    await falla('select * from contacto_del_trabajo($1)', [PINTURA_MARTA], /cuando el cliente elige/);

    const [contacto] = await filas('select * from contacto_del_trabajo($1)', [PLOMERIA_MARTA_ASIGNADO]);
    assert.deepEqual(contacto, { nombre: 'Ramón', apellido: 'Sosa', whatsapp: '3364555555' });

    await como(RAMON);
    const [cliente] = await filas('select * from contacto_del_trabajo($1)', [PLOMERIA_MARTA_ASIGNADO]);
    assert.equal(cliente.whatsapp, '3364111111');

    await como(LUCIA);
    await falla('select * from contacto_del_trabajo($1)', [PLOMERIA_MARTA_ASIGNADO], /No participás/);
  });

  test('el trabajador marca terminado y el cliente confirma', async () => {
    await como(MARTA); // el cliente no puede marcarlo por el trabajador
    await falla('select marcar_terminado($1)', [PLOMERIA_MARTA_ASIGNADO], /Solo el trabajador elegido/);
    await como(CARLOS); // otro trabajador tampoco
    await falla('select marcar_terminado($1)', [PLOMERIA_MARTA_ASIGNADO], /Solo el trabajador elegido/);

    await como(RAMON);
    const [marcado] = await filas('select * from marcar_terminado($1)', [PLOMERIA_MARTA_ASIGNADO]);
    assert.equal(marcado.estado, 'por_confirmar');
    await falla('select confirmar_terminado($1)', [PLOMERIA_MARTA_ASIGNADO], /Solo quien publicó/);

    await como(MARTA);
    const [t] = await filas('select * from confirmar_terminado($1)', [PLOMERIA_MARTA_ASIGNADO]);
    assert.equal(t.estado, 'terminado');
  });

  test('el cliente no confirma lo que el trabajador no marcó, y puede rechazarlo', async () => {
    await como(MARTA);
    await falla('select confirmar_terminado($1)', [PLOMERIA_MARTA_ASIGNADO], /todavía no marcó/);

    const [t] = await filas('select * from rechazar_terminado($1)', [REVOQUE_MARTA_POR_CONFIRMAR]);
    assert.equal(t.estado, 'asignado');
    assert.equal(t.marcado_terminado_at, null);
    await falla('select confirmar_terminado($1)', [REVOQUE_MARTA_POR_CONFIRMAR], /todavía no marcó/);
  });

  test('mientras espera confirmación, los dos siguen viendo el contacto', async () => {
    await como(CARLOS);
    const [cliente] = await filas('select * from contacto_del_trabajo($1)', [REVOQUE_MARTA_POR_CONFIRMAR]);
    assert.equal(cliente.nombre, 'Marta');
  });

  test('el cliente cancela su trabajo; nadie más puede', async () => {
    await como(LUCIA);
    await falla('select cancelar_trabajo($1)', [ELECTRICIDAD_MARTA], /Solo quien publicó/);
    await como(MARTA);
    const [t] = await filas('select * from cancelar_trabajo($1)', [ELECTRICIDAD_MARTA]);
    assert.equal(t.estado, 'cancelado');
    await falla('select cancelar_trabajo($1)', [ELECTRICIDAD_MARTA], /ya no se puede cancelar/);
  });

  test('sin sesión no se pueden usar las funciones', async () => {
    await como(null);
    await falla('select * from trabajos_para_mi()', [], /permission denied/);
    await falla('select * from contacto_del_trabajo($1)', [PLOMERIA_MARTA_ASIGNADO], /permission denied/);
  });
});

describe('calificaciones y recomendados', () => {
  const OPINAR = `insert into opiniones (trabajo_id, trabajador_id, puntaje, comentario) values ($1, $2, $3, $4)`;
  const CALIFICAR_CLIENTE = `insert into calificaciones_clientes (trabajo_id, cliente_id, puntaje) values ($1, $2, $3)`;

  const terminarRevoque = async () => {
    await db.exec('reset role');
    await db.query(`update trabajos set estado = 'terminado', terminado_at = now() where id = $1`, [
      REVOQUE_MARTA_POR_CONFIRMAR,
    ]);
  };

  test('el cliente opina una sola vez, con estrellas y descripción, cuando el trabajo está terminado', async () => {
    await como(MARTA);
    await falla(OPINAR, [REVOQUE_MARTA_POR_CONFIRMAR, CARLOS, 5, 'Excelente trabajo'], /row-level security/); // falta confirmar
    await terminarRevoque();
    await como(MARTA);
    await falla(OPINAR, [REVOQUE_MARTA_POR_CONFIRMAR, RAMON, 1, 'No fue él quien lo hizo'], /row-level security/);
    await falla(OPINAR, [REVOQUE_MARTA_POR_CONFIRMAR, CARLOS, 5, null], /null value|not-null/);
    await falla(OPINAR, [REVOQUE_MARTA_POR_CONFIRMAR, CARLOS, 6, 'Más de cinco estrellas'], /opiniones_puntaje_check/);
    await db.query(OPINAR, [REVOQUE_MARTA_POR_CONFIRMAR, CARLOS, 4, 'Muy prolijo, dejó todo limpio.']);
    await falla(OPINAR, [REVOQUE_MARTA_POR_CONFIRMAR, CARLOS, 5, 'Quiero opinar otra vez'], /opiniones_trabajo_id_key/);
  });

  test('el trabajador califica al cliente solo con estrellas, una vez', async () => {
    await como(CARLOS);
    await falla(CALIFICAR_CLIENTE, [REVOQUE_MARTA_POR_CONFIRMAR, MARTA, 5], /row-level security/); // falta confirmar
    await terminarRevoque();
    await como(CARLOS);
    await falla(CALIFICAR_CLIENTE, [REVOQUE_MARTA_POR_CONFIRMAR, DIEGO, 1], /row-level security/); // otro cliente
    await db.query(CALIFICAR_CLIENTE, [REVOQUE_MARTA_POR_CONFIRMAR, MARTA, 5]);
    await falla(CALIFICAR_CLIENTE, [REVOQUE_MARTA_POR_CONFIRMAR, MARTA, 4], /calificaciones_clientes_trabajo_id_key/);
    await falla(
      `insert into calificaciones_clientes (trabajo_id, cliente_id, puntaje, trabajador_id) values ($1, $2, 5, $3)`,
      [LED_DIEGO_TERMINADO, DIEGO, CARLOS],
      /permission denied/,
    );
  });

  test('solo el trabajador elegido califica al cliente', async () => {
    await terminarRevoque();
    await como(LUCIA);
    await falla(CALIFICAR_CLIENTE, [REVOQUE_MARTA_POR_CONFIRMAR, MARTA, 1], /row-level security/);
    await como(MARTA); // el cliente no se califica a sí mismo
    await falla(CALIFICAR_CLIENTE, [REVOQUE_MARTA_POR_CONFIRMAR, MARTA, 5], /row-level security/);
  });

  test('nadie opina sobre trabajos ajenos ni cambia calificaciones', async () => {
    await como(MARTA);
    await falla(OPINAR, [LED_DIEGO_TERMINADO, LUCIA, 1, 'No fue mi trabajo'], /row-level security|opiniones_trabajo_id_key/);
    await como(DIEGO);
    await falla(`update opiniones set puntaje = 1`, [], /permission denied/);
    await falla(`delete from opiniones`, [], /permission denied/);
    await como(LUCIA);
    await falla(`update calificaciones_clientes set puntaje = 1`, [], /permission denied/);
  });

  test('la reputación de trabajadores y clientes se calcula de las calificaciones', async () => {
    await como(MARTA);
    const [lucia] = await filas('select * from reputacion_trabajadores where trabajador_id = $1', [LUCIA]);
    assert.equal(lucia.cantidad_opiniones, 1);
    assert.equal(Number(lucia.promedio), 5);
    const [diego] = await filas('select * from reputacion_clientes where cliente_id = $1', [DIEGO]);
    assert.equal(diego.cantidad_calificaciones, 1);
    assert.equal(Number(diego.promedio), 5);
  });

  test('al cliente le recomendamos trabajadores de sus rubros y su zona, mejor puntuados primero', async () => {
    await como(MARTA); // Pintura, Electricidad, Plomería · Centro
    const marta = (await filas('select nombre from trabajadores_recomendados()')).map((t) => t.nombre);
    assert.deepEqual(marta, ['Lucía', 'Carlos', 'Ramón']);

    await como(DIEGO); // Electricidad, Gas, Aire acondicionado · Zona Norte
    const diego = (await filas('select nombre from trabajadores_recomendados()')).map((t) => t.nombre);
    assert.deepEqual(diego, ['Lucía', 'Ramón']);

    await como(CARLOS); // un trabajador no recibe recomendaciones
    assert.equal((await filas('select * from trabajadores_recomendados()')).length, 0);
  });
});

describe('foto de perfil, sobre mí y galería', () => {
  const SUMAR = `insert into galeria (foto_path) values ($1) returning *`;

  test('cada uno pone su foto y su "sobre mí", solo de su carpeta', async () => {
    await como(CARLOS);
    await db.query(`update perfiles set foto_path = $1, sobre_mi = 'Pinto casas hace 15 años.' where id = $2`, [
      `${CARLOS}/avatar.jpg`,
      CARLOS,
    ]);
    const [p] = await filas('select foto_path, sobre_mi from perfiles where id = $1', [CARLOS]);
    assert.equal(p.sobre_mi, 'Pinto casas hace 15 años.');
    await falla(`update perfiles set foto_path = $1 where id = $2`, [`${LUCIA}/robada.jpg`, CARLOS], /perfiles_foto_propia/);
  });

  test('el trabajador suma fotos a su galería y todos con sesión las ven', async () => {
    await como(CARLOS);
    const [foto] = await filas(SUMAR, [`${CARLOS}/galeria/frente.jpg`]);
    assert.equal(foto.trabajador_id, CARLOS);
    await como(MARTA);
    assert.equal((await filas('select * from galeria where trabajador_id = $1', [CARLOS])).length, 1);
    await como(null);
    await falla('select * from galeria', [], /permission denied/);
  });

  test('un cliente no tiene galería y nadie sube fotos ajenas', async () => {
    await como(MARTA);
    await falla(SUMAR, [`${MARTA}/galeria/x.jpg`], /row-level security/);
    await como(CARLOS);
    await falla(SUMAR, [`${LUCIA}/galeria/x.jpg`], /galeria_foto_propia/);
  });

  test('la galería tiene hasta 12 fotos', async () => {
    await como(CARLOS);
    for (let i = 0; i < 12; i++) await db.query(SUMAR, [`${CARLOS}/galeria/${i}.jpg`]);
    await falla(SUMAR, [`${CARLOS}/galeria/13.jpg`], /row-level security/);
  });

  test('cada uno borra solo sus fotos', async () => {
    await como(CARLOS);
    const [foto] = await filas(SUMAR, [`${CARLOS}/galeria/a.jpg`]);
    await como(LUCIA);
    assert.equal((await db.query('delete from galeria where id = $1', [foto.id])).affectedRows, 0);
    await como(CARLOS);
    assert.equal((await db.query('delete from galeria where id = $1', [foto.id])).affectedRows, 1);
  });

  test('en storage, cada uno sube solo a su carpeta de perfiles', async () => {
    await como(CARLOS);
    await db.query(`insert into storage.objects (bucket_id, name) values ('perfiles', $1)`, [`${CARLOS}/avatar.jpg`]);
    await falla(`insert into storage.objects (bucket_id, name) values ('perfiles', $1)`, [`${LUCIA}/avatar.jpg`], /row-level security/);
  });
});

describe('servicios y pedidos directos', () => {
  const PUBLICAR_SERVICIO = `insert into servicios (oficio, titulo, descripcion, precio_desde, precio_unidad, zonas)
    values ($1, 'Pintura de interiores', 'Pinto livings, dormitorios y cocinas. Trabajo prolijo.', 3500, 'm2', $2) returning *`;
  const PEDIR = `insert into trabajos (oficio, descripcion, zona, para_cuando, trabajador_invitado_id, servicio_id)
    values ('Pintura', 'Pintar el dormitorio, 12 m2.', 'Centro', 'sin_apuro', $1, $2) returning *`;

  async function servicioDeCarlos() {
    await como(CARLOS);
    const [s] = await filas(PUBLICAR_SERVICIO, ['Pintura', ['Centro', 'Zona Sur']]);
    return s;
  }

  test('el trabajador publica servicios solo de sus oficios', async () => {
    const s = await servicioDeCarlos();
    assert.equal(s.trabajador_id, CARLOS);
    await falla(PUBLICAR_SERVICIO, ['Gas', ['Centro']], /row-level security/); // Carlos no hace gas
    await como(MARTA); // un cliente no publica servicios
    await falla(PUBLICAR_SERVICIO, ['Pintura', ['Centro']], /row-level security/);
  });

  test('el servicio tiene que tener precio de referencia', async () => {
    await como(CARLOS);
    await falla(
      `insert into servicios (oficio, titulo, descripcion, zonas) values ('Pintura', 'Pintura general', 'Pinto todo tipo de ambientes.', '{Centro}')`,
      [],
      /servicios_con_precio/,
    );
  });

  test('precio: los dos datos o ninguno', async () => {
    await como(CARLOS);
    await falla(
      `insert into servicios (oficio, titulo, descripcion, precio_desde, zonas) values ('Pintura', 'Pintura general', 'Pinto todo tipo de ambientes.', 1000, '{Centro}')`,
      [],
      /servicios_(con_)?precio/,
    );
  });

  test('hasta 10 servicios por trabajador', async () => {
    await como(CARLOS);
    const [{ ya }] = await filas('select count(*)::int as ya from servicios where trabajador_id = $1', [CARLOS]);
    for (let i = ya; i < 10; i++) await db.query(PUBLICAR_SERVICIO, ['Pintura', ['Centro']]);
    await falla(PUBLICAR_SERVICIO, ['Pintura', ['Centro']], /row-level security/);
  });

  test('los clientes ven los servicios activos que llegan a su zona; pausados solo el dueño', async () => {
    const s = await servicioDeCarlos();
    const ids = async (sql) => (await filas(sql)).map((x) => x.id);
    await como(MARTA); // Centro
    assert.ok((await ids('select id from servicios_para_mi()')).includes(s.id));
    assert.ok(!(await ids(`select id from servicios_para_mi('Electricidad')`)).includes(s.id));
    await como(DIEGO); // Zona Norte: no le llega
    assert.ok(!(await ids('select id from servicios_para_mi()')).includes(s.id));

    await como(CARLOS);
    await db.query('update servicios set activo = false where id = $1', [s.id]);
    assert.equal((await filas('select id from servicios where id = $1', [s.id])).length, 1);
    await como(MARTA);
    assert.equal((await filas('select id from servicios where id = $1', [s.id])).length, 0);
  });

  test('nadie edita ni borra servicios ajenos', async () => {
    const s = await servicioDeCarlos();
    await como(LUCIA);
    assert.equal((await db.query(`update servicios set titulo = 'Trucho' where id = $1`, [s.id])).affectedRows, 0);
    assert.equal((await db.query('delete from servicios where id = $1', [s.id])).affectedRows, 0);
  });

  test('el pedido directo lo ven solo el cliente y el trabajador invitado', async () => {
    const s = await servicioDeCarlos();
    await como(MARTA);
    const [t] = await filas(PEDIR, [CARLOS, s.id]);
    assert.equal(t.trabajador_invitado_id, CARLOS);

    await como(CARLOS);
    const paraCarlos = (await filas('select id from trabajos_para_mi()')).map((x) => x.id);
    assert.equal(paraCarlos[0], t.id); // el pedido directo va primero
    await como(SERGIO); // también hace pintura, pero no se lo pidieron a él
    assert.equal((await filas('select id from trabajos where id = $1', [t.id])).length, 0);
    assert.ok(!(await filas('select id from trabajos_para_mi()')).some((x) => x.id === t.id));
  });

  test('en un pedido directo solo pasa precio el invitado, aunque no sea de su zona', async () => {
    const s = await servicioDeCarlos();
    await como(MARTA);
    const [t] = await filas(
      `insert into trabajos (oficio, descripcion, zona, para_cuando, trabajador_invitado_id, servicio_id)
       values ('Pintura', 'Pintar la reja del frente.', 'Costanera', 'sin_apuro', $1, $2) returning id`,
      [CARLOS, s.id],
    );
    await como(SERGIO);
    await falla(`insert into postulaciones (trabajo_id, precio) values ($1, 5000)`, [t.id], /row-level security/);
    await como(CARLOS); // Costanera no es su zona, pero se lo pidieron a él
    await db.query(`insert into postulaciones (trabajo_id, precio) values ($1, 45000)`, [t.id]);
  });

  test('no se puede invitar a un cliente ni con un servicio ajeno o pausado', async () => {
    const s = await servicioDeCarlos();
    await como(MARTA);
    await falla(PEDIR, [DIEGO, null], /row-level security/);
    await falla(PEDIR, [LUCIA, s.id], /row-level security/); // el servicio es de Carlos
    await como(CARLOS);
    await db.query('update servicios set activo = false where id = $1', [s.id]);
    await como(MARTA);
    await falla(PEDIR, [CARLOS, s.id], /row-level security/);
  });
});

describe('notificaciones y push', () => {
  const TOKEN_CARLOS = 'ExponentPushToken[carlos-iphone]';
  const avisos = async (usuario, tipo) => {
    await db.exec('reset role');
    return filas('select * from notificaciones where usuario_id = $1 and tipo = $2 order by created_at', [usuario, tipo]);
  };
  const publicar = async (quien, oficio, zona, extra = {}) => {
    await como(quien);
    const [t] = await filas(
      `insert into trabajos (oficio, descripcion, zona, para_cuando, trabajador_invitado_id)
       values ($1, 'Trabajo de prueba para avisos.', $2, 'sin_apuro', $3) returning *`,
      [oficio, zona, extra.invitado ?? null],
    );
    return t;
  };

  test('trabajo nuevo: avisa a los trabajadores de ese oficio y esa zona', async () => {
    const t = await publicar(MARTA, 'Pintura', 'Centro');
    assert.equal((await avisos(CARLOS, 'trabajo_nuevo')).filter((n) => n.trabajo_id === t.id).length, 1);
    assert.equal((await avisos(SERGIO, 'trabajo_nuevo')).filter((n) => n.trabajo_id === t.id).length, 0); // Alrededores
    assert.equal((await avisos(LUCIA, 'trabajo_nuevo')).filter((n) => n.trabajo_id === t.id).length, 0); // otro oficio
  });

  test('pedido directo: avisa solo al invitado', async () => {
    const t = await publicar(MARTA, 'Pintura', 'Centro', { invitado: CARLOS });
    const [n] = (await avisos(CARLOS, 'pedido_directo')).filter((x) => x.trabajo_id === t.id);
    assert.equal(n.titulo, 'Marta te pidió presupuesto');
    assert.equal((await avisos(CARLOS, 'trabajo_nuevo')).filter((x) => x.trabajo_id === t.id).length, 0);
  });

  test('precio nuevo: avisa al cliente con el precio', async () => {
    await como(RAMON);
    await db.query(`insert into postulaciones (trabajo_id, precio) values ($1, 45000)`, [GAS_DIEGO]);
    const [n] = (await avisos(DIEGO, 'precio_nuevo')).filter((x) => x.trabajo_id === GAS_DIEGO);
    assert.equal(n.titulo, 'Ramón te pasó precio: $ 45.000');
  });

  test('elegir: avisa al elegido y a los que no eligieron', async () => {
    await db.query(`insert into postulaciones (trabajo_id, trabajador_id, precio) values ($1, $2, 200000)`, [
      PINTURA_MARTA,
      SERGIO,
    ]);
    const id = (await filas('select id from postulaciones where trabajo_id = $1 and trabajador_id = $2', [PINTURA_MARTA, CARLOS]))[0].id;
    await como(MARTA);
    await db.query('select elegir_postulacion($1)', [id]);
    const [elegido] = await avisos(CARLOS, 'elegido');
    assert.equal(elegido.titulo, '¡Marta te eligió!');
    assert.match(elegido.cuerpo, /\$ 180\.000/);
    assert.equal((await avisos(SERGIO, 'no_elegido')).length, 1);
  });

  test('terminado: avisa al cliente; confirmado o rechazado: al trabajador', async () => {
    await como(RAMON);
    await db.query('select marcar_terminado($1)', [PLOMERIA_MARTA_ASIGNADO]);
    assert.equal((await avisos(MARTA, 'marcado_terminado')).length, 1);
    await como(MARTA);
    await db.query('select rechazar_terminado($1)', [PLOMERIA_MARTA_ASIGNADO]);
    assert.equal((await avisos(RAMON, 'rechazado')).length, 1);
    await como(RAMON);
    await db.query('select marcar_terminado($1)', [PLOMERIA_MARTA_ASIGNADO]);
    await como(MARTA);
    await db.query('select confirmar_terminado($1)', [PLOMERIA_MARTA_ASIGNADO]);
    assert.equal((await avisos(RAMON, 'confirmado')).length, 1);
  });

  test('cancelar: avisa a los que pasaron precio', async () => {
    await como(MARTA);
    await db.query('select cancelar_trabajo($1)', [ELECTRICIDAD_MARTA]);
    assert.equal((await avisos(LUCIA, 'cancelado')).length, 1);
  });

  test('calificaciones: avisa a quien recibe las estrellas', async () => {
    await db.exec('reset role');
    await db.query(`update trabajos set estado = 'terminado' where id = $1`, [REVOQUE_MARTA_POR_CONFIRMAR]);
    await como(MARTA);
    await db.query(`insert into opiniones (trabajo_id, trabajador_id, puntaje, comentario) values ($1, $2, 5, 'Excelente trabajo, muy prolijo.')`, [
      REVOQUE_MARTA_POR_CONFIRMAR,
      CARLOS,
    ]);
    assert.equal((await avisos(CARLOS, 'opinion'))[0].titulo, 'Marta te calificó con 5 ★');
    await como(CARLOS);
    await db.query(`insert into calificaciones_clientes (trabajo_id, cliente_id, puntaje) values ($1, $2, 4)`, [
      REVOQUE_MARTA_POR_CONFIRMAR,
      MARTA,
    ]);
    assert.equal((await avisos(MARTA, 'calificacion'))[0].titulo, 'Carlos te calificó con 4 ★');
  });

  test('cada uno ve y marca solo las suyas, y no puede inventar ni cambiar el texto', async () => {
    await publicar(MARTA, 'Pintura', 'Centro');
    await como(LUCIA);
    assert.equal((await filas('select * from notificaciones where usuario_id = $1', [CARLOS])).length, 0);
    await como(CARLOS);
    const mias = await filas('select id from notificaciones');
    assert.ok(mias.length > 0);
    await db.query('select marcar_notificaciones_leidas()');
    assert.equal((await filas('select id from notificaciones where not leida')).length, 0);
    await falla(`update notificaciones set titulo = 'Trucho'`, [], /permission denied/);
    await falla(
      `insert into notificaciones (usuario_id, tipo, titulo, cuerpo) values ($1, 'x', 'x', 'x')`,
      [CARLOS],
      /permission denied/,
    );
    await como(null);
    await falla('select * from notificaciones', [], /permission denied/);
  });

  test('push: se manda al teléfono registrado, con el link al trabajo', async () => {
    await como(CARLOS);
    await db.query(`select registrar_dispositivo($1, 'ios')`, [TOKEN_CARLOS]);
    await db.exec('reset role');
    await db.exec('delete from net.enviados');
    const t = await publicar(MARTA, 'Pintura', 'Centro');
    await db.exec('reset role');
    const [envio] = await filas('select url, body from net.enviados');
    assert.equal(envio.url, 'https://exp.host/--/api/v2/push/send');
    assert.equal(envio.body[0].to, TOKEN_CARLOS);
    assert.equal(envio.body[0].title, 'Trabajo nuevo de pintura en Centro');
    assert.equal(envio.body[0].data.url, `/trabajo/${t.id}`);
  });

  test('push: al cerrar sesión deja de llegar, y el token pasa a quien entre después', async () => {
    await como(CARLOS);
    await db.query(`select registrar_dispositivo($1, 'ios')`, [TOKEN_CARLOS]);
    await db.query('select olvidar_dispositivo($1)', [TOKEN_CARLOS]);
    await db.exec('reset role');
    assert.equal((await filas('select * from dispositivos')).length, 0);

    await como(CARLOS);
    await db.query(`select registrar_dispositivo($1, 'ios')`, [TOKEN_CARLOS]);
    await como(LUCIA); // mismo teléfono, otra cuenta
    await db.query(`select registrar_dispositivo($1, 'ios')`, [TOKEN_CARLOS]);
    await db.exec('reset role');
    assert.deepEqual(await filas('select usuario_id from dispositivos'), [{ usuario_id: LUCIA }]);
    await falla(`select registrar_dispositivo('cualquiera', 'ios')`, [], /dispositivos_token_check/);
  });

  test('push: si falla el envío, igual se crea el trabajo y la notificación', async () => {
    await como(CARLOS);
    await db.query(`select registrar_dispositivo($1, 'ios')`, [TOKEN_CARLOS]);
    await db.exec('reset role');
    await db.exec(`create or replace function net.http_post(url text, body jsonb default '{}', params jsonb default '{}',
      headers jsonb default '{}', timeout_milliseconds integer default 5000) returns bigint language plpgsql
      as $$ begin raise exception 'sin internet'; end $$`);
    const t = await publicar(MARTA, 'Pintura', 'Centro');
    assert.equal((await avisos(CARLOS, 'trabajo_nuevo')).filter((n) => n.trabajo_id === t.id).length, 1);
  });
});

describe('ranking y calificaciones pendientes', () => {
  // Crea un trabajo terminado del cliente con el trabajador y la opinión dada.
  async function terminadoConOpinion(cliente, trabajador, oficio, zona, puntaje) {
    await db.exec('reset role');
    const [t] = await filas(
      `insert into trabajos (cliente_id, oficio, descripcion, zona, para_cuando, estado, trabajador_elegido_id, precio_acordado, terminado_at)
       values ($1, $2, 'Trabajo terminado de prueba.', $3, 'sin_apuro', 'terminado', $4, 1000, now()) returning id`,
      [cliente, oficio, zona, trabajador],
    );
    await db.query(
      `insert into opiniones (trabajo_id, cliente_id, trabajador_id, puntaje, comentario) values ($1, $2, $3, $4, 'Opinión de prueba.')`,
      [t.id, cliente, trabajador, puntaje],
    );
    return t.id;
  }

  test('el puntaje premia tener más reseñas buenas, no solo el promedio', async () => {
    // Lucía ya tiene una de 5★ (seed). Ramón: diez de 5★ y dos de 4★ → promedio 4,8 pero muchas más reseñas.
    for (let i = 0; i < 10; i++) await terminadoConOpinion(MARTA, RAMON, 'Plomería', 'Centro', 5);
    for (let i = 0; i < 2; i++) await terminadoConOpinion(MARTA, RAMON, 'Plomería', 'Centro', 4);
    await como(MARTA);
    const rep = await filas(
      'select trabajador_id, promedio, cantidad_opiniones, puntaje, estrellas_5, estrellas_4 from reputacion_trabajadores where trabajador_id in ($1, $2)',
      [LUCIA, RAMON],
    );
    const lucia = rep.find((r) => r.trabajador_id === LUCIA);
    const ramon = rep.find((r) => r.trabajador_id === RAMON);
    assert.ok(Number(lucia.promedio) > Number(ramon.promedio)); // 5 contra 4,8...
    assert.ok(Number(ramon.puntaje) > Number(lucia.puntaje)); // ...pero Ramón va primero
    assert.deepEqual([ramon.estrellas_5, ramon.estrellas_4], [10, 2]);

    const recomendados = (await filas('select nombre from trabajadores_recomendados()')).map((t) => t.nombre);
    assert.deepEqual(recomendados.slice(0, 2), ['Ramón', 'Lucía']);
    const servicios = (await filas('select nombre from servicios_para_mi()')).map((s) => s.nombre);
    assert.equal(servicios[0], 'Ramón');
  });

  test('sin reseñas el puntaje es neutro (3,5) y una mala reseña baja', async () => {
    await terminadoConOpinion(MARTA, CARLOS, 'Pintura', 'Centro', 1);
    await como(MARTA);
    const [sergio] = await filas('select puntaje from reputacion_trabajadores where trabajador_id = $1', [SERGIO]);
    const [carlos] = await filas('select puntaje from reputacion_trabajadores where trabajador_id = $1', [CARLOS]);
    assert.equal(Number(sergio.puntaje), 3.5);
    assert.ok(Number(carlos.puntaje) < 3.5);
  });

  test('pendientes de calificar: al cliente le faltan opiniones, al trabajador las del cliente', async () => {
    await db.exec('reset role');
    await db.query(`update trabajos set estado = 'terminado', terminado_at = now() where id = $1`, [
      REVOQUE_MARTA_POR_CONFIRMAR,
    ]);
    await como(MARTA);
    assert.deepEqual(
      (await filas('select trabajo_id, nombre from pendientes_de_calificar()')).map((p) => [p.trabajo_id, p.nombre]),
      [[REVOQUE_MARTA_POR_CONFIRMAR, 'Carlos']],
    );
    await como(CARLOS);
    assert.deepEqual(
      (await filas('select trabajo_id, nombre from pendientes_de_calificar()')).map((p) => [p.trabajo_id, p.nombre]),
      [[REVOQUE_MARTA_POR_CONFIRMAR, 'Marta']],
    );
    await db.query(`insert into calificaciones_clientes (trabajo_id, cliente_id, puntaje) values ($1, $2, 5)`, [
      REVOQUE_MARTA_POR_CONFIRMAR,
      MARTA,
    ]);
    assert.equal((await filas('select * from pendientes_de_calificar()')).length, 0);
    await como(DIEGO); // el trabajo terminado del seed ya está calificado por los dos
    assert.equal((await filas('select * from pendientes_de_calificar()')).length, 0);
  });
});

describe('borrar cuenta', () => {
  test('cada uno borra solo su cuenta, y se va todo lo suyo', async () => {
    await como(MARTA);
    await db.query('select borrar_mi_cuenta()');
    await db.exec('reset role');
    const [{ usuarios, perfiles, trabajos }] = await filas(
      `select (select count(*) from auth.users where id = $1)::int as usuarios,
              (select count(*) from perfiles where id = $1)::int as perfiles,
              (select count(*) from trabajos where cliente_id = $1)::int as trabajos`,
      [MARTA],
    );
    assert.deepEqual({ usuarios, perfiles, trabajos }, { usuarios: 0, perfiles: 0, trabajos: 0 });
    assert.equal((await filas('select count(*)::int as n from perfiles'))[0].n, 5);
  });

  test('si se borra un trabajador, sus trabajos quedan sin trabajador elegido', async () => {
    await como(LUCIA);
    await db.query('select borrar_mi_cuenta()');
    await db.exec('reset role');
    const [t] = await filas('select estado, trabajador_elegido_id from trabajos where id = $1', [LED_DIEGO_TERMINADO]);
    assert.deepEqual(t, { estado: 'terminado', trabajador_elegido_id: null });
  });

  test('sin sesión no se puede', async () => {
    await como(null);
    await falla('select borrar_mi_cuenta()', [], /permission denied/);
  });
});

describe('fotos', () => {
  const PUBLICAR = `insert into trabajos (oficio, descripcion, zona, para_cuando, fotos) values ('Pintura', 'Pintar el frente de la casa.', 'Centro', 'sin_apuro', $1) returning fotos`;

  test('un trabajo puede tener de 0 a 5 fotos, todas de la carpeta del cliente', async () => {
    await como(MARTA);
    assert.deepEqual((await filas(PUBLICAR, [[]]))[0].fotos, []);
    const cinco = [1, 2, 3, 4, 5].map((n) => `${MARTA}/frente-${n}.jpg`);
    assert.equal((await filas(PUBLICAR, [cinco]))[0].fotos.length, 5);
    await falla(PUBLICAR, [[...cinco, `${MARTA}/frente-6.jpg`]], /trabajos_fotos/);
    await falla(PUBLICAR, [[`${DIEGO}/ajena.jpg`]], /trabajos_fotos/);
  });

  test('cada uno sube fotos solo a su carpeta', async () => {
    await como(MARTA);
    await db.query(`insert into storage.objects (bucket_id, name) values ('fotos-trabajos', $1)`, [`${MARTA}/living.jpg`]);
    await falla(
      `insert into storage.objects (bucket_id, name) values ('fotos-trabajos', $1)`,
      [`${DIEGO}/trucho.jpg`],
      /row-level security/,
    );
  });
});
