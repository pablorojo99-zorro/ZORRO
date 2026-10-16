-- Read-only verification after v2-structural-schema-20261016.sql.
with
expected_columns(table_name, column_name, data_type, not_null, default_pattern) as (
  values
    ('games', 'flow_version', 'smallint', true, '^1'),
    ('games', 'current_vote_round_id', 'uuid', false, null),
    ('games', 'transition_version', 'bigint', true, '^0'),
    ('vote_rounds', 'source_round_id', 'uuid', false, null),
    ('vote_rounds', 'winning_player_id', 'uuid', false, null),
    ('vote_rounds', 'winning_votes', 'integer', false, null)
),
actual_columns as (
  select c.relname as table_name, a.attname as column_name,
    pg_catalog.format_type(a.atttypid, a.atttypmod) as data_type,
    a.attnotnull as not_null,
    pg_catalog.pg_get_expr(d.adbin, d.adrelid) as column_default
  from pg_catalog.pg_attribute as a
  join pg_catalog.pg_class as c on c.oid = a.attrelid
  join pg_catalog.pg_namespace as n on n.oid = c.relnamespace
  left join pg_catalog.pg_attrdef as d
    on d.adrelid = a.attrelid and d.adnum = a.attnum
  where n.nspname = 'public' and a.attnum > 0 and not a.attisdropped
),
column_checks as (
  select 'column:public.' || e.table_name || '.' || e.column_name as check_name,
    case when a.column_name is null then 'FAIL'
      when a.data_type <> e.data_type or a.not_null <> e.not_null then 'FAIL'
      when e.default_pattern is not null
        and coalesce(a.column_default, '') !~ e.default_pattern then 'FAIL'
      else 'PASS' end as status,
    jsonb_build_object('type', a.data_type, 'not_null', a.not_null,
      'default', a.column_default) as details
  from expected_columns as e
  left join actual_columns as a using (table_name, column_name)
),
expected_constraints(check_name, table_name, constraint_type, definition_pattern) as (
  values
    ('constraint:games_flow_version_check', 'games', 'c', 'flow_version.*(1|2)'),
    ('constraint:games_transition_version_check', 'games', 'c', 'transition_version.*>=.*0'),
    ('constraint:games_current_vote_round_same_game_fk', 'games', 'f', 'FOREIGN KEY.*current_vote_round_id.*id.*REFERENCES (public[.])?vote_rounds.*id.*game_id'),
    ('constraint:vote_rounds_source_same_game_card_fk', 'vote_rounds', 'f', 'FOREIGN KEY.*source_round_id.*game_id.*card_id.*REFERENCES (public[.])?vote_rounds'),
    ('constraint:vote_rounds_winning_votes_nonnegative', 'vote_rounds', 'c', 'winning_votes.*>=.*0'),
    ('constraint:historical_winner_fk', 'vote_rounds', 'f', 'FOREIGN KEY.*winning_player_id.*REFERENCES (public[.])?players.*ON DELETE SET NULL')
),
constraint_checks as (
  select e.check_name,
    case when count(con.oid) filter (where pg_catalog.pg_get_constraintdef(con.oid) ~* e.definition_pattern) > 0
      then 'PASS' else 'FAIL' end as status,
    jsonb_build_object('matches', coalesce(jsonb_agg(jsonb_build_object(
      'name', con.conname, 'definition', pg_catalog.pg_get_constraintdef(con.oid),
      'validated', con.convalidated)) filter (where con.oid is not null), '[]'::jsonb)) as details
  from expected_constraints as e
  left join pg_catalog.pg_namespace as n on n.nspname = 'public'
  left join pg_catalog.pg_class as c on c.relnamespace = n.oid and c.relname = e.table_name
  left join pg_catalog.pg_constraint as con
    on con.conrelid = c.oid and con.contype = e.constraint_type::"char"
  group by e.check_name, e.definition_pattern
),
object_checks as (
  select 'schema:private' as check_name,
    case when n.oid is null then 'FAIL'
      when pg_catalog.has_schema_privilege('anon', n.oid, 'USAGE')
        or pg_catalog.has_schema_privilege('authenticated', n.oid, 'USAGE') then 'FAIL'
      else 'PASS' end as status,
    jsonb_build_object('exists', n.oid is not null,
      'anon_usage', coalesce(pg_catalog.has_schema_privilege('anon', n.oid, 'USAGE'), false),
      'authenticated_usage', coalesce(pg_catalog.has_schema_privilege('authenticated', n.oid, 'USAGE'), false)) as details
  from (values (1)) as seed(x)
  left join pg_catalog.pg_namespace as n on n.nspname = 'private'
  union all
  select 'table:private.v2_operations',
    case when c.oid is null then 'FAIL'
      when pg_catalog.has_table_privilege('anon', c.oid, 'SELECT')
        or pg_catalog.has_table_privilege('authenticated', c.oid, 'SELECT') then 'FAIL'
      else 'PASS' end,
    jsonb_build_object('exists', c.oid is not null, 'rls', c.relrowsecurity,
      'anon_select', coalesce(pg_catalog.has_table_privilege('anon', c.oid, 'SELECT'), false),
      'authenticated_select', coalesce(pg_catalog.has_table_privilege('authenticated', c.oid, 'SELECT'), false))
  from (values (1)) as seed(x)
  left join pg_catalog.pg_namespace as n on n.nspname = 'private'
  left join pg_catalog.pg_class as c on c.relnamespace = n.oid
    and c.relname = 'v2_operations' and c.relkind in ('r', 'p')
  union all
  select 'trigger:games_prevent_flow_version_change',
    case when count(*) = 1 and bool_and(not tr.tgisinternal) then 'PASS' else 'FAIL' end,
    jsonb_build_object('count', count(*),
      'definitions', coalesce(jsonb_agg(pg_catalog.pg_get_triggerdef(tr.oid)), '[]'::jsonb))
  from pg_catalog.pg_trigger as tr
  join pg_catalog.pg_class as c on c.oid = tr.tgrelid
  join pg_catalog.pg_namespace as n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relname = 'games'
    and tr.tgname = 'games_prevent_flow_version_change'
),
journal_columns as (
  select 'journal_columns:private.v2_operations' as check_name,
    case when count(*) filter (where a.attname in (
      'game_id','operation_id','actor_player_id','operation_name','request_fingerprint',
      'request_payload','status','result','result_transition_version','created_at','completed_at'
    )) = 11 then 'PASS' else 'FAIL' end as status,
    jsonb_build_object('columns', coalesce(jsonb_agg(a.attname order by a.attnum), '[]'::jsonb)) as details
  from pg_catalog.pg_attribute as a
  join pg_catalog.pg_class as c on c.oid = a.attrelid
  join pg_catalog.pg_namespace as n on n.oid = c.relnamespace
  where n.nspname = 'private' and c.relname = 'v2_operations'
    and a.attnum > 0 and not a.attisdropped
)
select check_name, status, details from column_checks
union all select check_name, status, details from constraint_checks
union all select check_name, status, details from object_checks
union all select check_name, status, details from journal_columns
order by check_name;
