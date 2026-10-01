# Registro de trabajo · Backend

Todo lo que se fue haciendo en la base (Supabase), del más nuevo al más viejo.
La app tiene su propio registro en [laburapp-app](https://github.com/DemkaaA01/laburapp-app/blob/main/REGISTRO.md).

## 2026-10-01

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
