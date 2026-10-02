# Laburapp · Backend

Backend de [Laburapp](../README.md), la app de oficios de San Nicolás. Es un proyecto de **Supabase**
(Postgres + Auth + Storage): no hay servidor propio. La app habla directo con Supabase y la seguridad
vive en la base (RLS en todas las tablas + funciones que validan cada cambio de estado).

## Estructura

```
supabase/
  config.toml        configuración del proyecto (local y valores base)
  migrations/        cambios de la base, en orden. NUNCA editar una ya aplicada: crear una nueva
  seed.sql           datos de prueba (solo desarrollo)
  functions/         Edge Functions (código de servidor, para más adelante: pagos, avisos)
tests/
  reglas.test.mjs            tests de seguridad y reglas de negocio
  supabase-simulado.sql      lo mínimo de Supabase para correr los tests sin Docker
```

## Modelo

| Tabla | Qué guarda | Quién la ve |
|---|---|---|
| `perfiles` | rol, nombre, apellido, oficios, zonas, comercio, foto, sobre mí | usuarios con sesión |
| `datos_privados` | WhatsApp y sexo | solo el dueño |
| `trabajos` | lo que publica el cliente (0 a 5 fotos), estado, trabajador elegido; si es pedido directo, trabajador invitado y servicio | el cliente; trabajadores si está abierto, si se postularon o si los eligieron |
| `postulaciones` | precio y mensaje del trabajador | el trabajador y el cliente del trabajo |
| `opiniones` | del cliente al trabajador: estrellas 1–5 y descripción, una por trabajo | usuarios con sesión |
| `servicios` | avisos del trabajador: oficio, título, descripción, precio desde, zonas, fotos, activo (hasta 10) | activos: usuarios con sesión; pausados: solo el dueño |
| `galeria` | fotos de trabajos hechos (solo trabajadores, hasta 12) | usuarios con sesión |
| `calificaciones_clientes` | del trabajador al cliente: solo estrellas 1–5, una por trabajo | usuarios con sesión |
| `notificaciones` | avisos de cada usuario (la campanita); los crean triggers y disparan el push | solo el dueño |
| `dispositivos` | tokens de push de Expo de cada teléfono | nadie directo: solo por funciones |

Funciones que usa la app (`supabase.rpc(...)`):

| Función | Quién | Qué hace |
|---|---|---|
| `registrar_dispositivo(p_token, p_plataforma)` / `olvidar_dispositivo(p_token)` | cualquiera con sesión | guarda u olvida el token de push de este teléfono |
| `marcar_notificaciones_leidas()` | cualquiera con sesión | marca todos sus avisos como leídos |
| `trabajos_para_mi()` | trabajador | trabajos abiertos de sus oficios y zonas |
| `servicios_para_mi(p_oficio)` | cliente | servicios activos que llegan a su zona, mejor puntuados primero |
| `trabajadores_recomendados(p_limite)` | cliente | trabajadores de sus rubros y su zona, mejor puntuados primero |
| `elegir_postulacion(p_postulacion_id)` | cliente | asigna el trabajo y fija el precio acordado |
| `contacto_del_trabajo(p_trabajo_id)` | cliente o trabajador elegido | nombre y WhatsApp de la otra parte |
| `marcar_terminado(p_trabajo_id)` | trabajador elegido | asignado → por_confirmar |
| `confirmar_terminado(p_trabajo_id)` | cliente | por_confirmar → terminado (habilita las calificaciones) |
| `rechazar_terminado(p_trabajo_id)` | cliente | por_confirmar → asignado |
| `cancelar_trabajo(p_trabajo_id)` | cliente | abierto o asignado → cancelado |

Estados de un trabajo: `abierto` → `asignado` → `por_confirmar` → `terminado` (o `cancelado` desde abierto o asignado).

Vistas `reputacion_trabajadores` y `reputacion_clientes`: promedio y cantidad de calificaciones.
Storage: bucket privado `fotos-trabajos` (fotos de pedidos, links firmados) y bucket público `perfiles` (foto de perfil y galería). Cada usuario sube solo a la carpeta `{su id}/`.

## Uso

```bash
npm install
npm test                 # tests de reglas (PGlite, no hace falta Docker)
```

GitHub Actions corre los tests en cada push a `main` y en cada pull request.

### Datos de demostración (solo desarrollo)

```bash
SUPABASE_URL=https://<ref>.supabase.co SUPABASE_PUBLISHABLE_KEY=sb_publishable_… npm run demo
```

Carga 12 trabajadores y 6 clientes (`<nombre>@laburapp.test`, contraseña `laburapp123`) con foto, servicios,
galería, ~40 trabajos terminados con calificaciones variadas y ~20 trabajos abiertos con fotos y precios. Pasa por la
API con los permisos de cada usuario (solo el alta de usuarios es por SQL). Se puede correr de nuevo sin duplicar
nada, y se niega a correr contra un proyecto que no sea el vinculado o contra el de la preinscripción.
Lo que se fue haciendo está en [REGISTRO.md](REGISTRO.md).

### Aplicar en el proyecto de desarrollo (sin Docker)

```bash
npx supabase login
npx supabase link --project-ref <ref-de-laburapp-dev>
npx supabase db push --include-seed   # migraciones + datos de prueba
npm run db:types                      # tipos TypeScript para la app
```

### Local completo (con Docker Desktop)

```bash
npm start          # levanta Supabase local
npm run db:reset   # recrea la base con migraciones + seed
```

## Reglas

- Proyectos separados: `laburapp-dev` y `laburapp-prod`. El proyecto de la preinscripción no se toca.
- Cada cambio de base es una migración nueva (`npx supabase migration new <nombre>`), con su test.
- `seed.sql` es solo para desarrollo: nunca `--include-seed` contra producción.
- Usuarios de prueba: ver el encabezado de `seed.sql` (contraseña `laburapp123`).
