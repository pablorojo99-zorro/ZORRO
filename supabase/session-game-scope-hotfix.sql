-- Scope session lookups to the current game.
-- Apply after player-presence-reconnect.sql.

begin;

create or replace function public.activate_game_card(
  p_game_id uuid,
  p_session_id text,
  p_card_slug text
)
returns text
language plpgsql
security definer
set search_path = ''
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
    and p.game_id = p_game_id
    and p.active = true
  limit 1;

  if not found then
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

  update public.players as p
    set last_seen_at = now(),
        disconnected_at = null
  where p.id = v_player.id;

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
set search_path = ''
as $$
declare
  v_player record;
begin
  select p.id, p.game_id, p.name
    into v_player
  from public.players as p
  where p.session_id = p_session_id
    and p.game_id = p_game_id
    and p.active = true
  limit 1;

  if not found then
    raise exception 'player_not_in_game';
  end if;

  update public.players as p
    set last_seen_at = now(),
        disconnected_at = null
  where p.id = v_player.id;

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
set search_path = ''
as $$
declare
  v_player record;
  v_card record;
  v_round record;
  v_next_round_number integer;
begin
  select p.id, p.game_id, p.name
    into v_player
  from public.players as p
  where p.session_id = p_session_id
    and p.game_id = p_game_id
    and p.active = true
  limit 1;

  if not found then
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

  update public.players as p
    set last_seen_at = now(),
        disconnected_at = null
  where p.id = v_player.id;

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
    and p.game_id = v_round.game_id
    and p.active = true
  limit 1;

  if not found then
    raise exception 'voter_not_found';
  end if;

  select p.id, p.game_id
    into v_target
  from public.players as p
  where p.id = p_voted_player_id
    and p.game_id = v_round.game_id
    and p.active = true;

  if not found then
    raise exception 'target_not_found';
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

create or replace function public.mark_round_ready_next(
  p_vote_round_id uuid,
  p_session_id text
)
returns text
language plpgsql
security definer
set search_path = ''
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

  select p.id, p.game_id, p.name
    into v_player
  from public.players as p
  where p.session_id = p_session_id
    and p.game_id = v_round.game_id
    and p.active = true
  limit 1;

  if not found then
    raise exception 'player_not_in_game';
  end if;

  update public.players as p
    set last_seen_at = now(),
        disconnected_at = null
  where p.id = v_player.id;

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
    and p.game_id = v_round.game_id
    and p.active = true
  limit 1;

  if not found then
    raise exception 'player_not_in_game';
  end if;

  update public.players as p
    set last_seen_at = now(),
        disconnected_at = null
  where p.id = v_player.id;

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
    and p.game_id = v_round.game_id
    and p.active = true
  limit 1;

  if not found then
    raise exception 'player_not_in_game';
  end if;

  update public.players as p
    set last_seen_at = now(),
        disconnected_at = null
  where p.id = v_player.id;

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

  select p.id, p.game_id, p.name
    into v_player
  from public.players as p
  where p.session_id = p_session_id
    and p.game_id = v_round.game_id
    and p.active = true
  limit 1;

  if not found then
    raise exception 'player_not_in_game';
  end if;

  update public.players as p
    set last_seen_at = now(),
        disconnected_at = null
  where p.id = v_player.id;

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

create or replace function public.start_tiebreak_round(
  p_source_round_id uuid,
  p_session_id text,
  p_tied_player_ids uuid[]
)
returns uuid
language plpgsql
security definer
set search_path = ''
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

  select p.id, p.game_id, p.name
    into v_player
  from public.players as p
  where p.session_id = p_session_id
    and p.game_id = v_source.game_id
    and p.active = true
  limit 1;

  if not found then
    raise exception 'player_not_in_game';
  end if;

  update public.players as p
    set last_seen_at = now(),
        disconnected_at = null
  where p.id = v_player.id;

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

create or replace function public.resolve_random_tiebreak(
  p_vote_round_id uuid,
  p_session_id text,
  p_tied_player_ids uuid[]
)
returns uuid
language plpgsql
security definer
set search_path = ''
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

  select p.id, p.game_id
    into v_player
  from public.players as p
  where p.session_id = p_session_id
    and p.game_id = v_round.game_id
    and p.active = true
  limit 1;

  if not found then
    raise exception 'player_not_in_game';
  end if;

  update public.players as p
    set last_seen_at = now(),
        disconnected_at = null
  where p.id = v_player.id;

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

revoke all on function public.activate_game_card(uuid, text, text) from public;
revoke all on function public.clear_active_card_if_current(uuid, text, text) from public;
revoke all on function public.get_or_create_vote_round(uuid, text, text, uuid) from public;
revoke all on function public.submit_vote(uuid, text, uuid) from public;
revoke all on function public.mark_round_ready_next(uuid, text) from public;
revoke all on function public.get_vote_state(uuid, text) from public;
revoke all on function public.get_round_result(uuid, text) from public;
revoke all on function public.close_vote_round_if_complete(uuid, text) from public;
revoke all on function public.start_tiebreak_round(uuid, text, uuid[]) from public;
revoke all on function public.resolve_random_tiebreak(uuid, text, uuid[]) from public;

grant execute on function public.activate_game_card(uuid, text, text) to anon;
grant execute on function public.clear_active_card_if_current(uuid, text, text) to anon;
grant execute on function public.get_or_create_vote_round(uuid, text, text, uuid) to anon;
grant execute on function public.submit_vote(uuid, text, uuid) to anon;
grant execute on function public.mark_round_ready_next(uuid, text) to anon;
grant execute on function public.get_vote_state(uuid, text) to anon;
grant execute on function public.get_round_result(uuid, text) to anon;
grant execute on function public.close_vote_round_if_complete(uuid, text) to anon;
grant execute on function public.start_tiebreak_round(uuid, text, uuid[]) to anon;
grant execute on function public.resolve_random_tiebreak(uuid, text, uuid[]) to anon;

commit;
