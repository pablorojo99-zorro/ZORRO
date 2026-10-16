-- Read-only verification after v1-flow-guards-block1-20261016.sql.
with
expected(function_name, arguments, result_type, prosrc_md5, advisory_lock) as (
  values
    ('activate_game_card', 'uuid, text, text', 'text', '6f4d5dc514604dc5c700c1e4b53bd097', false),
    ('clear_active_card_if_current', 'uuid, text, text', 'void', '3dc6cdc4da43bad3ce9119712de45156', false),
    ('get_or_create_vote_round', 'uuid, text, text, uuid', 'TABLE(id uuid, status text, tie_player_ids uuid[], card_id uuid)', 'a8815261bcec9584523e894f23181a9f', true)
),
actual as (
  select p.oid, p.proname, pg_catalog.oidvectortypes(p.proargtypes) as arguments,
    pg_catalog.pg_get_function_result(p.oid) as result_type, p.prosecdef,
    coalesce(p.proconfig, array[]::text[]) as configuration, p.prosrc,
    md5(p.prosrc) as prosrc_md5,
    pg_catalog.has_function_privilege('anon', p.oid, 'EXECUTE') as anon_execute,
    pg_catalog.has_function_privilege('authenticated', p.oid, 'EXECUTE') as authenticated_execute,
    exists (select 1 from pg_catalog.aclexplode(coalesce(p.proacl,
      pg_catalog.acldefault('f', p.proowner))) acl
      where acl.grantee = 0 and acl.privilege_type = 'EXECUTE') as public_execute
  from pg_catalog.pg_proc as p
  join pg_catalog.pg_namespace as n on n.oid = p.pronamespace
  where n.nspname = 'public'
),
checks as (
  select 'v1_guard_block1:' || e.function_name || '(' || e.arguments || ')' as check_name,
    case when a.oid is null or a.result_type <> e.result_type or not a.prosecdef
      or not ('search_path=""' = any(a.configuration)) or not a.anon_execute
      or a.authenticated_execute or a.public_execute
      or a.prosrc !~ 'client_upgrade_required'
      or (e.advisory_lock and a.prosrc !~ 'pg_advisory_xact_lock')
      or a.prosrc_md5 <> e.prosrc_md5 then 'FAIL' else 'PASS' end as status,
    jsonb_build_object('expected_result', e.result_type, 'actual_result', a.result_type,
      'security_definer', a.prosecdef, 'configuration', a.configuration,
      'anon_execute', a.anon_execute, 'authenticated_execute', a.authenticated_execute,
      'public_execute', a.public_execute, 'has_flow_guard', coalesce(a.prosrc ~ 'client_upgrade_required', false),
      'expected_md5', e.prosrc_md5, 'actual_md5', a.prosrc_md5) as details
  from expected as e left join actual as a
    on a.proname = e.function_name and a.arguments = e.arguments
)
select check_name, status, details from checks order by check_name;
