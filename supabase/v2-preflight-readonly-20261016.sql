-- EL GALLINERO V2: preflight de solo lectura.
-- Ejecutar manualmente antes de instalar las migraciones V2.
-- PASS: requisito satisfecho. FAIL: bloquea la instalación. REVIEW: revisar.

with check_01 as (
-- 1. Relaciones requeridas por el backend y el frontend.
with expected_objects(schema_name, object_name, allowed_kinds) as (
  values
    ('public', 'games', array['r', 'p']::"char"[]),
    ('public', 'players', array['r', 'p']::"char"[]),
    ('public', 'cards', array['r', 'p']::"char"[]),
    ('public', 'vote_rounds', array['r', 'p']::"char"[]),
    ('public', 'votes', array['r', 'p']::"char"[]),
    ('public', 'public_players', array['v', 'm']::"char"[]),
    ('public', 'realtime_events', array['r', 'p']::"char"[])
)
select
  'required_object:' || e.schema_name || '.' || e.object_name as check_name,
  case
    when c.oid is null then 'FAIL'
    when c.relkind = any(e.allowed_kinds) then 'PASS'
    else 'FAIL'
  end as status,
  case
    when c.oid is null then 'missing'
    else 'kind=' || c.relkind::text
  end as details
from expected_objects as e
left join pg_catalog.pg_namespace as n
  on n.nspname = e.schema_name
left join pg_catalog.pg_class as c
  on c.relnamespace = n.oid
 and c.relname = e.object_name
order by check_name
),

check_02 as (
-- 2. Columnas históricas requeridas por las migraciones y RPC V2.
with expected_columns(table_name, column_name, expected_type, nullable_ok) as (
  values
    ('games', 'id', 'uuid', false),
    ('games', 'code', 'text', false),
    ('games', 'status', 'text', false),
    ('games', 'host_session_id', 'text', false),
    ('games', 'active_card_slug', 'text', true),
    ('games', 'current_round_number', 'integer', false),
    ('players', 'id', 'uuid', false),
    ('players', 'game_id', 'uuid', false),
    ('players', 'name', 'text', false),
    ('players', 'session_id', 'text', false),
    ('players', 'is_host', 'boolean', false),
    ('players', 'active', 'boolean', false),
    ('players', 'created_at', 'timestamp with time zone', false),
    ('players', 'last_seen_at', 'timestamp with time zone', false),
    ('players', 'disconnected_at', 'timestamp with time zone', true),
    ('cards', 'id', 'uuid', false),
    ('cards', 'slug', 'text', false),
    ('cards', 'active', 'boolean', false),
    ('vote_rounds', 'id', 'uuid', false),
    ('vote_rounds', 'game_id', 'uuid', false),
    ('vote_rounds', 'card_id', 'uuid', false),
    ('vote_rounds', 'round_number', 'integer', false),
    ('vote_rounds', 'status', 'text', false),
    ('vote_rounds', 'tie_player_ids', 'uuid[]', true),
    ('vote_rounds', 'created_at', 'timestamp with time zone', false),
    ('votes', 'vote_round_id', 'uuid', false),
    ('votes', 'voter_session_id', 'text', false),
    ('votes', 'voted_player_id', 'uuid', false)
), actual_columns as (
  select
    c.relname as table_name,
    a.attname as column_name,
    pg_catalog.format_type(a.atttypid, a.atttypmod) as actual_type,
    not a.attnotnull as is_nullable
  from pg_catalog.pg_attribute as a
  join pg_catalog.pg_class as c on c.oid = a.attrelid
  join pg_catalog.pg_namespace as n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relname in ('games', 'players', 'cards', 'vote_rounds', 'votes')
    and a.attnum > 0
    and not a.attisdropped
)
select
  'required_column:public.' || e.table_name || '.' || e.column_name as check_name,
  case
    when a.column_name is null then 'FAIL'
    when a.actual_type <> e.expected_type then 'FAIL'
    when not e.nullable_ok and a.is_nullable then 'FAIL'
    else 'PASS'
  end as status,
  case
    when a.column_name is null then 'missing, expected=' || e.expected_type
    else 'actual=' || a.actual_type || ', nullable=' || a.is_nullable::text
  end as details
from expected_columns as e
left join actual_columns as a
  on a.table_name = e.table_name
 and a.column_name = e.column_name
order by check_name
),

