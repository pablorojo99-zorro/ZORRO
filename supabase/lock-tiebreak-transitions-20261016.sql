-- Serialize tiebreak creation, random resolution, and ready-next transitions.
-- This migration changes only the three RPC definitions below.

begin;

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
  v_required_count integer;
  v_vote_count integer;
  v_distinct_input_count integer;
  v_active_tied_count integer;
  v_actual_tied_player_ids uuid[];
  v_card_slug text;
  v_active_card_slug text;
  v_active_round_id uuid;
begin
  if coalesce(array_length(p_tied_player_ids, 1), 0) < 2
    or array_position(p_tied_player_ids, null) is not null
  then
    raise exception 'invalid_tiebreak_players';
  end if;

  select count(distinct tied_id)
    into v_distinct_input_count
  from unnest(p_tied_player_ids) as tied_id;

  if v_distinct_input_count <> array_length(p_tied_player_ids, 1) then
    raise exception 'invalid_tiebreak_players';
  end if;

  select vr.id, vr.game_id, vr.card_id, vr.round_number, vr.status, vr.tie_player_ids
    into v_source
  from public.vote_rounds as vr
  where vr.id = p_source_round_id
  for update;

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

  if v_source.status = 'ready_next' then
    raise exception 'vote_round_ready_next';
  end if;

  if v_source.status not in ('voting', 'closed') then
    raise exception 'vote_round_not_open';
  end if;

  select count(*)
    into v_required_count
  from public.players as p
  where p.game_id = v_source.game_id
    and p.active = true
    and (
      p.last_seen_at >= now() - interval '90 seconds'
      or exists (
        select 1
        from public.votes as v
        where v.vote_round_id = p_source_round_id
          and v.voter_session_id = p.session_id
      )
    );

  select count(distinct v.voter_session_id)
    into v_vote_count
  from public.votes as v
  where v.vote_round_id = p_source_round_id;

  if v_required_count = 0 or v_vote_count < v_required_count then
    raise exception 'vote_round_not_complete';
  end if;

  with counts as (
    select v.voted_player_id, count(*)::bigint as total
    from public.votes as v
    where v.vote_round_id = p_source_round_id
    group by v.voted_player_id
  ),
  max_count as (
    select coalesce(max(c.total), 0)::bigint as total
    from counts as c
  )
  select coalesce(
      array_agg(c.voted_player_id order by c.voted_player_id),
      array[]::uuid[]
    )
    into v_actual_tied_player_ids
  from counts as c
  where c.total = (select mc.total from max_count as mc)
    and c.total > 0;

  if coalesce(array_length(v_actual_tied_player_ids, 1), 0) < 2 then
    raise exception 'invalid_tiebreak_round';
  end if;

  if array_length(v_actual_tied_player_ids, 1) <> array_length(p_tied_player_ids, 1)
    or not (v_actual_tied_player_ids @> p_tied_player_ids)
    or not (p_tied_player_ids @> v_actual_tied_player_ids)
  then
    raise exception 'invalid_tiebreak_players';
  end if;

  select count(*)
    into v_active_tied_count
  from public.players as p
  where p.game_id = v_source.game_id
    and p.active = true
    and p.id = any(v_actual_tied_player_ids);

  if v_active_tied_count <> array_length(v_actual_tied_player_ids, 1) then
    raise exception 'invalid_tiebreak_players';
  end if;

  perform pg_advisory_xact_lock(
    hashtext(v_source.game_id::text || ':' || v_source.card_id::text || ':tie')
  );

  select c.slug
    into v_card_slug
  from public.cards as c
  where c.id = v_source.card_id;

  select g.active_card_slug
    into v_active_card_slug
  from public.games as g
  where g.id = v_source.game_id;

  if split_part(
      split_part(coalesce(v_active_card_slug, ''), '::scanned_by::', 1),
      '::round::',
      1
    ) <> v_card_slug
  then
    raise exception 'vote_round_not_current';
  end if;

  if coalesce(v_active_card_slug, '') ~ '::round::[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$' then
    v_active_round_id := substring(
      v_active_card_slug
      from '::round::([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12})$'
    )::uuid;
  end if;

  if v_active_round_id is not null and v_active_round_id <> p_source_round_id then
    select vr.id
      into v_tiebreak_id
    from public.vote_rounds as vr
    where vr.id = v_active_round_id
      and vr.game_id = v_source.game_id
      and vr.card_id = v_source.card_id
      and vr.round_number = v_source.round_number + 1
      and vr.status = 'voting'
      and array_length(vr.tie_player_ids, 1) = array_length(v_actual_tied_player_ids, 1)
      and vr.tie_player_ids @> v_actual_tied_player_ids
      and v_actual_tied_player_ids @> vr.tie_player_ids;

    if v_tiebreak_id is null then
      raise exception 'tiebreak_transition_conflict';
    end if;

    return v_tiebreak_id;
  end if;

  if v_source.status = 'closed'
    and coalesce(array_length(v_source.tie_player_ids, 1), 0) = 1
  then
    raise exception 'tiebreak_already_resolved';
  end if;

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
    v_actual_tied_player_ids
  )
  returning vote_rounds.id into v_tiebreak_id;

  update public.vote_rounds as vr
    set status = 'closed'
  where vr.id = p_source_round_id
    and vr.status in ('voting', 'closed');

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
  v_required_count integer;
  v_vote_count integer;
  v_distinct_input_count integer;
  v_active_tied_count integer;
  v_actual_tied_player_ids uuid[];
  v_card_slug text;
  v_active_card_slug text;
  v_active_round_id uuid;
  v_associated_tiebreak_exists boolean;
