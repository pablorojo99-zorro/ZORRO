-- Private vote security hardening.
-- Apply after secure-game-flow.sql and vote-security.sql.
-- This keeps public game UX working while hiding votes, session_id, and host_session_id.

begin;

create table if not exists public.security_backup_20260713_policies as
select *
from pg_policies
where schemaname = 'public'
  and tablename in ('games', 'players', 'vote_rounds', 'votes', 'realtime_events');

create table if not exists public.security_backup_20260713_table_grants as
select *
from information_schema.role_table_grants
where table_schema = 'public'
  and table_name in ('games', 'players', 'vote_rounds', 'votes', 'realtime_events');

alter table public.security_backup_20260713_policies enable row level security;
alter table public.security_backup_20260713_table_grants enable row level security;
revoke all on table public.security_backup_20260713_policies from anon, authenticated;
revoke all on table public.security_backup_20260713_table_grants from anon, authenticated;

alter table public.cards enable row level security;
alter table public.games enable row level security;
alter table public.players enable row level security;
alter table public.vote_rounds enable row level security;
alter table public.votes enable row level security;

drop policy if exists "games are publicly readable for the game flow" on public.games;
drop policy if exists "players are publicly readable for the game flow" on public.players;
drop policy if exists "votes are publicly readable for the game flow" on public.votes;

revoke all on table public.games from anon, authenticated;
revoke all on table public.players from anon, authenticated;
revoke all on table public.votes from anon, authenticated;

grant select (
  id,
  code,
  status,
  active_card_slug,
  current_round_number
) on table public.games to anon;

grant select (
  id,
  game_id,
  name,
  is_host,
  active,
  created_at
) on table public.players to anon;

drop policy if exists "anon can read non-secret active games" on public.games;
create policy "anon can read non-secret active games"
  on public.games
  for select
  to anon
  using (status in ('lobby', 'active'));

drop policy if exists "anon can read non-secret active players" on public.players;
create policy "anon can read non-secret active players"
  on public.players
  for select
  to anon
  using (active = true);

drop view if exists public.public_players;
create view public.public_players
with (security_invoker = true, security_barrier = true)
as
select
  id,
  game_id,
  name,
  is_host,
  active,
  created_at
from public.players
where active = true;

drop view if exists public.public_games;
create view public.public_games
with (security_invoker = true, security_barrier = true)
as
select
  id,
  code,
  status,
  active_card_slug,
  current_round_number
from public.games
where status in ('lobby', 'active');

grant select on public.public_players to anon;
grant select on public.public_games to anon;

create table if not exists public.realtime_events (
  id uuid primary key default gen_random_uuid(),
  game_id uuid,
  vote_round_id uuid,
  event_type text not null,
  created_at timestamptz not null default now()
);

alter table public.realtime_events enable row level security;

drop policy if exists "anon can read realtime event signals" on public.realtime_events;
create policy "anon can read realtime event signals"
  on public.realtime_events
  for select
  to anon
  using (event_type in ('game_changed', 'players_changed', 'round_changed', 'votes_changed'));

revoke all on table public.realtime_events from anon, authenticated;
grant select on public.realtime_events to anon;

create or replace function public.emit_players_changed()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.realtime_events (game_id, event_type)
  values (coalesce(new.game_id, old.game_id), 'players_changed');

  return coalesce(new, old);
end;
$$;

create or replace function public.emit_game_changed()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.realtime_events (game_id, event_type)
  values (coalesce(new.id, old.id), 'game_changed');

  return coalesce(new, old);
end;
$$;

create or replace function public.emit_votes_changed()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_game_id uuid;
  v_round_id uuid;
begin
  v_round_id := coalesce(new.vote_round_id, old.vote_round_id);

  select vr.game_id
    into v_game_id
  from public.vote_rounds as vr
  where vr.id = v_round_id;

  insert into public.realtime_events (game_id, vote_round_id, event_type)
  values (v_game_id, v_round_id, 'votes_changed');

  return coalesce(new, old);
end;
$$;

create or replace function public.emit_round_changed()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.realtime_events (game_id, vote_round_id, event_type)
  values (
    coalesce(new.game_id, old.game_id),
    coalesce(new.id, old.id),
    'round_changed'
  );

  return coalesce(new, old);