check_03 as (
-- 3. Columnas de la vista usadas directamente por el frontend.
with expected_view_columns(column_name) as (
  values ('id'), ('game_id'), ('name'), ('is_host'), ('active'),
         ('created_at'), ('last_seen_at'), ('presence_status')
)
select
  'public_players_column:' || e.column_name as check_name,
  case when c.column_name is null then 'FAIL' else 'PASS' end as status,
  coalesce('type=' || c.data_type, 'missing') as details
from expected_view_columns as e
left join information_schema.columns as c
  on c.table_schema = 'public'
 and c.table_name = 'public_players'
 and c.column_name = e.column_name
order by check_name
),

check_04 as (
-- 4. Claves primarias actuales de las tablas base.
with required_tables(table_name) as (
  values ('games'), ('players'), ('cards'), ('vote_rounds'), ('votes')
)
select
  'primary_key:public.' || r.table_name as check_name,
  case when count(con.oid) > 0 then 'PASS' else 'FAIL' end as status,
  coalesce(
    string_agg(con.conname || '=' || pg_catalog.pg_get_constraintdef(con.oid), ' | '),
    'missing'
  ) as details
from required_tables as r
left join pg_catalog.pg_namespace as n on n.nspname = 'public'
left join pg_catalog.pg_class as c
  on c.relnamespace = n.oid
 and c.relname = r.table_name
left join pg_catalog.pg_constraint as con
  on con.conrelid = c.oid
 and con.contype = 'p'
group by r.table_name
order by check_name
),

check_05 as (
-- 5. Unicidad semántica requerida. No depende del nombre histórico del índice.
with index_columns as (
  select
    n.nspname as schema_name,
    t.relname as table_name,
    i.relname as index_name,
    ix.indisunique,
    ix.indisvalid,
    pg_catalog.pg_get_expr(ix.indpred, ix.indrelid) as predicate,
    array_agg(a.attname order by k.ordinality)
      filter (where k.ordinality <= ix.indnkeyatts) as key_columns
  from pg_catalog.pg_index as ix
  join pg_catalog.pg_class as t on t.oid = ix.indrelid
  join pg_catalog.pg_namespace as n on n.oid = t.relnamespace
  join pg_catalog.pg_class as i on i.oid = ix.indexrelid
  left join lateral unnest(ix.indkey) with ordinality as k(attnum, ordinality)
    on true
  left join pg_catalog.pg_attribute as a
    on a.attrelid = t.oid
   and a.attnum = k.attnum
  where n.nspname = 'public'
  group by n.nspname, t.relname, i.relname, ix.indisunique,
           ix.indisvalid, ix.indpred, ix.indrelid
), required_unique(check_name, table_name, key_columns, requires_active_predicate) as (
  values
    ('unique_vote_per_round_session', 'votes', array['vote_round_id', 'voter_session_id']::name[], false),
    ('unique_active_session_per_game', 'players', array['game_id', 'session_id']::name[], true)
)
select
  r.check_name,
  case when count(i.index_name) filter (
    where i.indisunique
      and i.indisvalid
      and i.key_columns = r.key_columns
      and (
        not r.requires_active_predicate
        or coalesce(i.predicate, '') ~* 'active[^a-z]*(= *true|IS TRUE|active)'
      )
  ) > 0 then 'PASS' else 'FAIL' end as status,
  coalesce(
    string_agg(
      i.index_name || ' columns=' || i.key_columns::text ||
      ' predicate=' || coalesce(i.predicate, '<none>'),
      ' | '
    ),
    'no candidate index'
  ) as details
from required_unique as r
left join index_columns as i on i.table_name = r.table_name
group by r.check_name, r.key_columns, r.requires_active_predicate
order by r.check_name
),

