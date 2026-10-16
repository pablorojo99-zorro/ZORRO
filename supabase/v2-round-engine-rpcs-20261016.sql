-- Phase 2C V2: canonical round and voting engine.
-- Requires v2-structural-schema-20261016.sql.

begin;

create or replace function private.prepare_v2_operation(
  p_game_id uuid,
  p_session_id text,
  p_operation_id uuid,
  p_operation_name text,
  p_request_payload jsonb,
  p_expected_transition_version bigint
)
returns table(
  actor_player_id uuid,
  transition_version bigint,
  current_vote_round_id uuid,
  replay_result jsonb,
  is_replay boolean
)
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_game record;
  v_operation record;
  v_actor_id uuid;
  v_fingerprint text := md5(p_request_payload::text);
begin
  select g.id, g.flow_version, g.transition_version, g.current_vote_round_id
    into v_game
  from public.games as g
  where g.id = p_game_id
  for update;

  if not found then
    raise exception 'game_not_found';
  end if;

  if v_game.flow_version <> 2 then
    raise exception 'game_flow_version_mismatch';
  end if;

  select o.actor_player_id, o.operation_name, o.request_fingerprint,
         o.request_payload, o.status, o.result
    into v_operation
  from private.v2_operations as o
  where o.game_id = p_game_id
    and o.operation_id = p_operation_id
  for update;

  if found then
    if v_operation.operation_name <> p_operation_name
      or v_operation.request_fingerprint <> v_fingerprint
      or v_operation.request_payload <> p_request_payload
      or not exists (
        select 1
        from public.players as p
        where p.id = v_operation.actor_player_id
          and p.game_id = p_game_id
          and p.session_id = p_session_id
      )
    then
      raise exception 'operation_id_conflict';
    end if;

    if v_operation.status <> 'applied' or v_operation.result is null then
      raise exception 'operation_pending';
    end if;

    return query select v_operation.actor_player_id,
      v_game.transition_version, v_game.current_vote_round_id,
      v_operation.result, true;
    return;
  end if;

  select p.id
    into v_actor_id
  from public.players as p
  where p.game_id = p_game_id
    and p.session_id = p_session_id
    and p.active = true
  order by p.created_at asc
  limit 1;

  if not found then
    raise exception 'player_not_in_game';
  end if;

  if v_game.transition_version is distinct from p_expected_transition_version then
    raise exception 'stale_transition_version';
  end if;

  insert into private.v2_operations (
    game_id, operation_id, actor_player_id, operation_name,
    request_fingerprint, request_payload, status
  ) values (
    p_game_id, p_operation_id, v_actor_id, p_operation_name,
    v_fingerprint, p_request_payload, 'pending'
  );

  return query select v_actor_id, v_game.transition_version,
    v_game.current_vote_round_id, null::jsonb, false;
end;
$function$;

