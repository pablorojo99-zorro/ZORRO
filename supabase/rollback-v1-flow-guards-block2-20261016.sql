begin;

-- Restore the exact remote definitions captured with pg_get_functiondef.

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
  where vr.id = p_vote_round_id
  for update;

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

CREATE OR REPLACE FUNCTION public.join_game_by_code(
  p_code text,
  p_session_id text,
  p_name text
)
RETURNS TABLE(game_id uuid, code text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
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

  perform pg_advisory_xact_lock(
    hashtext(v_game.id::text || ':' || p_session_id)
  );

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
$function$;

CREATE OR REPLACE FUNCTION public.get_player_by_session(
  p_session_id text,
  p_code text DEFAULT NULL::text
)
RETURNS TABLE(
  player_id uuid,
  game_id uuid,
  name text,
  code text,
  is_host boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION public.heartbeat_player(
  p_session_id text,
  p_game_id uuid DEFAULT NULL::uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION public.remove_player_from_game(
  p_host_session_id text,
  p_player_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
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
$function$;

commit;