end;
$$;

drop trigger if exists players_emit_changed on public.players;
create trigger players_emit_changed
after insert or update or delete on public.players
for each row execute function public.emit_players_changed();

drop trigger if exists games_emit_changed on public.games;
create trigger games_emit_changed
after update on public.games
for each row execute function public.emit_game_changed();

drop trigger if exists votes_emit_changed on public.votes;
create trigger votes_emit_changed
after insert or update or delete on public.votes
for each row execute function public.emit_votes_changed();

drop trigger if exists rounds_emit_changed on public.vote_rounds;
create trigger rounds_emit_changed
after insert or update on public.vote_rounds
for each row execute function public.emit_round_changed();

do $$
declare
  v_table text;
begin
  if exists (
    select 1
    from pg_publication
    where pubname = 'supabase_realtime'
  ) then
    foreach v_table in array array['players', 'votes', 'games']
    loop
      if exists (
        select 1
        from pg_publication_tables
        where pubname = 'supabase_realtime'
          and schemaname = 'public'
          and tablename = v_table
      ) then
        execute format('alter publication supabase_realtime drop table public.%I', v_table);
      end if;
    end loop;

    if not exists (
      select 1
      from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'public'
        and tablename = 'realtime_events'
    ) then
      alter publication supabase_realtime add table public.realtime_events;
    end if;
  end if;
end;
$$;

create or replace function public.get_player_by_session(
  p_session_id text
)
returns table(player_id uuid, game_id uuid, name text, code text)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if length(coalesce(trim(p_session_id), '')) < 12 then
    raise exception 'invalid_session';
  end if;

  return query
  select p.id, p.game_id, p.name, g.code
  from public.players as p
  join public.games as g on g.id = p.game_id
  where p.session_id = p_session_id
    and p.active = true
  limit 1;
end;
$$;

create or replace function public.get_vote_state(
  p_vote_round_id uuid,
  p_session_id text
)
returns table(
  vote_count bigint,
  required_vote_count bigint,
  already_voted boolean,
  missing_players jsonb
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_round record;
  v_player record;
begin
  select vr.id, vr.game_id
    into v_round
  from public.vote_rounds as vr
  where vr.id = p_vote_round_id;

  if not found then
    raise exception 'vote_round_not_found';
  end if;

  select p.id, p.game_id
    into v_player
  from public.players as p
  where p.session_id = p_session_id
    and p.active = true
  limit 1;

  if not found or v_player.game_id <> v_round.game_id then
    raise exception 'player_not_in_game';
  end if;

  return query
  select
    (select count(*) from public.votes as v where v.vote_round_id = p_vote_round_id),
    (select count(*) from public.players as p where p.game_id = v_round.game_id and p.active = true),
    exists (
      select 1
      from public.votes as v
      where v.vote_round_id = p_vote_round_id
        and v.voter_session_id = p_session_id
    ),
    coalesce((
      select jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name) order by p.created_at)
      from public.players as p
      where p.game_id = v_round.game_id
        and p.active = true
        and not exists (
          select 1
          from public.votes as v
          where v.vote_round_id = p_vote_round_id
            and v.voter_session_id = p.session_id
        )
    ), '[]'::jsonb);
end;
$$;