create or replace function private.complete_v2_operation(
  p_game_id uuid,
  p_operation_id uuid,
  p_result jsonb,
  p_transition_version bigint
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
begin
  update private.v2_operations as o
    set status = 'applied',
        result = p_result,
        result_transition_version = p_transition_version,
        completed_at = now()
  where o.game_id = p_game_id
    and o.operation_id = p_operation_id
    and o.status = 'pending';

  if not found then
    raise exception 'operation_not_pending';
  end if;

  return p_result;
end;
$function$;

create or replace function public.activate_game_card_v2(
  p_game_id uuid,
  p_session_id text,
  p_card_slug text,
  p_operation_id uuid,
  p_expected_transition_version bigint
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_context record;
  v_current_round record;
  v_card record;
  v_round_id uuid;
  v_round_number integer;
  v_new_version bigint;
  v_result jsonb;
  v_payload jsonb := jsonb_build_object(
    'session_id', p_session_id, 'card_slug', p_card_slug,
    'expected_transition_version', p_expected_transition_version
  );
begin
  select * into v_context
  from private.prepare_v2_operation(
    p_game_id, p_session_id, p_operation_id, 'activate_game_card_v2',
    v_payload, p_expected_transition_version
  );

  if v_context.is_replay then return v_context.replay_result; end if;

  if v_context.current_vote_round_id is not null then
    select vr.id, vr.status
      into v_current_round
    from public.vote_rounds as vr
    where vr.id = v_context.current_vote_round_id
      and vr.game_id = p_game_id
    for update;

    if not found then raise exception 'canonical_round_not_found'; end if;
    if v_current_round.status <> 'ready_next' then
      raise exception 'round_not_ready_next';
    end if;
  end if;

  select c.id, c.slug
    into v_card
  from public.cards as c
  where c.slug = p_card_slug
    and c.active = true;

  if not found then raise exception 'card_not_found'; end if;

  update public.players as p
    set last_seen_at = now(), disconnected_at = null
  where p.id = v_context.actor_player_id
    and p.game_id = p_game_id
    and p.active = true;

  if not found then raise exception 'player_not_in_game'; end if;

  select coalesce(max(vr.round_number), 0) + 1
    into v_round_number
  from public.vote_rounds as vr
  where vr.game_id = p_game_id
    and vr.card_id = v_card.id;

  insert into public.vote_rounds (game_id, card_id, round_number, status)
  values (p_game_id, v_card.id, v_round_number, 'voting')
  returning id into v_round_id;

  update public.games as g
    set active_card_slug = v_card.slug,
        current_round_number = g.current_round_number + 1,
        current_vote_round_id = v_round_id,
        transition_version = g.transition_version + 1
  where g.id = p_game_id
  returning g.transition_version into v_new_version;

  v_result := jsonb_build_object(
    'operation_id', p_operation_id, 'game_id', p_game_id,
    'transition_version', v_new_version,
    'current_vote_round_id', v_round_id, 'status', 'voting',
    'result', jsonb_build_object('card_id', v_card.id,
      'card_slug', v_card.slug, 'round_number', v_round_number)
  );
  return private.complete_v2_operation(p_game_id, p_operation_id, v_result, v_new_version);
end;
$function$;

create or replace function public.submit_vote_v2(
  p_vote_round_id uuid,
  p_voter_session_id text,
  p_voted_player_id uuid,
  p_operation_id uuid,
  p_expected_transition_version bigint
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_game_id uuid;
  v_context record;
  v_round record;
  v_target record;
  v_result jsonb;
  v_payload jsonb := jsonb_build_object(
    'voter_session_id', p_voter_session_id,
    'vote_round_id', p_vote_round_id,
    'voted_player_id', p_voted_player_id,
    'expected_transition_version', p_expected_transition_version
  );
begin
  select vr.game_id into v_game_id
  from public.vote_rounds as vr where vr.id = p_vote_round_id;
  if not found then raise exception 'vote_round_not_found'; end if;

  select * into v_context
  from private.prepare_v2_operation(
    v_game_id, p_voter_session_id, p_operation_id, 'submit_vote_v2',
    v_payload, p_expected_transition_version
  );
  if v_context.is_replay then return v_context.replay_result; end if;

  select vr.id, vr.status, vr.tie_player_ids
    into v_round
  from public.vote_rounds as vr
  where vr.id = p_vote_round_id
    and vr.game_id = v_game_id
  for update;

  if not found then raise exception 'vote_round_not_found'; end if;
  if v_context.current_vote_round_id is distinct from p_vote_round_id
    or v_round.status <> 'voting' then
    raise exception 'vote_round_not_open';
  end if;

  select p.id into v_target
  from public.players as p
  where p.id = p_voted_player_id
    and p.game_id = v_game_id
    and p.active = true;
  if not found then raise exception 'target_not_found'; end if;
  if v_target.id = v_context.actor_player_id then raise exception 'self_vote_not_allowed'; end if;
  if coalesce(array_length(v_round.tie_player_ids, 1), 0) > 0
    and not (v_target.id = any(v_round.tie_player_ids)) then
    raise exception 'target_not_in_tiebreak';
  end if;

  update public.players as p
    set last_seen_at = now(), disconnected_at = null
  where p.id = v_context.actor_player_id
    and p.game_id = v_game_id and p.active = true;
  if not found then raise exception 'voter_not_found'; end if;

  insert into public.votes (vote_round_id, voter_session_id, voted_player_id)
  values (p_vote_round_id, p_voter_session_id, p_voted_player_id);

  v_result := jsonb_build_object(
    'operation_id', p_operation_id, 'game_id', v_game_id,
    'transition_version', v_context.transition_version,
    'current_vote_round_id', p_vote_round_id, 'status', 'voting',
    'result', jsonb_build_object('voted_player_id', p_voted_player_id)
  );
  return private.complete_v2_operation(
    v_game_id, p_operation_id, v_result, v_context.transition_version
  );
end;
$function$;

create or replace function public.close_vote_round_if_complete_v2(
  p_vote_round_id uuid,
  p_session_id text,
  p_operation_id uuid,
  p_expected_transition_version bigint
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_game_id uuid;
  v_context record;
  v_round record;
  v_required_count integer;
  v_vote_count integer;
  v_max_votes integer;
  v_winner_ids uuid[];
  v_new_version bigint;
  v_result jsonb;
  v_payload jsonb := jsonb_build_object(
    'session_id', p_session_id, 'vote_round_id', p_vote_round_id,
    'expected_transition_version', p_expected_transition_version
  );
begin
  select vr.game_id into v_game_id
  from public.vote_rounds as vr where vr.id = p_vote_round_id;
  if not found then raise exception 'vote_round_not_found'; end if;

  select * into v_context
  from private.prepare_v2_operation(
    v_game_id, p_session_id, p_operation_id,
    'close_vote_round_if_complete_v2', v_payload,
    p_expected_transition_version
  );
  if v_context.is_replay then return v_context.replay_result; end if;

  select vr.id, vr.status into v_round
  from public.vote_rounds as vr
  where vr.id = p_vote_round_id and vr.game_id = v_game_id
  for update;
  if not found then raise exception 'vote_round_not_found'; end if;
  if v_context.current_vote_round_id is distinct from p_vote_round_id
    or v_round.status <> 'voting' then raise exception 'vote_round_not_open'; end if;

  update public.players as p
    set last_seen_at = now(), disconnected_at = null
  where p.id = v_context.actor_player_id
    and p.game_id = v_game_id and p.active = true;
  if not found then raise exception 'player_not_in_game'; end if;

  select count(*) into v_required_count
  from public.players as p
  where p.game_id = v_game_id and p.active = true
    and (p.last_seen_at >= now() - interval '90 seconds'
      or exists (select 1 from public.votes as v
        where v.vote_round_id = p_vote_round_id
          and v.voter_session_id = p.session_id));

  select count(distinct v.voter_session_id) into v_vote_count
  from public.votes as v where v.vote_round_id = p_vote_round_id;
  if v_required_count = 0 or v_vote_count < v_required_count then
    raise exception 'vote_round_not_complete';
  end if;

  with counts as (
    select v.voted_player_id, count(*)::integer as total
    from public.votes as v where v.vote_round_id = p_vote_round_id
    group by v.voted_player_id
  ), maximum as (select max(total) as total from counts)
  select m.total, array_agg(c.voted_player_id order by c.voted_player_id)
    into v_max_votes, v_winner_ids
  from counts as c cross join maximum as m
  where c.total = m.total group by m.total;

  update public.vote_rounds as vr
    set status = 'closed',
        winning_player_id = case when array_length(v_winner_ids, 1) = 1 then v_winner_ids[1] else null end,
        winning_votes = v_max_votes,
        tie_player_ids = case when array_length(v_winner_ids, 1) > 1 then v_winner_ids else null end
  where vr.id = p_vote_round_id;

  update public.games as g
    set transition_version = g.transition_version + 1
  where g.id = v_game_id returning g.transition_version into v_new_version;

  v_result := jsonb_build_object(
    'operation_id', p_operation_id, 'game_id', v_game_id,
    'transition_version', v_new_version,
    'current_vote_round_id', p_vote_round_id, 'status', 'closed',
    'result', jsonb_build_object('vote_count', v_vote_count,
      'required_vote_count', v_required_count,
      'winning_player_id', case when array_length(v_winner_ids, 1) = 1 then v_winner_ids[1] else null end,
      'winning_votes', v_max_votes,
      'tie_player_ids', case when array_length(v_winner_ids, 1) > 1 then v_winner_ids else null end)
  );
  return private.complete_v2_operation(v_game_id, p_operation_id, v_result, v_new_version);
end;
$function$;

create or replace function public.start_tiebreak_round_v2(
  p_source_round_id uuid,
  p_session_id text,
  p_operation_id uuid,
  p_expected_transition_version bigint
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_game_id uuid;
  v_context record;
  v_source record;
  v_round_id uuid;
  v_round_number integer;
  v_valid_candidate_count integer;
  v_new_version bigint;
  v_result jsonb;
  v_payload jsonb := jsonb_build_object(
    'session_id', p_session_id, 'source_round_id', p_source_round_id,
    'expected_transition_version', p_expected_transition_version
  );
begin
  select vr.game_id into v_game_id
  from public.vote_rounds as vr where vr.id = p_source_round_id;
  if not found then raise exception 'vote_round_not_found'; end if;
  select * into v_context from private.prepare_v2_operation(
    v_game_id, p_session_id, p_operation_id, 'start_tiebreak_round_v2',
    v_payload, p_expected_transition_version
  );
  if v_context.is_replay then return v_context.replay_result; end if;

  select vr.id, vr.card_id, vr.status, vr.tie_player_ids, vr.winning_player_id
    into v_source
  from public.vote_rounds as vr
  where vr.id = p_source_round_id and vr.game_id = v_game_id
  for update;
  if not found then raise exception 'vote_round_not_found'; end if;
  if v_context.current_vote_round_id is distinct from p_source_round_id
    or v_source.status <> 'closed' then raise exception 'invalid_tiebreak_round'; end if;
  if v_source.winning_player_id is not null then
    raise exception 'invalid_tiebreak_round';
  end if;
  if coalesce(array_length(v_source.tie_player_ids, 1), 0) < 2 then
    raise exception 'invalid_tiebreak_round';
  end if;

  select count(*) into v_valid_candidate_count
  from public.players as p
  where p.game_id = v_game_id
    and p.active = true
    and p.id = any(v_source.tie_player_ids);

  if v_valid_candidate_count <> array_length(v_source.tie_player_ids, 1) then
    raise exception 'invalid_tiebreak_players';
  end if;

  update public.players as p set last_seen_at = now(), disconnected_at = null
  where p.id = v_context.actor_player_id
    and p.game_id = v_game_id and p.active = true;
  if not found then raise exception 'player_not_in_game'; end if;

  select coalesce(max(vr.round_number), 0) + 1 into v_round_number
  from public.vote_rounds as vr
  where vr.game_id = v_game_id and vr.card_id = v_source.card_id;

  insert into public.vote_rounds (
    game_id, card_id, round_number, status, tie_player_ids, source_round_id
  ) values (
    v_game_id, v_source.card_id, v_round_number, 'voting',
    v_source.tie_player_ids, p_source_round_id
  ) returning id into v_round_id;

  update public.games as g
    set current_vote_round_id = v_round_id,
        transition_version = g.transition_version + 1
  where g.id = v_game_id returning g.transition_version into v_new_version;

  v_result := jsonb_build_object(
    'operation_id', p_operation_id, 'game_id', v_game_id,
    'transition_version', v_new_version,
    'current_vote_round_id', v_round_id, 'status', 'voting',
    'result', jsonb_build_object('source_round_id', p_source_round_id,
      'tie_player_ids', v_source.tie_player_ids, 'round_number', v_round_number)
  );
  return private.complete_v2_operation(v_game_id, p_operation_id, v_result, v_new_version);
end;
$function$;

create or replace function public.resolve_random_tiebreak_v2(
  p_vote_round_id uuid,
  p_session_id text,
  p_operation_id uuid,
  p_expected_transition_version bigint
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_game_id uuid;
  v_context record;
  v_round record;
  v_winner_id uuid;
  v_valid_candidate_count integer;
  v_new_version bigint;
  v_result jsonb;
  v_payload jsonb := jsonb_build_object(
    'session_id', p_session_id, 'vote_round_id', p_vote_round_id,
    'expected_transition_version', p_expected_transition_version
  );
begin
  select vr.game_id into v_game_id from public.vote_rounds as vr
  where vr.id = p_vote_round_id;
  if not found then raise exception 'vote_round_not_found'; end if;
  select * into v_context from private.prepare_v2_operation(
    v_game_id, p_session_id, p_operation_id, 'resolve_random_tiebreak_v2',
    v_payload, p_expected_transition_version
  );
  if v_context.is_replay then return v_context.replay_result; end if;

  select vr.id, vr.status, vr.tie_player_ids, vr.winning_player_id, vr.winning_votes
    into v_round from public.vote_rounds as vr
  where vr.id = p_vote_round_id and vr.game_id = v_game_id
  for update;
  if not found then raise exception 'vote_round_not_found'; end if;
  if v_context.current_vote_round_id is distinct from p_vote_round_id
    or v_round.status <> 'closed'
    or coalesce(array_length(v_round.tie_player_ids, 1), 0) < 2 then
    raise exception 'invalid_tiebreak_round';
  end if;
  if v_round.winning_player_id is not null then
    raise exception 'invalid_tiebreak_round';
  end if;

  select count(*) into v_valid_candidate_count
  from public.players as p
  where p.game_id = v_game_id
    and p.active = true
    and p.id = any(v_round.tie_player_ids);

  if v_valid_candidate_count <> array_length(v_round.tie_player_ids, 1) then
    raise exception 'invalid_tiebreak_players';
  end if;

  update public.players as p set last_seen_at = now(), disconnected_at = null
  where p.id = v_context.actor_player_id
    and p.game_id = v_game_id and p.active = true;
  if not found then raise exception 'player_not_in_game'; end if;

  select tied_id into v_winner_id
  from unnest(v_round.tie_player_ids) as tied_id order by random() limit 1;

  update public.vote_rounds as vr
    set winning_player_id = v_winner_id,
        tie_player_ids = array[v_winner_id]
  where vr.id = p_vote_round_id;
  update public.games as g set transition_version = g.transition_version + 1
  where g.id = v_game_id returning g.transition_version into v_new_version;

  v_result := jsonb_build_object(
    'operation_id', p_operation_id, 'game_id', v_game_id,
    'transition_version', v_new_version,
    'current_vote_round_id', p_vote_round_id, 'status', 'closed',
    'result', jsonb_build_object('winning_player_id', v_winner_id)
  );
  return private.complete_v2_operation(v_game_id, p_operation_id, v_result, v_new_version);
end;
$function$;

create or replace function public.mark_round_ready_next_v2(
  p_vote_round_id uuid,
  p_session_id text,
  p_operation_id uuid,
  p_expected_transition_version bigint
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_game_id uuid;
  v_context record;
  v_round record;
  v_new_version bigint;
  v_result jsonb;
  v_payload jsonb := jsonb_build_object(
    'session_id', p_session_id, 'vote_round_id', p_vote_round_id,
    'expected_transition_version', p_expected_transition_version
  );
begin
  select vr.game_id into v_game_id from public.vote_rounds as vr
  where vr.id = p_vote_round_id;
  if not found then raise exception 'vote_round_not_found'; end if;
  select * into v_context from private.prepare_v2_operation(
    v_game_id, p_session_id, p_operation_id, 'mark_round_ready_next_v2',
    v_payload, p_expected_transition_version
  );
  if v_context.is_replay then return v_context.replay_result; end if;

  select vr.id, vr.status, vr.winning_player_id into v_round
  from public.vote_rounds as vr
  where vr.id = p_vote_round_id and vr.game_id = v_game_id
  for update;
  if not found then raise exception 'vote_round_not_found'; end if;
  if v_context.current_vote_round_id is distinct from p_vote_round_id
    or v_round.status <> 'closed' then raise exception 'vote_round_not_closed'; end if;
  if v_round.winning_player_id is null then raise exception 'tiebreak_unresolved'; end if;

  update public.players as p set last_seen_at = now(), disconnected_at = null
  where p.id = v_context.actor_player_id
    and p.game_id = v_game_id and p.active = true;
  if not found then raise exception 'player_not_in_game'; end if;

  update public.vote_rounds as vr set status = 'ready_next'
  where vr.id = p_vote_round_id;
  update public.games as g set transition_version = g.transition_version + 1
  where g.id = v_game_id returning g.transition_version into v_new_version;

  v_result := jsonb_build_object(
    'operation_id', p_operation_id, 'game_id', v_game_id,
    'transition_version', v_new_version,
    'current_vote_round_id', p_vote_round_id, 'status', 'ready_next',
    'result', jsonb_build_object('winning_player_id', v_round.winning_player_id)
  );
  return private.complete_v2_operation(v_game_id, p_operation_id, v_result, v_new_version);
end;
$function$;

create or replace function public.get_canonical_game_state_v2(
  p_game_id uuid,
  p_session_id text
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_result jsonb;
begin
  select jsonb_build_object(
    'game_id', g.id, 'flow_version', g.flow_version,
    'transition_version', g.transition_version,
    'active_card_slug', g.active_card_slug,
    'current_round_number', g.current_round_number,
    'current_vote_round_id', g.current_vote_round_id,
    'status', vr.status, 'card_id', vr.card_id,
    'round_number', vr.round_number,
    'source_round_id', vr.source_round_id,
    'tie_player_ids', vr.tie_player_ids,
    'winning_player_id', vr.winning_player_id,
    'winning_votes', vr.winning_votes
  ) into v_result
  from public.games as g
  left join public.vote_rounds as vr
    on vr.id = g.current_vote_round_id and vr.game_id = g.id
  where g.id = p_game_id
    and g.flow_version = 2
    and exists (
      select 1
      from public.players as p
      where p.game_id = p_game_id
        and p.session_id = p_session_id
        and p.active = true
    );

  if not found then
    if exists (
      select 1
      from public.games as g
      where g.id = p_game_id
        and g.flow_version = 2
    ) then
      raise exception 'player_not_in_game';
    end if;

    raise exception 'game_not_found';
  end if;
  return v_result;
end;
$function$;

revoke all on function private.prepare_v2_operation(uuid, text, uuid, text, jsonb, bigint) from public;
revoke all on function private.prepare_v2_operation(uuid, text, uuid, text, jsonb, bigint) from anon;
revoke all on function private.prepare_v2_operation(uuid, text, uuid, text, jsonb, bigint) from authenticated;
revoke all on function private.complete_v2_operation(uuid, uuid, jsonb, bigint) from public;
revoke all on function private.complete_v2_operation(uuid, uuid, jsonb, bigint) from anon;
revoke all on function private.complete_v2_operation(uuid, uuid, jsonb, bigint) from authenticated;

revoke all on function public.activate_game_card_v2(uuid, text, text, uuid, bigint) from public;
revoke all on function public.submit_vote_v2(uuid, text, uuid, uuid, bigint) from public;
revoke all on function public.close_vote_round_if_complete_v2(uuid, text, uuid, bigint) from public;
revoke all on function public.start_tiebreak_round_v2(uuid, text, uuid, bigint) from public;
revoke all on function public.resolve_random_tiebreak_v2(uuid, text, uuid, bigint) from public;
revoke all on function public.mark_round_ready_next_v2(uuid, text, uuid, bigint) from public;
revoke all on function public.get_canonical_game_state_v2(uuid, text) from public;

revoke all on function public.activate_game_card_v2(uuid, text, text, uuid, bigint) from authenticated;
revoke all on function public.submit_vote_v2(uuid, text, uuid, uuid, bigint) from authenticated;
revoke all on function public.close_vote_round_if_complete_v2(uuid, text, uuid, bigint) from authenticated;
revoke all on function public.start_tiebreak_round_v2(uuid, text, uuid, bigint) from authenticated;
revoke all on function public.resolve_random_tiebreak_v2(uuid, text, uuid, bigint) from authenticated;
revoke all on function public.mark_round_ready_next_v2(uuid, text, uuid, bigint) from authenticated;
revoke all on function public.get_canonical_game_state_v2(uuid, text) from authenticated;

grant execute on function public.activate_game_card_v2(uuid, text, text, uuid, bigint) to anon;
grant execute on function public.submit_vote_v2(uuid, text, uuid, uuid, bigint) to anon;
grant execute on function public.close_vote_round_if_complete_v2(uuid, text, uuid, bigint) to anon;
grant execute on function public.start_tiebreak_round_v2(uuid, text, uuid, bigint) to anon;
grant execute on function public.resolve_random_tiebreak_v2(uuid, text, uuid, bigint) to anon;
grant execute on function public.mark_round_ready_next_v2(uuid, text, uuid, bigint) to anon;
grant execute on function public.get_canonical_game_state_v2(uuid, text) to anon;

commit;
