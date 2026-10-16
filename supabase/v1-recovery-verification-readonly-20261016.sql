-- Read-only verification for the five hardened V1 RPCs restored remotely.
-- Run manually in Supabase SQL Editor. This file only reads PostgreSQL catalogs.

with expected (
  function_name,
  argument_types,
  result_type,
  expected_prosrc_md5,
  requires_for_update,
  requires_advisory_lock
) as (
  values
    ('submit_vote', 'uuid, text, uuid', 'void', '7752a32e7845f2e34e88b428cfbf98ef', true, false),
    ('close_vote_round_if_complete', 'uuid, text', 'void', 'ebeb24c468b671aa358fa9051f89e4a6', true, false),
    ('start_tiebreak_round', 'uuid, text, uuid[]', 'uuid', '4c736cf19366980d91a45c56371552c0', true, true),
    ('resolve_random_tiebreak', 'uuid, text, uuid[]', 'uuid', '095fafb0a2ffb1c99ded5f5dc7b8896d', true, true),
    ('mark_round_ready_next', 'uuid, text', 'text', '020787806b2f24097f4acf9ff992a110', true, false)
),
actual as (
  select
    p.oid,
    p.proname as function_name,
    pg_catalog.oidvectortypes(p.proargtypes) as argument_types,
    pg_catalog.pg_get_function_result(p.oid) as result_type,
    p.prosecdef as security_definer,
    coalesce(p.proconfig, array[]::text[]) as configuration,
    p.prosrc,
    md5(p.prosrc) as prosrc_md5,
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
  join pg_catalog.pg_namespace as n
    on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname in (
      'submit_vote',
      'close_vote_round_if_complete',
      'start_tiebreak_round',
      'resolve_random_tiebreak',
      'mark_round_ready_next'
    )
),
function_checks as (
select
  e.function_name || '(' || e.argument_types || ')' as check_name,
  case
    when a.oid is null then 'FAIL'
    when a.result_type <> e.result_type then 'FAIL'
    when not a.security_definer then 'FAIL'
    when not ('search_path=""' = any(a.configuration)) then 'FAIL'
    when not a.anon_execute then 'FAIL'
    when a.authenticated_execute or a.public_execute then 'FAIL'
    when e.requires_for_update
      and a.prosrc !~* '\mfor[[:space:]]+update\M' then 'FAIL'
    when e.requires_advisory_lock
      and a.prosrc !~* '\mpg_advisory_xact_lock\M' then 'FAIL'
    when a.prosrc_md5 <> e.expected_prosrc_md5 then 'FAIL'
    else 'PASS'
  end as status,
  jsonb_build_object(
    'exists', a.oid is not null,
    'expected_arguments', e.argument_types,
    'actual_arguments', a.argument_types,
    'expected_result', e.result_type,
    'actual_result', a.result_type,
    'security_definer', a.security_definer,
    'configuration', a.configuration,
    'anon_execute', a.anon_execute,
    'authenticated_execute', a.authenticated_execute,
    'public_execute', a.public_execute,
    'has_for_update', coalesce(a.prosrc ~* '\mfor[[:space:]]+update\M', false),
    'requires_advisory_lock', e.requires_advisory_lock,
    'has_advisory_lock', coalesce(a.prosrc ~* '\mpg_advisory_xact_lock\M', false),
    'expected_prosrc_md5', e.expected_prosrc_md5,
    'actual_prosrc_md5', a.prosrc_md5
  ) as details
from expected as e
left join actual as a
  on a.function_name = e.function_name
 and a.argument_types = e.argument_types
),
unexpected_overloads_check as (
select
  'unexpected_overloads_of_recovered_v1_rpcs' as check_name,
  case when count(*) = 0 then 'PASS' else 'REVIEW' end as status,
  jsonb_build_object(
    'count', count(*),
    'signatures', coalesce(
      jsonb_agg(
        pg_catalog.format(
          '%I.%I(%s)',
          n.nspname,
          p.proname,
          pg_catalog.oidvectortypes(p.proargtypes)
        )
        order by p.proname, pg_catalog.oidvectortypes(p.proargtypes)
      ) filter (where p.oid is not null),
      '[]'::jsonb
    )
  ) as details
from pg_catalog.pg_proc as p
join pg_catalog.pg_namespace as n
  on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'submit_vote',
    'close_vote_round_if_complete',
    'start_tiebreak_round',
    'resolve_random_tiebreak',
    'mark_round_ready_next'
  )
  and (p.proname, pg_catalog.oidvectortypes(p.proargtypes)) not in (
    ('submit_vote', 'uuid, text, uuid'),
    ('close_vote_round_if_complete', 'uuid, text'),
    ('start_tiebreak_round', 'uuid, text, uuid[]'),
    ('resolve_random_tiebreak', 'uuid, text, uuid[]'),
    ('mark_round_ready_next', 'uuid, text')
  )
)
select check_name, status, details
from function_checks
union all
select check_name, status, details
from unexpected_overloads_check
order by check_name;
