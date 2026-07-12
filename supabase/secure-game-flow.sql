-- Secure game flow RPCs for production.
-- Apply in Supabase SQL editor before deploying the matching frontend.

begin;

alter table public.cards enable row level security;
alter table public.games enable row level security;
alter table public.players enable row level security;
alter table public.vote_rounds enable row level security;
alter table public.votes enable row level security;

do $$
declare
  v_policy record;
begin
  for v_policy in
    select tablename, policyname
    from pg_policies
    where schemaname = 'public'
      and tablename in ('games', 'players', 'vote_rounds', 'votes')
      and cmd <> 'SELECT'
  loop
    execute format(
      'drop policy if exists %I on public.%I',
      v_policy.policyname,
      v_policy.tablename
    );
  end loop;
end;
$$;

create unique index if not exists games_code_key on public.games (code);
create unique index if not exists votes_one_vote_per_round_session_key
  on public.votes (vote_round_id, voter_session_id);
create index if not exists players_session_active_idx
  on public.players (session_id, active);
create index if not exists vote_rounds_game_card_status_created_idx
  on public.vote_rounds (game_id, card_id, status, created_at);

do $$
declare
  v_table text;
begin
  if exists (
    select 1
    from pg_publication
    where pubname = 'supabase_realtime'
  ) then
    foreach v_table in array array['games', 'players', 'vote_rounds', 'votes']
    loop
      if not exists (
        select 1
        from pg_publication_tables
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

drop policy if exists "cards are publicly readable" on public.cards;
create policy "cards are publicly readable"
  on public.cards
  for select
  to anon
  using (true);

drop policy if exists "games are publicly readable for the game flow" on public.games;
create policy "games are publicly readable for the game flow"
  on public.games
  for select
  to anon
  using (true);

drop policy if exists "players are publicly readable for the game flow" on public.players;
create policy "players are publicly readable for the game flow"
  on public.players
  for select
  to anon
  using (true);

drop policy if exists "vote rounds are publicly readable for the game flow" on public.vote_rounds;
create policy "vote rounds are publicly readable for the game flow"
  on public.vote_rounds
  for select
  to anon
  using (true);

drop policy if exists "votes are publicly readable for the game flow" on public.votes;
create policy "votes are publicly readable for the game flow"
  on public.votes
  for select
  to anon
  using (true);

create or replace function public.create_game_with_host(
  p_code text,
  p_host_session_id text,
  p_host_name text
)
returns table(game_id uuid, code text)
language plpgsql
security definer
set search_path = public
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
    active
  )
  values (
    v_game_id,
    v_name,
    p_host_session_id,
    true,
    true
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
set search_path = public
as $$
declare
  v_game record;
  v_code text := upper(trim(p_code));
  v_name text := trim(p_name);
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

  insert into public.players (
    game_id,
    name,
    session_id,
    is_host,
    active
  )
  values (
    v_game.id,
    v_name,
    p_session_id,
    false,
    true
  );

  return query select v_game.id, v_game.code;
end;
$$;

create or replace function public.activate_game_card(
  p_game_id uuid,
  p_session_id text,
  p_card_slug text
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player record;
  v_card record;
  v_active_card_slug text;
begin
  select p.id, p.name, p.game_id
    into v_player
  from public.players as p
  where p.session_id = p_session_id
    and p.active = true
  limit 1;

  if not found or v_player.game_id <> p_game_id then
    raise exception 'player_not_in_game';
  end if;

  select c.id, c.slug
    into v_card
  from public.cards as c
  where c.slug = p_card_slug
    and c.active = true;

  if not found then
    raise exception 'card_not_found';
  end if;

  v_active_card_slug := v_card.slug || '::scanned_by::' || v_player.name;

  update public.games as g
    set active_card_slug = v_active_card_slug
  where g.id = p_game_id;

  return v_active_card_slug;
end;
$$;

create or replace function public.clear_active_card_if_current(
  p_game_id uuid,
  p_session_id text,
  p_card_slug text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player record;
begin
  select p.game_id, p.name
    into v_player
  from public.players as p
  where p.session_id = p_session_id
    and p.active = true
  limit 1;

  if not found or v_player.game_id <> p_game_id then
    raise exception 'player_not_in_game';
  end if;

  update public.games as g
    set active_card_slug = null
  where g.id = p_game_id
    and split_part(
      split_part(coalesce(g.active_card_slug, ''), '::scanned_by::', 1),
      '::round::',
      1
    ) = p_card_slug;
end;
$$;

create or replace function public.get_or_create_vote_round(
  p_game_id uuid,
  p_session_id text,
  p_card_slug text,
  p_round_id uuid default null
)
returns table(id uuid, status text, tie_player_ids uuid[], card_id uuid)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player record;
  v_card record;
  v_round record;
  v_next_round_number integer;
begin
  select p.game_id, p.name
    into v_player
  from public.players as p
  where p.session_id = p_session_id
    and p.active = true
  limit 1;

  if not found or v_player.game_id <> p_game_id then
    raise exception 'player_not_in_game';
  end if;

  select c.id, c.slug
    into v_card
  from public.cards as c
  where c.slug = p_card_slug
    and c.active = true;

  if not found then
    raise exception 'card_not_found';
  end if;

  if p_round_id is not null then
    select vr.id, vr.status, vr.tie_player_ids, vr.card_id
      into v_round
    from public.vote_rounds as vr
    where vr.id = p_round_id
      and vr.game_id = p_game_id
      and vr.card_id = v_card.id;

    if not found then
      raise exception 'vote_round_not_found';
    end if;

    return query select v_round.id, v_round.status, v_round.tie_player_ids, v_round.card_id;
    return;
  end if;

  perform pg_advisory_xact_lock(hashtext(p_game_id::text || ':' || v_card.id::text));

  select vr.id, vr.status, vr.tie_player_ids, vr.card_id
    into v_round
  from public.vote_rounds as vr
  where vr.game_id = p_game_id
    and vr.card_id = v_card.id
    and vr.status = 'voting'
  order by vr.created_at desc
  limit 1;

  if not found then
    select coalesce(max(vr.round_number), 0) + 1
      into v_next_round_number
    from public.vote_rounds as vr
    where vr.game_id = p_game_id
      and vr.card_id = v_card.id;

    insert into public.vote_rounds (
      game_id,
      card_id,
      round_number,
      status
    )
    values (
      p_game_id,
      v_card.id,
      v_next_round_number,
      'voting'
    )
    returning vote_rounds.id, vote_rounds.status, vote_rounds.tie_player_ids, vote_rounds.card_id
    into v_round;
  end if;

  return query select v_round.id, v_round.status, v_round.tie_player_ids, v_round.card_id;
end;
$$;

create or replace function public.close_vote_round_if_complete(
  p_vote_round_id uuid,
  p_session_id text
)
returns void
language plpgsql
security definer
set search_path = public
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
    and p.active = true;

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

create or replace function public.mark_round_ready_next(
  p_vote_round_id uuid,
  p_session_id text
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_round record;
  v_player record;
  v_status text;
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

  if v_round.status = 'ready_next' then
    return 'ready_next';
  end if;

  if v_round.status <> 'closed' then
    raise exception 'vote_round_not_closed';
  end if;

  update public.vote_rounds as vr
    set status = 'ready_next'
  where vr.id = p_vote_round_id
    and vr.status = 'closed'
  returning vr.status into v_status;

  return coalesce(v_status, 'ready_next');
end;
$$;

create or replace function public.start_tiebreak_round(
  p_source_round_id uuid,
  p_session_id text,
  p_tied_player_ids uuid[]
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_source record;
  v_player record;
  v_tiebreak_id uuid;
  v_next_round_number integer;
  v_tied_count integer;
  v_card_slug text;
begin
  if coalesce(array_length(p_tied_player_ids, 1), 0) < 2 then
    raise exception 'invalid_tiebreak_players';
  end if;

  select vr.id, vr.game_id, vr.card_id
    into v_source
  from public.vote_rounds as vr
  where vr.id = p_source_round_id;

  if not found then
    raise exception 'vote_round_not_found';
  end if;

  select p.game_id, p.name
    into v_player
  from public.players as p
  where p.session_id = p_session_id
    and p.active = true
  limit 1;

  if not found or v_player.game_id <> v_source.game_id then
    raise exception 'player_not_in_game';
  end if;

  select count(*)
    into v_tied_count
  from public.players as p
  where p.game_id = v_source.game_id
    and p.active = true
    and p.id = any(p_tied_player_ids);

  if v_tied_count <> array_length(p_tied_player_ids, 1) then
    raise exception 'invalid_tiebreak_players';
  end if;

  perform pg_advisory_xact_lock(hashtext(v_source.game_id::text || ':' || v_source.card_id::text || ':tie'));

  select vr.id
    into v_tiebreak_id
  from public.vote_rounds as vr
  where vr.game_id = v_source.game_id
    and vr.card_id = v_source.card_id
    and vr.status = 'voting'
    and vr.tie_player_ids @> p_tied_player_ids
    and p_tied_player_ids @> vr.tie_player_ids
  order by vr.created_at desc
  limit 1;

  if v_tiebreak_id is null then
    select coalesce(max(vr.round_number), 0) + 1
      into v_next_round_number
    from public.vote_rounds as vr
    where vr.game_id = v_source.game_id
      and vr.card_id = v_source.card_id;

    insert into public.vote_rounds (
      game_id,
      card_id,
      round_number,
      status,
      tie_player_ids
    )
    values (
      v_source.game_id,
      v_source.card_id,
      v_next_round_number,
      'voting',
      p_tied_player_ids
    )
    returning vote_rounds.id into v_tiebreak_id;
  end if;

  update public.vote_rounds as vr
    set status = 'closed'
  where vr.id = p_source_round_id
    and vr.id <> v_tiebreak_id
    and vr.status <> 'ready_next';

  select c.slug
    into v_card_slug
  from public.cards as c
  where c.id = v_source.card_id;

  update public.games as g
    set active_card_slug = v_card_slug || '::round::' || v_tiebreak_id::text
  where g.id = v_source.game_id;

  return v_tiebreak_id;
end;
$$;

drop function if exists public.resolve_random_tiebreak(uuid, text);

create or replace function public.resolve_random_tiebreak(
  p_vote_round_id uuid,
  p_session_id text,
  p_tied_player_ids uuid[]
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_round record;
  v_player record;
  v_winner_id uuid;
  v_tied_count integer;
begin
  select vr.id, vr.game_id, vr.status, vr.tie_player_ids
    into v_round
  from public.vote_rounds as vr
  where vr.id = p_vote_round_id;

  if not found then
    raise exception 'vote_round_not_found';
  end if;

  select p.game_id
    into v_player
  from public.players as p
  where p.session_id = p_session_id
    and p.active = true
  limit 1;

  if not found or v_player.game_id <> v_round.game_id then
    raise exception 'player_not_in_game';
  end if;

  if v_round.status = 'closed'
    and coalesce(array_length(v_round.tie_player_ids, 1), 0) = 1
  then
    return v_round.tie_player_ids[1];
  end if;

  if coalesce(array_length(p_tied_player_ids, 1), 0) < 2 then
    raise exception 'invalid_tiebreak_round';
  end if;

  select count(*)
    into v_tied_count
  from public.players as p
  where p.game_id = v_round.game_id
    and p.active = true
    and p.id = any(p_tied_player_ids);

  if v_tied_count <> array_length(p_tied_player_ids, 1) then
    raise exception 'invalid_tiebreak_players';
  end if;

  select tied_id
    into v_winner_id
  from unnest(p_tied_player_ids) as tied_id
  order by random()
  limit 1;

  update public.vote_rounds as vr
    set status = 'closed',
        tie_player_ids = array[v_winner_id]
  where vr.id = p_vote_round_id
    and vr.status <> 'ready_next';

  return v_winner_id;
end;
$$;

revoke all on function public.create_game_with_host(text, text, text) from public;
revoke all on function public.join_game_by_code(text, text, text) from public;
revoke all on function public.activate_game_card(uuid, text, text) from public;
revoke all on function public.clear_active_card_if_current(uuid, text, text) from public;
revoke all on function public.get_or_create_vote_round(uuid, text, text, uuid) from public;
revoke all on function public.close_vote_round_if_complete(uuid, text) from public;
revoke all on function public.mark_round_ready_next(uuid, text) from public;
revoke all on function public.start_tiebreak_round(uuid, text, uuid[]) from public;
revoke all on function public.resolve_random_tiebreak(uuid, text, uuid[]) from public;

grant execute on function public.create_game_with_host(text, text, text) to anon;
grant execute on function public.join_game_by_code(text, text, text) to anon;
grant execute on function public.activate_game_card(uuid, text, text) to anon;
grant execute on function public.clear_active_card_if_current(uuid, text, text) to anon;
grant execute on function public.get_or_create_vote_round(uuid, text, text, uuid) to anon;
grant execute on function public.close_vote_round_if_complete(uuid, text) to anon;
grant execute on function public.mark_round_ready_next(uuid, text) to anon;
grant execute on function public.start_tiebreak_round(uuid, text, uuid[]) to anon;
grant execute on function public.resolve_random_tiebreak(uuid, text, uuid[]) to anon;

commit;