check_06 as (
-- 6. Índices históricos usados por las búsquedas principales de las RPC.
with index_columns as (
  select
    t.relname as table_name,
    i.relname as index_name,
    ix.indisunique,
    ix.indisvalid,
    array_agg(a.attname order by k.ordinality)
      filter (where k.ordinality <= ix.indnkeyatts) as key_columns
  from pg_catalog.pg_index as ix
  join pg_catalog.pg_class as t on t.oid = ix.indrelid
  join pg_catalog.pg_namespace as n on n.oid = t.relnamespace
  join pg_catalog.pg_class as i on i.oid = ix.indexrelid
  left join lateral unnest(ix.indkey) with ordinality as k(attnum, ordinality)
    on true
  left join pg_catalog.pg_attribute as a
    on a.attrelid = t.oid
   and a.attnum = k.attnum
  where n.nspname = 'public'
  group by t.relname, i.relname, ix.indisunique, ix.indisvalid,
           ix.indrelid
), required_indexes(check_name, table_name, key_columns, must_be_unique) as (
  values
    ('index:cards(slug)', 'cards', array['slug']::name[], true),
    ('index:games(code)', 'games', array['code']::name[], true),
    ('index:players(game,active,created)', 'players', array['game_id', 'active', 'created_at']::name[], false),
    ('index:players(game,active,last_seen)', 'players', array['game_id', 'active', 'last_seen_at']::name[], false),
    ('index:vote_rounds(game,card,status,created)', 'vote_rounds', array['game_id', 'card_id', 'status', 'created_at']::name[], false),
    ('index:votes(round)', 'votes', array['vote_round_id']::name[], false)
)
select
  r.check_name,
  case when exists (
    select 1
    from index_columns as i
    where i.table_name = r.table_name
      and i.indisvalid
      and i.key_columns[1:cardinality(r.key_columns)] = r.key_columns
      and (not r.must_be_unique or i.indisunique)
  ) then 'PASS' else 'FAIL' end as status,
  coalesce((
    select string_agg(i.index_name || '=' || i.key_columns::text, ' | ')
    from index_columns as i
    where i.table_name = r.table_name
  ), 'no indexes on table') as details
from required_indexes as r
order by r.check_name
),

check_07 as (
-- 7. Inventario de restricciones e índices relevantes para revisión manual.
select
  'constraint_inventory:public.' || c.relname || '.' || con.conname as check_name,
  'REVIEW' as status,
  'type=' || con.contype::text || ', definition=' ||
    pg_catalog.pg_get_constraintdef(con.oid) as details
from pg_catalog.pg_constraint as con
join pg_catalog.pg_class as c on c.oid = con.conrelid
join pg_catalog.pg_namespace as n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname in ('games', 'players', 'cards', 'vote_rounds', 'votes')
order by c.relname, con.conname
),

check_08 as (
select
  'index_inventory:public.' || t.relname || '.' || i.relname as check_name,
  'REVIEW' as status,
  pg_catalog.pg_get_indexdef(i.oid) as details
from pg_catalog.pg_index as ix
join pg_catalog.pg_class as t on t.oid = ix.indrelid
join pg_catalog.pg_namespace as n on n.oid = t.relnamespace
join pg_catalog.pg_class as i on i.oid = ix.indexrelid
where n.nspname = 'public'
  and t.relname in ('games', 'players', 'cards', 'vote_rounds', 'votes')
order by t.relname, i.relname
),

