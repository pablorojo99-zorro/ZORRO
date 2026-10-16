-- EL GALLINERO V2: diagnóstico de diferencias estructurales detectadas.
-- Ejecutar manualmente. Una sola sentencia, únicamente de lectura.

with
column_metadata as (
  select
    c.relname as table_name,
    a.attname as column_name,
    pg_catalog.format_type(a.atttypid, a.atttypmod) as data_type,
    a.attnotnull as not_null,
    pg_catalog.pg_get_expr(d.adbin, d.adrelid) as column_default
  from pg_catalog.pg_attribute as a
  join pg_catalog.pg_class as c on c.oid = a.attrelid
  join pg_catalog.pg_namespace as n on n.oid = c.relnamespace
  left join pg_catalog.pg_attrdef as d
    on d.adrelid = a.attrelid
   and d.adnum = a.attnum
  where n.nspname = 'public'
    and (
      (c.relname = 'players' and a.attname = 'created_at')
      or (
        c.relname = 'vote_rounds'
        and a.attname in (
          'created_at',
          'winning_player_id',
          'winning_votes'
        )
      )
    )
    and a.attnum > 0
    and not a.attisdropped
),
column_definition_checks as (
  select
    'column_definition:public.' || e.table_name || '.' || e.column_name as check_name,
    case
      when m.column_name is null then 'FAIL'
      when m.data_type <> e.expected_type then 'FAIL'
      else 'REVIEW'
    end as status,
    jsonb_build_object(
      'expected_type', e.expected_type,
      'actual_type', m.data_type,
      'not_null', m.not_null,
      'default', m.column_default
    ) as details
  from (
    values
      ('players', 'created_at', 'timestamp with time zone'),
      ('vote_rounds', 'created_at', 'timestamp with time zone'),
      ('vote_rounds', 'winning_player_id', 'uuid'),
      ('vote_rounds', 'winning_votes', 'integer')
  ) as e(table_name, column_name, expected_type)
  left join column_metadata as m
    on m.table_name = e.table_name
   and m.column_name = e.column_name
),
null_count_checks as (
  select
    'null_count:public.players.created_at' as check_name,
    case when count(*) filter (where p.created_at is null) = 0
      then 'PASS' else 'REVIEW' end as status,
    jsonb_build_object(
      'null_rows', count(*) filter (where p.created_at is null),
      'total_rows', count(*)
    ) as details
  from public.players as p

  union all

  select
    'null_count:public.vote_rounds.created_at',
    case when count(*) filter (where vr.created_at is null) = 0
      then 'PASS' else 'REVIEW' end,
    jsonb_build_object(
      'null_rows', count(*) filter (where vr.created_at is null),
      'total_rows', count(*)
    )
  from public.vote_rounds as vr
),
result_value_checks as (
  select
    'round_count:winning_player_id_not_null' as check_name,
    'REVIEW' as status,
    jsonb_build_object('round_count', count(*)) as details
  from public.vote_rounds as vr
  where vr.winning_player_id is not null

  union all

  select
    'round_count:winning_votes_not_null',
    'REVIEW',
    jsonb_build_object('round_count', count(*))
  from public.vote_rounds as vr
  where vr.winning_votes is not null

  union all

  select
    'round_count:winning_votes_negative',
    case when count(*) = 0 then 'PASS' else 'FAIL' end,
    jsonb_build_object('round_count', count(*))
  from public.vote_rounds as vr
  where vr.winning_votes < 0
),
winning_constraint_checks as (
  select
    'constraints:public.vote_rounds.' || e.column_name as check_name,
    case
      when count(con.oid) = 0 then 'REVIEW'
      else 'REVIEW'
    end as status,
    jsonb_build_object(
      'constraint_count', count(con.oid),
      'constraints', coalesce(
        jsonb_agg(
          jsonb_build_object(
            'name', con.conname,
            'type', con.contype,
            'definition', pg_catalog.pg_get_constraintdef(con.oid),
            'delete_action', con.confdeltype,
            'validated', con.convalidated
          ) order by con.conname
        ) filter (where con.oid is not null),
        '[]'::jsonb
      )
    ) as details
  from (
    values ('winning_player_id'), ('winning_votes')
  ) as e(column_name)
  left join pg_catalog.pg_namespace as n on n.nspname = 'public'
  left join pg_catalog.pg_class as c
    on c.relnamespace = n.oid
   and c.relname = 'vote_rounds'
  left join pg_catalog.pg_attribute as a
    on a.attrelid = c.oid
   and a.attname = e.column_name
   and a.attnum > 0
   and not a.attisdropped
  left join pg_catalog.pg_constraint as con
    on con.conrelid = c.oid
   and a.attnum = any(con.conkey)
   and con.contype in ('c', 'f')
  group by e.column_name
),
winner_fk_summary as (
  select
    coalesce(bool_or(con.confdeltype = 'n'), false) as has_on_delete_set_null_fk,
    coalesce(
      jsonb_agg(jsonb_build_object(
        'name', con.conname,
        'definition', pg_catalog.pg_get_constraintdef(con.oid)
      ) order by con.conname) filter (where con.oid is not null),
      '[]'::jsonb
    ) as foreign_keys
  from pg_catalog.pg_namespace as n
  join pg_catalog.pg_class as c
    on c.relnamespace = n.oid
   and c.relname = 'vote_rounds'
  join pg_catalog.pg_attribute as a
    on a.attrelid = c.oid
   and a.attname = 'winning_player_id'
  left join pg_catalog.pg_constraint as con
    on con.conrelid = c.oid
   and con.contype = 'f'
   and a.attnum = any(con.conkey)
  where n.nspname = 'public'
),
winner_data_summary as (
  select
    count(*) filter (
      where vr.winning_player_id is not null
    ) as nonnull_references,
    count(*) filter (
      where vr.winning_player_id is not null and p.id is not null
    ) as matching_players,
    count(*) filter (
      where vr.winning_player_id is not null and p.id is null
    ) as orphan_references,
    count(*) filter (
      where vr.winning_player_id is not null
        and p.id is not null
        and p.active = false
    ) as inactive_player_references
  from public.vote_rounds as vr
  left join public.players as p on p.id = vr.winning_player_id
),
winner_reference_check as (
  select
    'winner_reference_persistence' as check_name,
    case
      when d.orphan_references > 0 then 'FAIL'
      when f.has_on_delete_set_null_fk then 'REVIEW'
      else 'PASS'
    end as status,
    jsonb_build_object(
      'nonnull_references', d.nonnull_references,
      'matching_players', d.matching_players,
      'orphan_references', d.orphan_references,
      'inactive_player_references', d.inactive_player_references,
      'has_on_delete_set_null_fk', f.has_on_delete_set_null_fk,
      'foreign_keys', f.foreign_keys
    ) as details
  from winner_data_summary as d
  cross join winner_fk_summary as f
),
relevant_index_check as (
  select
    'relevant_indexes:players_and_vote_rounds' as check_name,
    'REVIEW' as status,
    jsonb_build_object(
      'index_count', count(*),
      'indexes', coalesce(
        jsonb_agg(
          jsonb_build_object(
            'table', t.relname,
            'name', i.relname,
            'valid', ix.indisvalid,
            'unique', ix.indisunique,
            'definition', pg_catalog.pg_get_indexdef(i.oid)
          ) order by t.relname, i.relname
        ),
        '[]'::jsonb
      )
    ) as details
  from pg_catalog.pg_index as ix
  join pg_catalog.pg_class as t on t.oid = ix.indrelid
  join pg_catalog.pg_namespace as n on n.oid = t.relnamespace
  join pg_catalog.pg_class as i on i.oid = ix.indexrelid
  where n.nspname = 'public'
    and t.relname in ('players', 'vote_rounds')
),
function_writer_check as (
  select
    'catalog_functions_writing_winner_columns' as check_name,
    case when count(*) = 0 then 'PASS' else 'REVIEW' end as status,
    jsonb_build_object(
      'function_count', count(*),
      'functions', coalesce(
        jsonb_agg(
          pg_catalog.format(
            '%I.%I(%s)',
            n.nspname,
            p.proname,
            pg_catalog.oidvectortypes(p.proargtypes)
          ) order by n.nspname, p.proname,
            pg_catalog.oidvectortypes(p.proargtypes)
        ),
        '[]'::jsonb
      )
    ) as details
  from pg_catalog.pg_proc as p
  join pg_catalog.pg_namespace as n on n.oid = p.pronamespace
  where p.prosrc ~* '\m(winning_player_id|winning_votes)\M[[:space:]]*='
),
trigger_writer_check as (
  select
    'vote_rounds_triggers_writing_winner_columns' as check_name,
    case when count(*) = 0 then 'PASS' else 'REVIEW' end as status,
    jsonb_build_object(
      'trigger_count', count(*),
      'triggers', coalesce(
        jsonb_agg(
          jsonb_build_object(
            'name', tr.tgname,
            'function', pg_catalog.format(
              '%I.%I(%s)',
              fn_ns.nspname,
              fn.proname,
              pg_catalog.oidvectortypes(fn.proargtypes)
            ),
            'definition', pg_catalog.pg_get_triggerdef(tr.oid)
          ) order by tr.tgname
        ),
        '[]'::jsonb
      )
    ) as details
  from pg_catalog.pg_trigger as tr
  join pg_catalog.pg_class as c on c.oid = tr.tgrelid
  join pg_catalog.pg_namespace as n on n.oid = c.relnamespace
  join pg_catalog.pg_proc as fn on fn.oid = tr.tgfoid
  join pg_catalog.pg_namespace as fn_ns on fn_ns.oid = fn.pronamespace
  where n.nspname = 'public'
    and c.relname = 'vote_rounds'
    and not tr.tgisinternal
    and fn.prosrc ~* '\m(winning_player_id|winning_votes)\M[[:space:]]*='
),
all_checks as (
  select check_name, status, details from column_definition_checks
  union all
  select check_name, status, details from null_count_checks
  union all
  select check_name, status, details from result_value_checks
  union all
  select check_name, status, details from winning_constraint_checks
  union all
  select check_name, status, details from winner_reference_check
  union all
  select check_name, status, details from relevant_index_check
  union all
  select check_name, status, details from function_writer_check
  union all
  select check_name, status, details from trigger_writer_check
)
select check_name, status, details
from all_checks
order by check_name;