create or replace function public.get_round_result(
  p_vote_round_id uuid,
  p_session_id text
)
returns table(
  round_id uuid,
  status text,
  winners jsonb,
  tied_players jsonb,
  vote_count bigint,
  required_vote_count bigint
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_round record;
  v_player record;
begin
  select vr.id, vr.game_id, vr.status, vr.tie_player_ids
    into v_round
  from public.vote_rounds as vr
  where vr.id = p_vote_round_id;

  if not found then
    raise exception 'vote_round_not_found';
  end if;

  select p.id, p.game_id
    into v_player
  from public.players as p
  where p.session_id = p_session_id
    and p.active = true
  limit 1;

  if not found or v_player.game_id <> v_round.game_id then
    raise exception 'player_not_in_game';
  end if;

  return query
  with counts as (
    select v.voted_player_id, count(*)::bigint as total
    from public.votes as v
    where v.vote_round_id = p_vote_round_id
    group by v.voted_player_id
  ),
  max_count as (
    select coalesce(max(total), 0)::bigint as total
    from counts
  ),
  winner_rows as (
    select p.id, p.name, c.total
    from counts as c
    join public.players as p on p.id = c.voted_player_id
    where c.total = (select max_count.total from max_count)
      and c.total > 0
  )
  select
    v_round.id,
    v_round.status,
    coalesce((
      select jsonb_agg(jsonb_build_object('id', wr.id, 'name', wr.name, 'votes', wr.total))
      from winner_rows as wr
    ), '[]'::jsonb),
    coalesce((
      select jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name) order by p.created_at)
      from public.players as p
      where p.id = any(coalesce(v_round.tie_player_ids, array[]::uuid[]))
    ), '[]'::jsonb),
    (select count(*) from public.votes as v where v.vote_round_id = p_vote_round_id),
    (select count(*) from public.players as p where p.game_id = v_round.game_id and p.active = true);
end;
$$;

create or replace function public.submit_vote(
  p_vote_round_id uuid,
  p_voter_session_id text,
  p_voted_player_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_round record;
  v_voter record;
  v_target record;
begin
  select vr.id, vr.game_id, vr.status, vr.tie_player_ids
    into v_round
  from public.vote_rounds as vr
  where vr.id = p_vote_round_id;

  if not found then
    raise exception 'vote_round_not_found';
  end if;

  if v_round.status <> 'voting' then
    raise exception 'vote_round_not_open';
  end if;

  select p.id, p.game_id
    into v_voter
  from public.players as p
  where p.session_id = p_voter_session_id
    and p.active = true
  limit 1;

  if not found then
    raise exception 'voter_not_found';
  end if;

  if v_voter.game_id <> v_round.game_id then
    raise exception 'voter_not_in_game';
  end if;

  select p.id, p.game_id
    into v_target
  from public.players as p
  where p.id = p_voted_player_id
    and p.active = true;

  if not found then
    raise exception 'target_not_found';
  end if;

  if v_target.game_id <> v_round.game_id then
    raise exception 'target_not_in_game';
  end if;

  if v_target.id = v_voter.id then
    raise exception 'self_vote_not_allowed';
  end if;

  if coalesce(array_length(v_round.tie_player_ids, 1), 0) > 0
    and not (v_target.id = any(v_round.tie_player_ids))
  then
    raise exception 'target_not_in_tiebreak';
  end if;

  insert into public.votes (
    vote_round_id,
    voter_session_id,
    voted_player_id
  )
  values (
    p_vote_round_id,
    p_voter_session_id,
    p_voted_player_id
  );
end;
$$;

alter function public.create_game_with_host(text, text, text) set search_path = '';
alter function public.join_game_by_code(text, text, text) set search_path = '';
alter function public.activate_game_card(uuid, text, text) set search_path = '';
alter function public.clear_active_card_if_current(uuid, text, text) set search_path = '';
alter function public.get_or_create_vote_round(uuid, text, text, uuid) set search_path = '';
alter function public.close_vote_round_if_complete(uuid, text) set search_path = '';
alter function public.mark_round_ready_next(uuid, text) set search_path = '';
alter function public.start_tiebreak_round(uuid, text, uuid[]) set search_path = '';
alter function public.resolve_random_tiebreak(uuid, text, uuid[]) set search_path = '';

revoke all on function public.emit_players_changed() from public;
revoke all on function public.emit_game_changed() from public;
revoke all on function public.emit_votes_changed() from public;
revoke all on function public.emit_round_changed() from public;
revoke all on function public.get_player_by_session(text) from public;
revoke all on function public.get_vote_state(uuid, text) from public;
revoke all on function public.get_round_result(uuid, text) from public;
revoke all on function public.submit_vote(uuid, text, uuid) from public;

grant execute on function public.get_player_by_session(text) to anon;
grant execute on function public.get_vote_state(uuid, text) to anon;
grant execute on function public.get_round_result(uuid, text) to anon;
grant execute on function public.submit_vote(uuid, text, uuid) to anon;

commit;