check_09 as (
-- 8. RPC V1 que serán sustituidas por las guardas.
with expected_functions(function_name, identity_arguments) as (
  values
    ('activate_game_card', 'uuid, text, text'),
    ('clear_active_card_if_current', 'uuid, text, text'),
    ('get_or_create_vote_round', 'uuid, text, text, uuid'),
    ('submit_vote', 'uuid, text, uuid'),
    ('close_vote_round_if_complete', 'uuid, text'),
    ('start_tiebreak_round', 'uuid, text, uuid[]'),
    ('resolve_random_tiebreak', 'uuid, text, uuid[]'),
    ('mark_round_ready_next', 'uuid, text'),
    ('join_game_by_code', 'text, text, text'),
    ('get_player_by_session', 'text, text'),
    ('heartbeat_player', 'text, uuid'),
    ('remove_player_from_game', 'text, uuid')
), actual_functions as (
  select
    p.oid,
    p.proname,
    pg_catalog.oidvectortypes(p.proargtypes) as identity_arguments,
    pg_catalog.pg_get_function_result(p.oid) as result_type,
    p.prosecdef,
    p.proconfig,
    p.proacl,
    p.proowner,
    pg_catalog.has_function_privilege('anon', p.oid, 'EXECUTE') as anon_execute,
    pg_catalog.has_function_privilege('authenticated', p.oid, 'EXECUTE') as authenticated_execute,
    exists (
      select 1
      from pg_catalog.aclexplode(
        coalesce(p.proacl, pg_catalog.acldefault('f', p.proowner))
      ) as acl
      where acl.grantee = 0
        and acl.privilege_type = 'EXECUTE'
    ) as public_execute
  from pg_catalog.pg_proc as p
  join pg_catalog.pg_namespace as n on n.oid = p.pronamespace
  where n.nspname = 'public'
)
select
  'v1_rpc:' || e.function_name || '(' || e.identity_arguments || ')' as check_name,
  case
    when a.oid is null then 'FAIL'
    when not a.prosecdef then 'FAIL'
    when coalesce(array_to_string(a.proconfig, ','), '') !~ '(^|,)search_path=(""|)(,|$)' then 'FAIL'
    when not a.anon_execute then 'FAIL'
    when a.authenticated_execute or a.public_execute then 'FAIL'
    else 'PASS'
  end as status,
  case
    when a.oid is null then 'missing'
    else 'returns=' || a.result_type ||
      ', security_definer=' || a.prosecdef::text ||
      ', config=' || coalesce(array_to_string(a.proconfig, ','), '<none>') ||
      ', anon_execute=' || a.anon_execute::text ||
      ', authenticated_execute=' || a.authenticated_execute::text ||
      ', public_execute=' || a.public_execute::text
  end as details
from expected_functions as e
left join actual_functions as a
  on a.proname = e.function_name
 and a.identity_arguments = e.identity_arguments
order by check_name
),

check_10 as (
-- 9. Huella reproducible de las definiciones V1 para comparar posteriormente.
select
  'v1_fingerprint:' || p.proname || '(' ||
    pg_catalog.oidvectortypes(p.proargtypes) || ')' as check_name,
  'REVIEW' as status,
  'returns=' || pg_catalog.pg_get_function_result(p.oid) ||
    ', md5=' || md5(pg_catalog.pg_get_functiondef(p.oid)) as details
from pg_catalog.pg_proc as p
join pg_catalog.pg_namespace as n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'activate_game_card',
    'clear_active_card_if_current',
    'get_or_create_vote_round',
    'submit_vote',
    'close_vote_round_if_complete',
    'start_tiebreak_round',
    'resolve_random_tiebreak',
    'mark_round_ready_next',
    'join_game_by_code',
    'get_player_by_session',
    'heartbeat_player',
    'remove_player_from_game'
  )
order by p.proname, pg_catalog.oidvectortypes(p.proargtypes)
),

check_11 as (
-- 10. Existencia y permisos actuales del esquema private.
select
  'private_schema' as check_name,
  case when n.oid is null then 'PASS' else 'REVIEW' end as status,
  case
    when n.oid is null then 'absent, V2 may add it'
    else 'present, owner=' || pg_catalog.pg_get_userbyid(n.nspowner) ||
      ', anon_usage=' || pg_catalog.has_schema_privilege('anon', n.oid, 'USAGE')::text ||
      ', authenticated_usage=' || pg_catalog.has_schema_privilege('authenticated', n.oid, 'USAGE')::text ||
      ', public_usage=' || (exists (
        select 1
        from pg_catalog.aclexplode(
          coalesce(n.nspacl, pg_catalog.acldefault('n', n.nspowner))
        ) as acl
        where acl.grantee = 0
          and acl.privilege_type = 'USAGE'
      ))::text
  end as details
from (values (1)) as seed(value)
left join pg_catalog.pg_namespace as n on n.nspname = 'private'
),

