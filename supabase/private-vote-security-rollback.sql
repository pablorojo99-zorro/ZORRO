-- Roll back private-vote-security.sql using the backup tables created by that migration.
-- Keep this file next to the forward migration; do not run unless you need to revert.

begin;

drop trigger if exists players_emit_changed on public.players;
drop trigger if exists games_emit_changed on public.games;
drop trigger if exists votes_emit_changed on public.votes;
drop trigger if exists rounds_emit_changed on public.vote_rounds;

drop function if exists public.emit_players_changed();
drop function if exists public.emit_game_changed();
drop function if exists public.emit_votes_changed();
drop function if exists public.emit_round_changed();
drop function if exists public.get_player_by_session(text);
drop function if exists public.get_vote_state(uuid, text);
drop function if exists public.get_round_result(uuid, text);

drop view if exists public.public_players;
drop view if exists public.public_games;

do $$
declare
  v_table text;
begin
  if exists (
    select 1
    from pg_catalog.pg_publication
    where pubname = 'supabase_realtime'
  ) then
    if exists (
      select 1
      from pg_catalog.pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'public'
        and tablename = 'realtime_events'
    ) then
      alter publication supabase_realtime drop table public.realtime_events;
    end if;

    foreach v_table in array array['games', 'players', 'votes']
    loop
      if not exists (
        select 1
        from pg_catalog.pg_publication_tables
        where pubname = 'supabase_realtime'
          and schemaname = 'public'
          and tablename = v_table
      ) then
        execute format('alter publication supabase_realtime add table public.%I', v_table);
      end if;
    end loop;
  end if;
end;
$$;

drop table if exists public.realtime_events;

revoke select (
  id,
  code,
  status,
  active_card_slug,
  current_round_number
) on table public.games from anon;

revoke select (
  id,
  game_id,
  name,
  is_host,
  active,
  created_at
) on table public.players from anon;

revoke all on table public.games from anon, authenticated;
revoke all on table public.players from anon, authenticated;
revoke all on table public.votes from anon, authenticated;

do $$
declare
  v_policy record;
begin
  for v_policy in
    select schemaname, tablename, policyname
    from pg_catalog.pg_policies
    where schemaname = 'public'
      and tablename in ('games', 'players', 'vote_rounds', 'votes')
  loop
    execute format(
      'drop policy if exists %I on %I.%I',
      v_policy.policyname,
      v_policy.schemaname,
      v_policy.tablename
    );
  end loop;
end;
$$;

do $$
declare
  v_policy record;
  v_sql text;
  v_roles text;
begin
  for v_policy in
    select *
    from public.security_backup_20260713_policies
    where schemaname = 'public'
      and tablename in ('games', 'players', 'vote_rounds', 'votes')
  loop
    select string_agg(quote_ident(v_role::text), ', ')
      into v_roles
    from unnest(v_policy.roles) as v_role;

    v_sql := format(
      'create policy %I on %I.%I as %s for %s to %s',
      v_policy.policyname,
      v_policy.schemaname,
      v_policy.tablename,
      v_policy.permissive,
      v_policy.cmd,
      coalesce(v_roles, 'public')
    );

    if v_policy.qual is not null then
      v_sql := v_sql || format(' using (%s)', v_policy.qual);
    end if;

    if v_policy.with_check is not null then
      v_sql := v_sql || format(' with check (%s)', v_policy.with_check);
    end if;

    execute v_sql;
  end loop;
end;
$$;

do $$
declare
  v_grant record;
begin
  for v_grant in
    select grantee, table_schema, table_name, privilege_type
    from public.security_backup_20260713_table_grants
    where table_schema = 'public'
      and table_name in ('games', 'players', 'vote_rounds', 'votes')
  loop
    execute format(
      'grant %s on table %I.%I to %I',
      v_grant.privilege_type,
      v_grant.table_schema,
      v_grant.table_name,
      v_grant.grantee
    );
  end loop;
end;
$$;

commit;
