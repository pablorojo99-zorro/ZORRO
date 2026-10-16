-- Read-only verification after v1-flow-guards-block2-20261016.sql.
with
expected(function_name, arguments, prosrc_md5, needs_for_update, needs_advisory) as (
  values
    ('submit_vote', 'uuid, text, uuid', 'b1c257014ce86c6a6fca8b3427a4856e', true, false),
    ('close_vote_round_if_complete', 'uuid, text', 'f698bd42972e12d3eaa45217f5e15964', true, false),
    ('get_vote_state', 'uuid, text', '71ec97c7a4386be93107790332873d94', false, false),
    ('get_round_result', 'uuid, text', '54dcb680be12c6a3e8cfa31039c3b025', false, false),
    ('start_tiebreak_round', 'uuid, text, uuid[]', 'dc6f3776bfba7e4b91037987be2e90b2', true, true),
    ('resolve_random_tiebreak', 'uuid, text, uuid[]', '0c026d03f78924c483ac5b4206d93d85', true, true),
    ('mark_round_ready_next', 'uuid, text', '37b8b5438c3199b763899e8e39db10c3', true, false),
    ('join_game_by_code', 'text, text, text', '0f09a8e3f3d53f25152dcb164aac99b0', false, true),
    ('get_player_by_session', 'text, text', 'c3cb117049886c2267357de3e5d370d3', false, false),
    ('heartbeat_player', 'text, uuid', '6339d8b65323ca31e84dff043cf3982a', false, false),
    ('remove_player_from_game', 'text, uuid', 'e3abc91763bf97b0b37bc09c9f40916c', false, false)
),
actual as (
  select p.oid, p.proname, pg_catalog.oidvectortypes(p.proargtypes) as arguments,
    p.prosecdef, coalesce(p.proconfig, array[]::text[]) as configuration,
    p.prosrc, md5(p.prosrc) as prosrc_md5,
    pg_catalog.has_function_privilege('anon', p.oid, 'EXECUTE') as anon_execute,
    pg_catalog.has_function_privilege('authenticated', p.oid, 'EXECUTE') as authenticated_execute,
    exists (select 1 from pg_catalog.aclexplode(coalesce(p.proacl,
      pg_catalog.acldefault('f', p.proowner))) acl
      where acl.grantee = 0 and acl.privilege_type = 'EXECUTE') as public_execute
  from pg_catalog.pg_proc as p join pg_catalog.pg_namespace as n on n.oid = p.pronamespace
  where n.nspname = 'public'
),
function_checks as (
  select 'v1_guard_block2:' || e.function_name || '(' || e.arguments || ')' as check_name,
    case when a.oid is null or not a.prosecdef or not ('search_path=""' = any(a.configuration))
      or not a.anon_execute or a.authenticated_execute or a.public_execute
      or a.prosrc !~ 'client_upgrade_required'
      or (e.needs_for_update and a.prosrc !~* '\mfor[[:space:]]+update\M')
      or (e.needs_advisory and a.prosrc !~ 'pg_advisory_xact_lock')
      or a.prosrc_md5 <> e.prosrc_md5 then 'FAIL' else 'PASS' end as status,
    jsonb_build_object('security_definer', a.prosecdef, 'configuration', a.configuration,
      'anon_execute', a.anon_execute, 'authenticated_execute', a.authenticated_execute,
      'public_execute', a.public_execute, 'has_flow_guard', coalesce(a.prosrc ~ 'client_upgrade_required', false),
      'has_for_update', coalesce(a.prosrc ~* '\mfor[[:space:]]+update\M', false),
      'has_advisory_lock', coalesce(a.prosrc ~ 'pg_advisory_xact_lock', false),
      'expected_md5', e.prosrc_md5, 'actual_md5', a.prosrc_md5) as details
  from expected as e left join actual as a
    on a.proname = e.function_name and a.arguments = e.arguments
),
overload_check as (
  select 'v1_guard_block2:unexpected_overloads' as check_name,
    case when count(*) = 0 then 'PASS' else 'REVIEW' end as status,
    jsonb_build_object('count', count(*), 'signatures', coalesce(jsonb_agg(
      a.proname || '(' || a.arguments || ')' order by a.proname, a.arguments), '[]'::jsonb)) as details
  from actual as a where a.proname in (select function_name from expected)
    and not exists (select 1 from expected as e
      where e.function_name = a.proname and e.arguments = a.arguments)
)
select check_name, status, details from function_checks
union all select check_name, status, details from overload_check
order by check_name;
