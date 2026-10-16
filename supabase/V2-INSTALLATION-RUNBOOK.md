# El Gallinero V2 — instalación controlada

Esta guía describe una instalación manual y secuencial. No sustituye una copia
de seguridad, una ventana de mantenimiento ni la revisión humana de cada
resultado.

## Condiciones previas

- Confirmar que nadie está jugando y detener todo tráfico que pueda llamar RPC.
- No publicar el frontend V2 antes de completar backend y pruebas.
- Todos los entornos de la aplicación comparten el mismo Supabase remoto: una
  migración aplicada desde cualquier entorno afecta a todos.
- Conservar los resultados del preflight y de la recuperación V1.
- Ejecutar cada migración por separado. No concatenar ni automatizar los cinco
  pasos.

**MIGRACIÓN** modifica la base de datos.
**VERIFICACIÓN** contiene una única consulta de solo lectura.

## Paso 1 — estructura V2

**MIGRACIÓN:** `v2-structural-schema-20261016.sql`
**VERIFICACIÓN:** `v2-verify-step1-readonly.sql`

Continuar únicamente si todas las filas obligatorias muestran `PASS`. Un
`REVIEW` exige revisar `details`; cualquier `FAIL` detiene la instalación.

Si la migración falla, su transacción debe revertir el paso completo. No volver
a ejecutarla a ciegas: conservar el error, ejecutar el preflight de solo lectura
y confirmar mediante catálogos si existe algún objeto V2 inesperado.

## Paso 2 — guardas V1, bloque 1

**MIGRACIÓN:** `v1-flow-guards-block1-20261016.sql`
**VERIFICACIÓN:** `v2-verify-step2-readonly.sql`

Continuar solo con todos los resultados en `PASS`. Las huellas MD5 verifican que
el cuerpo instalado coincide exactamente con el archivo local auditado.

Ante un `FAIL`, no instalar el paso 3. Si la migración informó error, asumir que
su transacción se revirtió; verificar igualmente las definiciones remotas antes
de decidir si se reintenta.

## Paso 3 — guardas V1, bloque 2

**MIGRACIÓN:** `v1-flow-guards-block2-20261016.sql`
**VERIFICACIÓN:** `v2-verify-step3-readonly.sql`

Continuar solo si las once funciones devuelven `PASS` y la comprobación de
sobrecargas no requiere intervención. Las huellas comprueban la conservación de
las implementaciones V1 endurecidas, además de sus guardas V2.

Ante un `FAIL`, detenerse. No instalar RPC V2 mientras el aislamiento V1/V2 sea
incierto.

## Paso 4 — ciclo de vida V2

**MIGRACIÓN:** `v2-game-lifecycle-rpcs-20261016.sql`
**VERIFICACIÓN:** `v2-verify-step4-readonly.sql`

Continuar solo con cinco filas `PASS`. Deben verificarse las firmas, retornos,
`SECURITY DEFINER`, `search_path` y permisos efectivos: `anon` permitido,
`PUBLIC` y `authenticated` denegados.

No permitir todavía tráfico ni crear partidas V2: en este punto aún falta el
motor de rondas.

## Paso 5 — motor de rondas V2

**MIGRACIÓN:** `v2-round-engine-rpcs-20261016.sql`
**VERIFICACIÓN:** `v2-verify-step5-readonly.sql`

Continuar a pruebas únicamente con todas las filas en `PASS`. Deben estar las
siete RPC públicas, las dos funciones privadas, el CAS seguro ante `NULL` y el
diario de idempotencia protegido.

## Si aparece un FAIL

1. Detener la secuencia inmediatamente.
2. Guardar el mensaje de la migración y la tabla completa de verificación.
3. No editar ni ejecutar SQL improvisado en producción.
4. Determinar si falló la migración o solo una expectativa de verificación.
5. Consultar catálogos y el preflight para identificar el último paso completo.
6. Corregir y auditar localmente antes de reintentar o revertir.

Cada archivo usa `BEGIN/COMMIT`; un error revierte ese archivo, pero no los pasos
anteriores ya confirmados.

## Identificar una instalación parcial

- Paso 1: existen columnas V2, esquema `private` y `private.v2_operations`.
- Paso 2: las tres RPC V1 del bloque 1 tienen las huellas protegidas.
- Paso 3: las once RPC V1 del bloque 2 tienen las huellas protegidas.
- Paso 4: existen las cinco RPC públicas de ciclo de vida V2.
- Paso 5: existen las siete RPC públicas del motor y las dos funciones privadas.

Ejecutar únicamente las verificaciones de lectura correspondientes. No deducir
el estado solo por el último archivo que alguien recuerda haber ejecutado.

## Rollback de referencia

Solo con tráfico detenido y después de evaluar si existen partidas u operaciones
V2, el orden inverso es:

1. `rollback-v2-round-engine-rpcs-20261016.sql`
2. `rollback-v2-game-lifecycle-rpcs-20261016.sql`
3. `rollback-v1-flow-guards-block2-20261016.sql`
4. `rollback-v1-flow-guards-block1-20261016.sql`
5. `rollback-v2-structural-schema-20261016.sql`

El rollback estructural está diseñado para bloquearse si detecta datos V2. No
forzarlo, no borrar el diario y no eliminar datos para lograr que continúe. Sus
locks requieren una ventana sin tráfico.

## Estrategia de pruebas posterior

### Pruebas de solo lectura

- Ejecutar de nuevo los cinco verificadores y el preflight.
- Confirmar firmas, ACL efectivas, restricciones, índices y ausencia de
  sobrecargas inesperadas.
- Consultar el estado canónico únicamente después de disponer de una partida de
  prueba creada de forma deliberada.

### Pruebas que crean datos

Estas pruebas deben realizarse manualmente en una partida identificada como de
prueba y generan datos persistentes:

1. Crear una partida V2 con anfitrión y unir varios jugadores.
2. Recuperar sesiones y comprobar heartbeat, desconexión y expulsión por host.
3. Activar una carta, emitir un voto por jugador y cerrar la ronda.
4. Probar ganador único, empate, desempate votado y sorteo aleatorio.
5. Marcar `ready_next` y activar la carta siguiente.
6. Repetir una mutación con el mismo `operation_id` y los mismos parámetros;
   debe devolver el resultado persistido sin duplicar efectos.
7. Reutilizar ese `operation_id` con parámetros diferentes; debe rechazarse.
8. Enviar una versión obsoleta y `NULL`; ambas deben producir
   `stale_transition_version`.
9. Lanzar mutaciones concurrentes con la misma versión y verificar que no haya
   dos transiciones incompatibles.
10. Confirmar que las RPC V1 rechazan la partida V2 y que las RPC V2 rechazan
    una partida V1.

La concurrencia y la compilación PL/pgSQL solo quedan demostradas tras ejecutar
estas pruebas reales; la auditoría estática no las sustituye.

## Acciones que no deben automatizarse

- No ejecutar las cinco migraciones como un lote único.
- No continuar automáticamente después de `FAIL` o `REVIEW` no explicado.
- No ejecutar rollbacks automáticamente.
- No borrar datos, operaciones o partidas para facilitar un rollback.
- No desplegar el frontend V2 hasta completar instalación, verificaciones y
  pruebas funcionales.
