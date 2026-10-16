-- Read-only verification after v2-round-engine-rpcs-20261016.sql.
with
expected_public(function_name, arguments) as (
  values
    ('activate_game_card_v2', 'uuid, text, text, uuid, bigint'),
    ('submit_vote_v2', 'uuid, text, uuid, uuid, bigint'),
    ('close_vote_round_if_complete_v2', 'uuid, text, uuid, bigint'),
    ('start_tiebreak_round_v2', 'uuid, text, uuid, bigint'),
    ('resolve_random_tiebreak_v2', 'uuid, text, uuid, bigint'),
    ('mark_round_ready_next_v2', 'uuid, text, uuid, bigint'),
    ('get_canonical_game_state_v2', 'uuid, text')
),
expected_private(function_name, arguments) as (
  values
    ('prepare_v2_operation', 'uuid, text, uuid, text, jsonb, bigint'),
    ('complete_v2_operation', 'uuid, uuid, jsonb, bigint')
),
functions as (
  select n.nspname, p.oid, p.proname,
    pg_catalog.oidvectortypes(p.proargtypes) as arguments,
    pg_catalog.pg_get_function_result(p.oid) as result_type, p.prosecdef,
    coalesce(p.proconfig, array[]::text[]) as configuration, p.prosrc,
    pg_catalog.has_function_privilege('anon', p.oid, 'EXECUTE') as anon_execute,
    pg_catalog.has_function_privilege('authenticated', p.oid, 'EXECUTE') as authenticated_execute,
    exists (select 1 from pg_catalog.aclexplode(coalesce(p.proacl,
      pg_catalog.acldefault('f', p.proowner))) acl
      where acl.grantee = 0 and acl.privilege_type = 'EXECUTE') as public_execute
  from pg_catalog.pg_proc as p join pg_catalog.pg_namespace as n on n.oid = p.pronamespace
  where n.nspname in ('public', 'private')
),
public_checks as (
  select 'v2_round_rpc:' || e.function_name || '(' || e.arguments || ')' as check_name,
    case when f.oid is null or f.result_type <> 'jsonb' or not f.prosecdef
      or not ('search_path=""' = any(f.configuration)) or not f.anon_execute
      or f.authenticated_execute or f.public_execute then 'FAIL' else 'PASS' end as status,
    jsonb_build_object('result', f.result_type, 'security_definer', f.prosecdef,
      'configuration', f.configuration, 'anon_execute', f.anon_execute,
      'authenticated_execute', f.authenticated_execute, 'public_execute', f.public_execute) as details
  from expected_public as e left join functions as f
    on f.nspname = 'public' and f.proname = e.function_name and f.arguments = e.arguments
),
private_checks as (
  select 'v2_private:' || e.function_name || '(' || e.arguments || ')' as check_name,
    case when f.oid is null or not f.prosecdef
      or not ('search_path=""' = any(f.configuration))
      or f.anon_execute or f.authenticated_execute or f.public_execute then 'FAIL' else 'PASS' end as status,
    jsonb_build_object('result', f.result_type, 'security_definer', f.prosecdef,
      'configuration', f.configuration, 'anon_execute', f.anon_execute,
      'authenticated_execute', f.authenticated_execute, 'public_execute', f.public_execute) as details
  from expected_private as e left join functions as f
    on f.nspname = 'private' and f.proname = e.function_name and f.arguments = e.arguments
),
cas_check as (
  select 'v2_cas:null_safe_transition_version' as check_name,
    case when f.oid is not null
      and f.prosrc ~* 'transition_version[[:space:]]+is[[:space:]]+distinct[[:space:]]+from[[:space:]]+p_expected_transition_version'
      and f.prosrc !~* 'transition_version[[:space:]]*<>[[:space:]]*p_expected_transition_version'
      then 'PASS' else 'FAIL' end as status,
    jsonb_build_object('function_exists', f.oid is not null,
      'has_null_safe_cas', coalesce(f.prosrc ~* 'transition_version[[:space:]]+is[[:space:]]+distinct[[:space:]]+from[[:space:]]+p_expected_transition_version', false)) as details
  from (values (1)) seed(x) left join functions as f
    on f.nspname = 'private' and f.proname = 'prepare_v2_operation'
      and f.arguments = 'uuid, text, uuid, text, jsonb, bigint'
),
journal_check as (
  select 'v2_journal:idempotency_structure' as check_name,
    case when c.oid is null then 'FAIL'
      when count(distinct a.attname) filter (where a.attname in (
        'game_id','operation_id','actor_player_id','operation_name','request_fingerprint',
        'request_payload','status','result','result_transition_version','created_at','completed_at'
      )) = 11
      and count(con.oid) filter (where con.contype = 'p') > 0
      and c.relrowsecurity then 'PASS' else 'FAIL' end as status,
    jsonb_build_object('exists', c.oid is not null, 'rls', c.relrowsecurity,
      'column_count', count(distinct a.attname),
      'constraints', coalesce(jsonb_agg(distinct con.conname) filter (where con.oid is not null), '[]'::jsonb)) as details
  from (values (1)) seed(x)
  left join pg_catalog.pg_namespace as n on n.nspname = 'private'
  left join pg_catalog.pg_class as c on c.relnamespace = n.oid and c.relname = 'v2_operations'
  left join pg_catalog.pg_attribute as a on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
  left join pg_catalog.pg_constraint as con on con.conrelid = c.oid
  group by c.oid, c.relrowsecurity
)
select check_name, status, details from public_checks
union all select check_name, status, details from private_checks
union all select check_name, status, details from cas_check
union all select check_name, status, details from journal_check
order by check_name;