begin
  if coalesce(array_length(p_tied_player_ids, 1), 0) < 2
    or array_position(p_tied_player_ids, null) is not null
  then
    raise exception 'invalid_tiebreak_round';
  end if;

  select count(distinct tied_id)
    into v_distinct_input_count
  from unnest(p_tied_player_ids) as tied_id;

  if v_distinct_input_count <> array_length(p_tied_player_ids, 1) then
    raise exception 'invalid_tiebreak_players';
  end if;

  select vr.id, vr.game_id, vr.card_id, vr.round_number, vr.status, vr.tie_player_ids
    into v_round
  from public.vote_rounds as vr
  where vr.id = p_vote_round_id
  for update;

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

  if v_round.status = 'ready_next' then
    raise exception 'vote_round_ready_next';
  end if;

  if v_round.status not in ('voting', 'closed') then
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

  select count(distinct v.voter_session_id)
    into v_vote_count
  from public.votes as v
  where v.vote_round_id = p_vote_round_id;

  if v_required_count = 0 or v_vote_count < v_required_count then
    raise exception 'vote_round_not_complete';
  end if;

  with counts as (
    select v.voted_player_id, count(*)::bigint as total
    from public.votes as v
    where v.vote_round_id = p_vote_round_id
    group by v.voted_player_id
  ),
  max_count as (
    select coalesce(max(c.total), 0)::bigint as total
    from counts as c
  )
  select coalesce(
      array_agg(c.voted_player_id order by c.voted_player_id),
      array[]::uuid[]
    )
    into v_actual_tied_player_ids
  from counts as c
  where c.total = (select mc.total from max_count as mc)
    and c.total > 0;

  if coalesce(array_length(v_actual_tied_player_ids, 1), 0) < 2 then
    raise exception 'invalid_tiebreak_round';
  end if;

  if array_length(v_actual_tied_player_ids, 1) <> array_length(p_tied_player_ids, 1)
    or not (v_actual_tied_player_ids @> p_tied_player_ids)
    or not (p_tied_player_ids @> v_actual_tied_player_ids)
  then
    raise exception 'invalid_tiebreak_players';
  end if;

  select count(*)
    into v_active_tied_count
  from public.players as p
  where p.game_id = v_round.game_id
    and p.active = true
    and p.id = any(v_actual_tied_player_ids);

  if v_active_tied_count <> array_length(v_actual_tied_player_ids, 1) then
    raise exception 'invalid_tiebreak_players';
  end if;

  perform pg_advisory_xact_lock(
    hashtext(v_round.game_id::text || ':' || v_round.card_id::text || ':tie')
  );

  select c.slug
    into v_card_slug
  from public.cards as c
  where c.id = v_round.card_id;

  select g.active_card_slug
    into v_active_card_slug
  from public.games as g
  where g.id = v_round.game_id;

  if split_part(
      split_part(coalesce(v_active_card_slug, ''), '::scanned_by::', 1),
      '::round::',
      1
    ) <> v_card_slug
  then
    raise exception 'vote_round_not_current';
  end if;

  if coalesce(v_active_card_slug, '') ~ '::round::[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$' then
    v_active_round_id := substring(
      v_active_card_slug
      from '::round::([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12})$'
    )::uuid;
  end if;

  select exists (
    select 1
    from public.vote_rounds as vr
    where vr.id = v_active_round_id
      and vr.id <> p_vote_round_id
      and vr.game_id = v_round.game_id
      and vr.card_id = v_round.card_id
      and vr.round_number = v_round.round_number + 1
      and vr.status = 'voting'
      and array_length(vr.tie_player_ids, 1) = array_length(v_actual_tied_player_ids, 1)
      and vr.tie_player_ids @> v_actual_tied_player_ids
      and v_actual_tied_player_ids @> vr.tie_player_ids
  ) into v_associated_tiebreak_exists;

  if v_associated_tiebreak_exists then
    raise exception 'tiebreak_round_already_started';
  end if;

  if v_active_round_id is not null and v_active_round_id <> p_vote_round_id then
    raise exception 'tiebreak_transition_conflict';
  end if;

  if v_round.status = 'closed'
    and coalesce(array_length(v_round.tie_player_ids, 1), 0) = 1
  then
    if not (v_round.tie_player_ids[1] = any(v_actual_tied_player_ids)) then
      raise exception 'invalid_tiebreak_result';
    end if;

    return v_round.tie_player_ids[1];
  end if;

  select tied_id
    into v_winner_id
  from unnest(v_actual_tied_player_ids) as tied_id
  order by random()
  limit 1;

  update public.vote_rounds as vr
    set status = 'closed',
        tie_player_ids = array[v_winner_id]
  where vr.id = p_vote_round_id
    and vr.status in ('voting', 'closed');

  return v_winner_id;
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
  v_active_card_slug text;
  v_active_round_id uuid;
  v_active_round record;
