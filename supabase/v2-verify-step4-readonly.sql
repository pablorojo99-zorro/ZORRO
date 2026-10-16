-- Read-only verification after v2-game-lifecycle-rpcs-20261016.sql.
with
expected(function_name, arguments, result_type) as (
  values
    ('create_game_with_host_v2', 'text, text, text', 'TABLE(game_id uuid, code text)'),
    ('join_game_by_code_v2', 'text, text, text', 'TABLE(game_id uuid, code text)'),
    ('get_player_by_session_v2', 'text, text', 'TABLE(player_id uuid, game_id uuid, name text, code text, is_host boolean)'),
    ('heartbeat_player_v2', 'text, uuid', 'void'),
    ('remove_player_from_game_v2', 'text, uuid', 'void')
),
actual as (
  select p.oid, p.proname, pg_catalog.oidvectortypes(p.proargtypes) as arguments,
    pg_catalog.pg_get_function_result(p.oid) as result_type, p.prosecdef,
    coalesce(p.proconfig, array[]::text[]) as configuration,
    pg_catalog.has_function_privilege('anon', p.oid, 'EXECUTE') as anon_execute,
    pg_catalog.has_function_privilege('authenticated', p.oid, 'EXECUTE') as authenticated_execute,
    exists (select 1 from pg_catalog.aclexplode(coalesce(p.proacl,
      pg_catalog.acldefault('f', p.proowner))) acl
      where acl.grantee = 0 and acl.privilege_type = 'EXECUTE') as public_execute
  from pg_catalog.pg_proc as p join pg_catalog.pg_namespace as n on n.oid = p.pronamespace
  where n.nspname = 'public'
)
select 'v2_lifecycle:' || e.function_name || '(' || e.arguments || ')' as check_name,
  case when a.oid is null or a.result_type <> e.result_type or not a.prosecdef
    or not ('search_path=""' = any(a.configuration)) or not a.anon_execute
    or a.authenticated_execute or a.public_execute then 'FAIL' else 'PASS' end as status,
  jsonb_build_object('expected_result', e.result_type, 'actual_result', a.result_type,
    'security_definer', a.prosecdef, 'configuration', a.configuration,
    'anon_execute', a.anon_execute, 'authenticated_execute', a.authenticated_execute,
    'public_execute', a.public_execute) as details
from expected as e left join actual as a
  on a.proname = e.function_name and a.arguments = e.arguments
order by check_name;
