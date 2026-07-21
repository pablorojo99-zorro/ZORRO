-- Player presence and reconnect handling.
-- Apply after private-vote-security.sql.

begin;

alter table public.players
  add column if not exists last_seen_at timestamptz not null default now(),
  add column if not exists disconnected_at timestamptz;

update public.players
  set last_seen_at = coalesce(last_seen_at, created_at, now())
where last_seen_at is null;

with duplicate_players as (
  select
    p.id,
    row_number() over (
      partition by p.game_id, p.session_id
      order by p.is_host desc, p.created_at asc, p.id asc
    ) as duplicate_rank
  from public.players as p
  where p.active = true
    and p.session_id is not null
)
update public.players as p
  set active = false,
      disconnected_at = now()
from duplicate_players as dp
where p.id = dp.id
  and dp.duplicate_rank > 1;

create unique index if not exists players_one_active_session_per_game_key
  on public.players (game_id, session_id)
  where active = true;

create index if not exists players_game_presence_idx
  on public.players (game_id, active, last_seen_at);

grant select (
  id,
  game_id,
  name,
  is_host,
  active,
  created_at,
  last_seen_at
) on table public.players to anon;

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
  created_at,
  last_seen_at,
  case
    when last_seen_at >= now() - interval '45 seconds' then 'online'
    when last_seen_at >= now() - interval '5 minutes' then 'reconnecting'
    else 'offline'
  end as presence_status
from public.players
where active = true;

grant select on public.public_players to anon;

