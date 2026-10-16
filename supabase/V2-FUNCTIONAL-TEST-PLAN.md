# El Gallinero V2 — plan de pruebas funcionales y de concurrencia

## Alcance y seguridad

Estas pruebas se ejecutan únicamente después de instalar y verificar las cinco
migraciones V2. Todas las pruebas funcionales son **mutantes**: crean partidas,
jugadores, rondas, votos y entradas en `private.v2_operations`. No eliminan nada.

- Usar partidas nuevas y jugadores con nombres que empiecen por `V2TEST-`.
- Generar sesiones aleatorias; nunca reutilizar sesiones reales.
- Usar únicamente URL pública y clave `anon`. Nunca `service_role`.
- No imprimir claves, tokens ni identificadores de sesión.
- No tocar códigos de partidas históricas.
- Ejecutar un caso cada vez y conservar su código e informe para auditoría.
- Si el estado observado no coincide, detenerse: no intentar “arreglarlo” con
  SQL, borrados o nuevas operaciones automáticas.

## Contratos utilizados

### Ciclo de vida

| RPC | Parámetros | Retorno | Regla principal |
|---|---|---|---|
| `create_game_with_host_v2` | `p_code text`, `p_host_session_id text`, `p_host_name text` | tabla `(game_id uuid, code text)` | Crea partida `flow_version=2` y anfitrión activo |
| `join_game_by_code_v2` | `p_code text`, `p_session_id text`, `p_name text` | tabla `(game_id uuid, code text)` | Une o reactiva la misma sesión |
| `get_player_by_session_v2` | `p_session_id text`, `p_code text default null` | tabla `(player_id, game_id, name, code, is_host)` | Recupera sesión activa y actualiza presencia |
| `heartbeat_player_v2` | `p_session_id text`, `p_game_id uuid` | `void` | Actualiza presencia en V2 |
| `remove_player_from_game_v2` | `p_host_session_id text`, `p_player_id uuid` | `void` | Solo anfitrión activo; no puede expulsarse a sí mismo |

### Motor de rondas

Todas las mutaciones devuelven un JSON con
`operation_id`, `game_id`, `transition_version`, `current_vote_round_id`,
`status` y `result`.

| RPC | Parámetros |
|---|---|
| `activate_game_card_v2` | `p_game_id`, `p_session_id`, `p_card_slug`, `p_operation_id`, `p_expected_transition_version` |
| `submit_vote_v2` | `p_vote_round_id`, `p_voter_session_id`, `p_voted_player_id`, `p_operation_id`, `p_expected_transition_version` |
| `close_vote_round_if_complete_v2` | `p_vote_round_id`, `p_session_id`, `p_operation_id`, `p_expected_transition_version` |
| `start_tiebreak_round_v2` | `p_source_round_id`, `p_session_id`, `p_operation_id`, `p_expected_transition_version` |
| `resolve_random_tiebreak_v2` | `p_vote_round_id`, `p_session_id`, `p_operation_id`, `p_expected_transition_version` |
| `mark_round_ready_next_v2` | `p_vote_round_id`, `p_session_id`, `p_operation_id`, `p_expected_transition_version` |
| `get_canonical_game_state_v2` | `p_game_id`, `p_session_id` |

`get_canonical_game_state_v2` devuelve `game_id`, `flow_version`,
`transition_version`, `active_card_slug`, `current_round_number`,
`current_vote_round_id`, `status`, `card_id`, `round_number`,
`source_round_id`, `tie_player_ids`, `winning_player_id` y `winning_votes`.

Una operación ya aplicada se recupera antes de validar nuevamente el CAS. Un
`operation_id` solo puede representar el mismo nombre de operación, actor y
payload. `submit_vote_v2` no incrementa `transition_version`; las transiciones de
ronda sí lo hacen.

## Secuencia funcional

### A. Crear partida V2

- Preparación: código aleatorio válido `[A-Z2-9]{4}`, sesión nueva de al menos 12
  caracteres y nombre `V2TEST-HOST-*`.
