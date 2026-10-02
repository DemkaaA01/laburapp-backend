# Registro de trabajo · Backend

Todo lo que se fue haciendo en la base (Supabase), del más nuevo al más viejo.
La app tiene su propio registro en [laburapp-app](https://github.com/DemkaaA01/laburapp-app/blob/main/REGISTRO.md).

## 2026-10-02

### Seguridad

- **Revisión con `supabase db advisors`:** sin errores. Los helpers que usan las reglas (`mi_rol`, `puedo_postularme`, `invitacion_valida`, `cantidad_servicios`, etc.) se movieron al schema **`privado`**, que no está expuesto en la API: antes cualquiera podía llamarlos por `/rest/v1/rpc`. Quedan 11 avisos por funciones que la app llama a propósito (elegir, cancelar, contacto, borrar cuenta…) y que validan quién sos adentro. "Leaked password protection" requiere plan pago.
- **Perfiles de clientes privados:** antes cualquier usuario con sesión podía listar a todos los clientes (nombre, zona, comercio). Ahora a un cliente lo ve él mismo y quien tiene relación con un trabajo suyo (elegido, invitado, quien le pasó precio o un trabajador que ve su pedido abierto). Los trabajadores siguen públicos. `opiniones_de()` muestra al autor como "Marta G.".
- **Fotos de pedidos:** antes se podían listar todas las del bucket privado; ahora solo las de trabajos que podés ver.
- **Bloqueos** (`bloqueos`, `privado.hay_bloqueo`, `mis_bloqueados()`): en los dos sentidos, ocultan pedidos abiertos y servicios, impiden pasar precio y pedir presupuesto, no se avisan los trabajos nuevos y salen de los recomendados.
- **Reportes** (`reportes`): motivo y detalle, solo los ve quien reporta; se revisan desde el panel.
- **Límites anti-spam** (solo para usuarios de la app): 10 trabajos por día y 20 abiertos por cliente, 40 precios por día por trabajador, 10 reportes por día.
- `scripts/repartir-fechas.sql`: reparte en las últimas semanas las fechas de los datos de demostración (si no, los clientes de prueba quedaban en el límite diario). Lo corre `npm run demo` al final.
- 11 tests nuevos (79 en total), con prueba de que fallan si se saca la regla de bloqueos.

### Datos de demostración

- `scripts/datos-demo.mjs` (`npm run demo`): 12 trabajadores (todos los oficios y zonas, con calificaciones de 1 a 5★ y uno sin reseñas), 6 clientes (uno comercio), servicios con fotos, galerías, 38 trabajos terminados y calificados recorriendo el flujo completo por la API, y 20 trabajos abiertos con fotos y precios.
- Idempotente, con reintentos (la CLI a veces tarda en conectar) y protegido: solo corre contra el proyecto vinculado y nunca contra el de la preinscripción. Mientras carga, saca los teléfonos registrados para no mandar decenas de avisos; la app los vuelve a registrar al abrirse.
- Cargado en `laburapp-dev`.

## 2026-10-01

### Ranking por calificaciones y pendientes de calificar

- `reputacion_trabajadores` suma `puntaje` (promedio bayesiano: como si todos arrancaran con 5 reseñas de 3,5★, así pesa la cantidad y no solo el promedio) y `estrellas_5` a `estrellas_1` para las barras.
- `trabajadores_recomendados()` y `servicios_para_mi()` ordenan por `puntaje`.
- `pendientes_de_calificar()`: trabajos terminados que el usuario todavía no calificó (cliente u trabajador).
- Auth: URLs de retorno permitidas para el link de recuperar contraseña (`exp://**`, `laburapp://**`, `http://localhost:8081/**`) y contraseña mínima de 8, aplicadas con `supabase config push`. Las plantillas de mail quedaron comentadas en `config.toml` hasta tener SMTP propio (si no, el push de config falla).
- 3 tests nuevos (68 en total).

### Notificaciones y push

- Tabla `notificaciones` (la campanita): cada uno ve y marca solo las suyas; las crean triggers, no la app.
- Tabla `dispositivos` (tokens de Expo) manejada solo con `registrar_dispositivo()` (reasigna el token si el teléfono cambia de cuenta) y `olvidar_dispositivo()`.
- Triggers que avisan: trabajo nuevo (a los trabajadores de ese oficio y zona), pedido directo, precio nuevo, elegido / no elegido, terminado, confirmado, rechazado, cancelado y calificaciones.
- Al crearse una notificación se manda el push a Expo con **pg_net** (`net.http_post`). Si el envío falla, igual se guarda todo.
- pg_net movido al schema `extensions` (recomendación de Supabase).
- 11 tests nuevos (65 en total); en los tests pg_net está simulado y guarda lo que se mandaría.

### Revisión automática

- **GitHub Actions** (`.github/workflows/revision.yml`): en cada push a `main` y en cada pull request corren los 54 tests de reglas con PGlite (sin Docker ni proyecto de Supabase).

### Servicios con precio obligatorio

- Constraint `servicios_con_precio` (NOT VALID: no frena servicios viejos, sí los nuevos y cualquier cambio).

### Servicios y pedidos directos

- Tabla `servicios` (hasta 10 por trabajador, solo de sus oficios, pausables).
- Pedidos directos: `trabajos.trabajador_invitado_id` y `servicio_id`. Solo los ve el invitado, y solo él puede pasar precio aunque no sea de su zona.
- `servicios_para_mi()` para el cliente; `trabajos_para_mi()` pone primero los pedidos directos.

### Foto de perfil, "sobre mí" y galería

- `perfiles.foto_path` y `sobre_mi`. Tabla `galeria` (solo trabajadores, hasta 12 fotos).
- Bucket público `perfiles` (foto y galería), cada uno sube solo a su carpeta.
- `trabajadores_recomendados()` devuelve también foto y "sobre mí".

### Borrar cuenta

- `borrar_mi_cuenta()`: borra el usuario y en cascada todo lo suyo (requisito de Google Play).

### Mails con la marca

- Plantillas de confirmación, cambio de contraseña y cambio de mail en `supabase/templates/`.
- **Pendiente:** aplicarlas requiere SMTP propio (Resend) y dominio. Supabase no deja cambiarlas en el plan gratis con su servidor de mail.

### Terminado con confirmación y calificaciones

- El trabajador marca terminado (`por_confirmar`) y el cliente confirma o rechaza.
- Pedidos con 0 a 5 fotos. Opinión del cliente con descripción obligatoria; el trabajador califica al cliente con estrellas.

## 2026-09-30

### Backend inicial

- Proyecto Supabase con migraciones, seed y tests: `perfiles` + `datos_privados`, `trabajos`, `postulaciones`, `opiniones`, fotos en Storage.
- RLS en todas las tablas; cambios de estado solo por funciones (`elegir_postulacion`, `cancelar_trabajo`, etc.).
- Aplicado en el proyecto `laburapp-dev`.