check_12 as (
select
  'private_object:' || n.nspname || '.' || c.relname as check_name,
  'REVIEW' as status,
  'kind=' || c.relkind::text ||
    ', owner=' || pg_catalog.pg_get_userbyid(c.relowner) ||
    ', anon_select=' || pg_catalog.has_table_privilege('anon', c.oid, 'SELECT')::text ||
    ', authenticated_select=' || pg_catalog.has_table_privilege('authenticated', c.oid, 'SELECT')::text ||
    ', public_select=' || (exists (
      select 1
      from pg_catalog.aclexplode(
        coalesce(c.relacl, pg_catalog.acldefault('r', c.relowner))
      ) as acl
      where acl.grantee = 0
        and acl.privilege_type = 'SELECT'
    ))::text as details
from pg_catalog.pg_class as c
join pg_catalog.pg_namespace as n on n.oid = c.relnamespace
where n.nspname = 'private'
order by c.relname
),

check_13 as (
select
  'private_function:' || p.proname || '(' ||
    pg_catalog.oidvectortypes(p.proargtypes) || ')' as check_name,
  'REVIEW' as status,
  'owner=' || pg_catalog.pg_get_userbyid(p.proowner) ||
    ', anon_execute=' || pg_catalog.has_function_privilege('anon', p.oid, 'EXECUTE')::text ||
    ', authenticated_execute=' || pg_catalog.has_function_privilege('authenticated', p.oid, 'EXECUTE')::text ||
    ', public_execute=' || (exists (
      select 1
      from pg_catalog.aclexplode(
        coalesce(p.proacl, pg_catalog.acldefault('f', p.proowner))
      ) as acl
      where acl.grantee = 0
        and acl.privilege_type = 'EXECUTE'
    ))::text as details
from pg_catalog.pg_proc as p
join pg_catalog.pg_namespace as n on n.oid = p.pronamespace
where n.nspname = 'private'
order by p.proname, pg_catalog.oidvectortypes(p.proargtypes)
),

check_14 as (
-- 11. Detección de columnas V2 ya presentes o de instalación parcial.
with v2_columns(table_name, column_name) as (
  values
    ('games', 'flow_version'),
    ('games', 'transition_version'),
    ('games', 'current_vote_round_id'),
    ('vote_rounds', 'source_round_id'),
    ('vote_rounds', 'winning_player_id'),
    ('vote_rounds', 'winning_votes')
)
select
  'preexisting_v2_column:public.' || v.table_name || '.' || v.column_name as check_name,
  case when c.column_name is null then 'PASS' else 'REVIEW' end as status,
  case
    when c.column_name is null then 'absent'
    else 'present, type=' || c.data_type ||
      coalesce(', udt=' || c.udt_name, '')
  end as details
from v2_columns as v
left join information_schema.columns as c
  on c.table_schema = 'public'
 and c.table_name = v.table_name
 and c.column_name = v.column_name
order by check_name
),

check_15 as (
select
  'preexisting_v2_journal:private.v2_operations' as check_name,
  case when c.oid is null then 'PASS' else 'REVIEW' end as status,
  case when c.oid is null then 'absent' else 'present, kind=' || c.relkind::text end as details
from (values (1)) as seed(value)
left join pg_catalog.pg_namespace as n on n.nspname = 'private'
left join pg_catalog.pg_class as c
  on c.relnamespace = n.oid
 and c.relname = 'v2_operations'
),

check_16 as (
select
  'preexisting_v2_function:public.' || p.proname || '(' ||
    pg_catalog.oidvectortypes(p.proargtypes) || ')' as check_name,
  'REVIEW' as status,
  'returns=' || pg_catalog.pg_get_function_result(p.oid) ||
    ', security_definer=' || p.prosecdef::text ||
    ', config=' || coalesce(array_to_string(p.proconfig, ','), '<none>') as details
from pg_catalog.pg_proc as p
join pg_catalog.pg_namespace as n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname like '%\_v2' escape '\'
order by p.proname, pg_catalog.oidvectortypes(p.proargtypes)
),