- Acción: `create_game_with_host_v2` con los tres parámetros exactos.
- Esperado: una fila con UUID y el mismo código.
- Modifica: `games` y `players`.
- Comprobación: recuperar al anfitrión y consultar estado canónico; debe mostrar
  `flow_version=2`, `transition_version=0` y ronda actual nula.

### B. Unir jugadores

- Preparación: tres sesiones nuevas y nombres `V2TEST-P2/P3/P4-*`.
- Acción: una llamada a `join_game_by_code_v2` por jugador.
- Esperado: todas devuelven el mismo `game_id` y código.
- Modifica: crea jugadores activos y actualiza presencia.
- Comprobación: `get_player_by_session_v2` devuelve un `player_id` diferente para
  cada sesión.

### C. Recuperar sesión

- Acción: `get_player_by_session_v2(session, code)` y después con `p_code=NULL`.
- Esperado: misma identidad, partida y rol; el anfitrión tiene `is_host=true`.
- Modifica: presencia del jugador recuperado.
- Comprobación: comparar únicamente IDs y rol, sin registrar la sesión.

### D. Activar carta

- Preparación: slug de una carta activa confirmado previamente por el operador;
  estado canónico con versión `V`.
- Acción: `activate_game_card_v2(game, hostSession, slug, opId, V)`.
- Esperado: `status=voting`, ronda no nula y versión `V+1`.
- Modifica: crea `vote_rounds`, actualiza `games`, presencia y diario.
- Comprobación: estado canónico coincide con el sobre devuelto.

### E. Emitir votos

- Preparación: ronda abierta; cada jugador vota a otro jugador activo.
- Acción: `submit_vote_v2` con un `operation_id` distinto por voto y la misma
  versión canónica.
- Esperado: éxito por votante; la versión no cambia.
- Modifica: crea votos, actualiza presencia y diario.
- Comprobación: intentar un segundo voto de la misma sesión debe ser rechazado
  por la unicidad de ronda/sesión.

### F–G. Cerrar y consultar resultado

- Preparación: todos los jugadores elegibles han votado.
- Acción: `close_vote_round_if_complete_v2`.
- Esperado: `status=closed`, versión incrementada, `winning_votes` persistido;
  con ganador único, `winning_player_id` no nulo y `tie_player_ids` nulo.
- Modifica: ronda, partida, presencia y diario.
- Comprobación: `get_canonical_game_state_v2` devuelve exactamente el ganador y
  conteo persistidos.

### H. Pasar a la siguiente ronda

- Acción: `mark_round_ready_next_v2` con la versión cerrada y después
  `activate_game_card_v2` con la nueva versión.
- Esperado: primero `ready_next`; después nueva ronda `voting`, UUID distinto y
  versión incrementada en cada transición.
- Modifica: ronda anterior, partida, nueva ronda y diario.
- Comprobación: el estado canónico apunta solo a la nueva ronda; sus campos de
  ganador y empate empiezan nulos.

### I. Provocar empate y crear desempate

- Preparación: cuatro jugadores. Repartir votos para que dos o más candidatos
  compartan el máximo.
- Acción: cerrar la ronda y llamar `start_tiebreak_round_v2`.
- Esperado: ronda origen cerrada con `winning_player_id=NULL`,
  `winning_votes` persistido y `tie_player_ids` con los empatados; la ronda hija
  tiene `source_round_id` igual a la origen y estado `voting`.
- Modifica: ronda origen, ronda hija, partida y diario.
- Comprobación: estado canónico apunta a la hija y conserva solo sus propios
  campos, sin copiar ganador de la ronda origen.

### J. Resolver desempate aleatorio

- Preparación: votar en la ronda hija para producir otro empate y cerrarla.
- Acción: `resolve_random_tiebreak_v2`.
- Esperado: ganador escogido entre `tie_player_ids`; permanece persistido en
  `winning_player_id`. La respuesta repetida con el mismo `operation_id` devuelve
  el mismo ganador.
- Modifica: ronda hija, partida y diario.
- Comprobación: dos lecturas canónicas sucesivas muestran el mismo ganador.

### K. Presencia y abandono