create or replace function public.create_game_with_host(
  p_code text,
  p_host_session_id text,
  p_host_name text
)
returns table(game_id uuid, code text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_game_id uuid;
  v_code text := upper(trim(p_code));
  v_name text := trim(p_host_name);
begin
  if v_code !~ '^[A-Z2-9]{4}$' then
    raise exception 'invalid_game_code';
  end if;

  if length(coalesce(trim(p_host_session_id), '')) < 12 then
    raise exception 'invalid_session';
  end if;

  if length(v_name) < 1 or length(v_name) > 40 then
    raise exception 'invalid_player_name';
  end if;

  insert into public.games (
    code,
    status,
    host_session_id,
    current_round_number
  )
  values (
    v_code,
    'lobby',
    p_host_session_id,
    0
  )
  returning id into v_game_id;

  insert into public.players (
    game_id,
    name,
    session_id,
    is_host,
    active,
    last_seen_at,
    disconnected_at
  )
  values (
    v_game_id,
    v_name,
    p_host_session_id,
    true,
    true,
    now(),
    null
  );

  return query select v_game_id, v_code;
end;
$$;

create or replace function public.join_game_by_code(
  p_code text,
  p_session_id text,
  p_name text
)
returns table(game_id uuid, code text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_game record;
  v_code text := upper(trim(p_code));
  v_name text := trim(p_name);
  v_player_id uuid;
begin
  if length(coalesce(trim(p_session_id), '')) < 12 then
    raise exception 'invalid_session';
  end if;

  if length(v_name) < 1 or length(v_name) > 40 then
    raise exception 'invalid_player_name';
  end if;

  select g.id, g.code
    into v_game
  from public.games as g
  where g.code = v_code
  limit 1;

  if not found then
    raise exception 'game_not_found';
  end if;

  perform pg_advisory_xact_lock(hashtext(v_game.id::text || ':' || p_session_id));

  select p.id
    into v_player_id
  from public.players as p
  where p.game_id = v_game.id
    and p.session_id = p_session_id
    and p.active = true
  order by p.created_at asc
  limit 1;

  if v_player_id is null then
    select p.id
      into v_player_id
    from public.players as p
    where p.game_id = v_game.id
      and p.session_id = p_session_id
      and p.active = false
    order by p.created_at desc
    limit 1;
  end if;

  if v_player_id is not null then
    update public.players as p
      set name = v_name,
          active = true,
          last_seen_at = now(),
          disconnected_at = null
    where p.id = v_player_id;
  else
    insert into public.players (
      game_id,
      name,
      session_id,
      is_host,
      active,
      last_seen_at,
      disconnected_at
    )
    values (
      v_game.id,
      v_name,
      p_session_id,
      false,
      true,
      now(),
      null
    );
  end if;

  return query select v_game.id, v_game.code;
end;
$$;

drop function if exists public.get_player_by_session(text);

create or replace function public.get_player_by_session(
  p_session_id text,
  p_code text default null
)
returns table(player_id uuid, game_id uuid, name text, code text, is_host boolean)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if length(coalesce(trim(p_session_id), '')) < 12 then
    raise exception 'invalid_session';
  end if;

  return query
  with target_player as (
    select p.id
    from public.players as p
    join public.games as g on g.id = p.game_id
    where p.session_id = p_session_id
      and p.active = true
      and (
        p_code is null
        or g.code = upper(trim(p_code))
      )
    order by p.last_seen_at desc, p.created_at desc
    limit 1
  ),
  updated_player as (
    update public.players as p
      set last_seen_at = now(),
          disconnected_at = null
    from target_player as tp
    where p.id = tp.id
    returning p.id, p.game_id, p.name, p.is_host
  )
  select up.id, up.game_id, up.name, g.code, up.is_host
  from updated_player as up
  join public.games as g on g.id = up.game_id;
end;
$$;

create or replace function public.heartbeat_player(
  p_session_id text,
  p_game_id uuid default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if length(coalesce(trim(p_session_id), '')) < 12 then
    raise exception 'invalid_session';
  end if;

  update public.players as p
    set last_seen_at = now(),
        disconnected_at = null
  where p.session_id = p_session_id
    and p.active = true
    and (p_game_id is null or p.game_id = p_game_id)
    and p.last_seen_at < now() - interval '15 seconds';
end;
$$;

create or replace function public.remove_player_from_game(
  p_host_session_id text,
  p_player_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_host record;
  v_target record;
begin
  select p.id, p.game_id
    into v_target
  from public.players as p
  where p.id = p_player_id
    and p.active = true;

  if not found then
    raise exception 'player_not_in_game';
  end if;

  select p.id, p.game_id, p.is_host
    into v_host
  from public.players as p
  where p.session_id = p_host_session_id
    and p.game_id = v_target.game_id
    and p.active = true
  limit 1;

  if not found or v_host.is_host <> true then
    raise exception 'host_not_found';
  end if;

  if v_target.id = v_host.id then
    raise exception 'cannot_remove_self';
  end if;

  update public.players as p
    set active = false,
        disconnected_at = now()
  where p.id = p_player_id;
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
  with eligible_players as (
    select p.id, p.name, p.session_id, p.created_at
    from public.players as p
    where p.game_id = v_round.game_id
      and p.active = true
      and (
        p.last_seen_at >= now() - interval '90 seconds'
        or exists (
          select 1
          from public.votes as v
          where v.vote_round_id = p_vote_round_id
            and v.voter_session_id = p.session_id
        )
      )
  )
  select
    (select count(distinct v.voter_session_id) from public.votes as v where v.vote_round_id = p_vote_round_id),
    (select count(*) from eligible_players),
    exists (
      select 1
      from public.votes as v
      where v.vote_round_id = p_vote_round_id
        and v.voter_session_id = p_session_id
    ),
    coalesce((
      select jsonb_agg(jsonb_build_object('id', ep.id, 'name', ep.name) order by ep.created_at)
      from eligible_players as ep
      where not exists (
        select 1
        from public.votes as v
        where v.vote_round_id = p_vote_round_id
          and v.voter_session_id = ep.session_id
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
  with eligible_players as (
    select p.id, p.session_id
    from public.players as p
    where p.game_id = v_round.game_id
      and p.active = true
      and (
        p.last_seen_at >= now() - interval '90 seconds'
        or exists (
          select 1
          from public.votes as v
          where v.vote_round_id = p_vote_round_id
            and v.voter_session_id = p.session_id
        )
      )
  ),
  counts as (
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
    (select count(distinct v.voter_session_id) from public.votes as v where v.vote_round_id = p_vote_round_id),
    (select count(*) from eligible_players);
end;
$$;

create or replace function public.close_vote_round_if_complete(
  p_vote_round_id uuid,
  p_session_id text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_round record;
  v_player record;
  v_required_count integer;
  v_vote_count integer;
begin
  select vr.id, vr.game_id, vr.status
    into v_round
  from public.vote_rounds as vr
  where vr.id = p_vote_round_id;

  if not found then
    raise exception 'vote_round_not_found';
  end if;

  select p.game_id, p.name
    into v_player
  from public.players as p
  where p.session_id = p_session_id
    and p.active = true
  limit 1;

  if not found or v_player.game_id <> v_round.game_id then
    raise exception 'player_not_in_game';
  end if;

  if v_round.status = 'closed' then
    return;
  end if;

  if v_round.status <> 'voting' then
    raise exception 'vote_round_not_open';
  end if;

  select count(*)
    into v_required_count
  from public.players as p
  where p.game_id = v_round.game_id
    and p.active = true
    and (
      p.last_seen_at >= now() - interval '90 seconds'
      or exists (
        select 1
        from public.votes as v
        where v.vote_round_id = p_vote_round_id
          and v.voter_session_id = p.session_id
      )
    );

  select count(distinct voter_session_id)
    into v_vote_count
  from public.votes as v
  where v.vote_round_id = p_vote_round_id;

  if v_required_count = 0 or v_vote_count < v_required_count then
    raise exception 'vote_round_not_complete';
  end if;

  update public.vote_rounds as vr
    set status = 'closed'
  where vr.id = p_vote_round_id
    and vr.status = 'voting';
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

  update public.players as p
    set last_seen_at = now(),
        disconnected_at = null
  where p.id = v_voter.id;

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

revoke all on function public.get_player_by_session(text, text) from public;
revoke all on function public.heartbeat_player(text, uuid) from public;
revoke all on function public.remove_player_from_game(text, uuid) from public;

grant execute on function public.get_player_by_session(text, text) to anon;
grant execute on function public.heartbeat_player(text, uuid) to anon;
grant execute on function public.remove_player_from_game(text, uuid) to anon;

commit;