begin
  select vr.id, vr.game_id, vr.card_id, vr.round_number, vr.status
    into v_round
  from public.vote_rounds as vr
  where vr.id = p_vote_round_id
  for update;

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

  select g.active_card_slug
    into v_active_card_slug
  from public.games as g
  where g.id = v_round.game_id;

  if coalesce(v_active_card_slug, '') ~ '::round::[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$' then
    v_active_round_id := substring(
      v_active_card_slug
      from '::round::([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12})$'
    )::uuid;
  end if;

  if v_active_round_id is not null and v_active_round_id <> p_vote_round_id then
    select vr.id, vr.status
      into v_active_round
    from public.vote_rounds as vr
    where vr.id = v_active_round_id
      and vr.game_id = v_round.game_id
      and vr.card_id = v_round.card_id
      and vr.round_number = v_round.round_number + 1
      and coalesce(array_length(vr.tie_player_ids, 1), 0) >= 1;

    if found and v_active_round.status in ('voting', 'closed') then
      raise exception 'tiebreak_round_active';
    end if;
  end if;

  update public.vote_rounds as vr
    set status = 'ready_next'
  where vr.id = p_vote_round_id
    and vr.status = 'closed'
  returning vr.status into v_status;

  if v_status is null then
    raise exception 'invalid_round_transition';
  end if;

  return v_status;
end;
$$;

revoke all on function public.start_tiebreak_round(uuid, text, uuid[]) from public;
revoke all on function public.resolve_random_tiebreak(uuid, text, uuid[]) from public;
revoke all on function public.mark_round_ready_next(uuid, text) from public;

grant execute on function public.start_tiebreak_round(uuid, text, uuid[]) to anon;
grant execute on function public.resolve_random_tiebreak(uuid, text, uuid[]) to anon;
grant execute on function public.mark_round_ready_next(uuid, text) to anon;

commit;