- Acción: `heartbeat_player_v2`; expulsar un no-anfitrión mediante
  `remove_player_from_game_v2`; intentar expulsar con una sesión no anfitriona.
- Esperado: heartbeat exitoso; expulsión del anfitrión exitosa; intento no
  autorizado devuelve `host_not_found`; autoexpulsión devuelve
  `cannot_remove_self`.
- Modifica: presencia y estado activo del jugador expulsado.
- Comprobación: su recuperación devuelve vacío y su consulta canónica devuelve
  `player_not_in_game`. Reunirse otra vez reactiva su sesión.

### L. Aislamiento V1/V2

- Preparación: partida V2 nueva y carta activa.
- Acción: llamar una RPC V1 mutante con datos válidos de esa partida, por ejemplo
  `activate_game_card`.
- Esperado: `client_upgrade_required` antes de cualquier escritura V1.
- Modifica: nada si la guarda funciona.
- Comprobación: estado canónico V2 idéntico antes y después. La prueba inversa
  requiere una partida V1 de prueba nueva; no usar una histórica.

## Pruebas de concurrencia

| Caso | Ejecución | Resultado esperado | Invariantes |
|---|---|---|---|
| Dos votos simultáneos | Dos sesiones, operaciones distintas, misma ronda y versión | Ambos pueden completar; la versión no cambia | Un voto por sesión, sin votos duplicados |
| Dos cierres simultáneos | Dos operaciones distintas y misma versión | Uno aplica; el otro recibe `stale_transition_version` | Un solo cierre y un solo incremento |
| Dos activaciones simultáneas | Misma partida/versión, operaciones distintas | Una aplica; otra queda obsoleta | Una sola ronda canónica nueva |
| Mismo CAS | Dos transiciones diferentes con la misma versión | Como máximo una avanza | `transition_version` aumenta una vez |
| Replay de operación | Repetir exactamente operación, actor y parámetros | Misma respuesta persistida | Sin segundo efecto ni incremento |
| `operation_id` conflictivo | Mismo ID, cambiar cualquier campo del payload | `operation_id_conflict` | Resultado original intacto |
| Versión `NULL` | Nueva operación con `p_expected_transition_version=NULL` | `stale_transition_version` | Ninguna fila de operación aplicada ni transición |
| Versión obsoleta | Nueva operación con versión anterior | `stale_transition_version` | Estado canónico sin cambios |
| Dos desempates simultáneos | Dos `start_tiebreak_round_v2` con misma fuente/versión | Uno aplica; otro obsoleto | Una sola hija por `source_round_id` |

Usar `Promise.allSettled` para iniciar llamadas desde el mismo proceso. Esto
aproxima simultaneidad, pero no prueba todos los interleavings. Repetir varias
veces en partidas nuevas y considerar pruebas posteriores con barrera coordinada
si se necesita evidencia más fuerte.

## Ejecutor local

El archivo `scripts/v2-functional-tests.mjs` ejecuta un escenario mutante con
cuatro jugadores, ganador único, siguiente ronda, empate, desempate aleatorio,
replay, CAS nulo/obsoleto, conflicto de operación, presencia, expulsión y una
guarda V1.

Requisitos:

```text
NEXT_PUBLIC_SUPABASE_URL
NEXT_PUBLIC_SUPABASE_ANON_KEY
V2_TEST_CARD_SLUG
V2_TEST_CONFIRM=CREATE_REMOTE_V2_TEST_DATA
```

Ejecución deliberada, únicamente después de revisar el código:

```text
node scripts/v2-functional-tests.mjs --confirm-write-tests
```

El script no se ejecuta mediante `npm test`, no borra sus datos y nunca imprime
la clave ni las sesiones. Un `FAIL` detiene el escenario y deja el código de la
partida en el informe para investigación.

## Criterio de salida

- Todas las pruebas funcionales aplicables: `PASS`.
- Errores negativos coinciden con los códigos esperados.
- Estado canónico consistente después de cada respuesta incierta o concurrente.
- Ningún efecto duplicado en replays.
- Ninguna RPC V1 modifica V2 ni viceversa.
- Cualquier anomalía se documenta antes de desplegar el frontend.