check_17 as (
-- 12. Conteos estimados sin referenciar directamente relaciones que podrían faltar.
with expected_tables(table_name) as (
  values ('games'), ('players'), ('vote_rounds'), ('votes')
)
select
  'estimated_row_count:public.' || e.table_name as check_name,
  case when c.oid is null then 'FAIL' else 'REVIEW' end as status,
  case
    when c.oid is null then 'table missing'
    else 'estimated_rows=' || greatest(c.reltuples, 0)::bigint::text ||
      ', estimate only, based on planner statistics'
  end as details
from expected_tables as e
left join pg_catalog.pg_namespace as n on n.nspname = 'public'
left join pg_catalog.pg_class as c
  on c.relnamespace = n.oid
 and c.relname = e.table_name
 and c.relkind in ('r', 'p')
order by check_name
),

check_18 as (
-- 13. Riesgo de duplicados: un índice único válido garantiza ausencia de
-- duplicados incompatibles. Si falta, REVIEW requiere una consulta de datos
-- específica después de confirmar que la tabla existe.
with index_columns as (
  select
    t.relname as table_name,
    i.relname as index_name,
    ix.indisunique,
    ix.indisvalid,
    pg_catalog.pg_get_expr(ix.indpred, ix.indrelid) as predicate,
    array_agg(a.attname order by k.ordinality)
      filter (where k.ordinality <= ix.indnkeyatts) as key_columns
  from pg_catalog.pg_index as ix
  join pg_catalog.pg_class as t on t.oid = ix.indrelid
  join pg_catalog.pg_namespace as n on n.oid = t.relnamespace
  join pg_catalog.pg_class as i on i.oid = ix.indexrelid
  left join lateral unnest(ix.indkey) with ordinality as k(attnum, ordinality)
    on true
  left join pg_catalog.pg_attribute as a
    on a.attrelid = t.oid
   and a.attnum = k.attnum
  where n.nspname = 'public'
  group by t.relname, i.relname, ix.indisunique, ix.indisvalid,
           ix.indpred, ix.indrelid
), checks(check_name, table_name, key_columns, partial_active) as (
  values
    ('duplicate_risk:votes(round,session)', 'votes', array['vote_round_id', 'voter_session_id']::name[], false),
    ('duplicate_risk:players(game,active_session)', 'players', array['game_id', 'session_id']::name[], true)
)
select
  x.check_name,
  case when exists (
    select 1
    from index_columns as i
    where i.table_name = x.table_name
      and i.indisunique
      and i.indisvalid
      and i.key_columns = x.key_columns
      and (
        not x.partial_active
        or coalesce(i.predicate, '') ~* 'active[^a-z]*(= *true|IS TRUE|active)'
      )
  ) then 'PASS' else 'REVIEW' end as status,
  case when exists (
    select 1
    from index_columns as i
    where i.table_name = x.table_name
      and i.indisunique
      and i.indisvalid
      and i.key_columns = x.key_columns
      and (
        not x.partial_active
        or coalesce(i.predicate, '') ~* 'active[^a-z]*(= *true|IS TRUE|active)'
      )
  ) then 'valid unique index prevents incompatible duplicates'
    else 'unique protection missing, inspect duplicates before installing V2'
  end as details
from checks as x
order by x.check_name
)
select check_name, status, details
from check_01
union all
select check_name, status, details
from check_02
union all
select check_name, status, details
from check_03
union all
select check_name, status, details
from check_04
union all
select check_name, status, details
from check_05
union all
select check_name, status, details
from check_06
union all
select check_name, status, details
from check_07
union all
select check_name, status, details
from check_08
union all
select check_name, status, details
from check_09
union all
select check_name, status, details
from check_10
union all
select check_name, status, details
from check_11
union all
select check_name, status, details
from check_12
union all
select check_name, status, details
from check_13
union all
select check_name, status, details
from check_14
union all
select check_name, status, details
from check_15
union all
select check_name, status, details
from check_16
union all
select check_name, status, details
from check_17
union all
select check_name, status, details
from check_18
order by check_name;
