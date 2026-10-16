-- Restore the three RPC definitions that preceded the tiebreak transition lock migration.

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

revoke all on function public.start_tiebreak_round(uuid, text, uuid[]) from public;
revoke all on function public.resolve_random_tiebreak(uuid, text, uuid[]) from public;
revoke all on function public.mark_round_ready_next(uuid, text) from public;

grant execute on function public.start_tiebreak_round(uuid, text, uuid[]) to anon;
grant execute on function public.resolve_random_tiebreak(uuid, text, uuid[]) to anon;
grant execute on function public.mark_round_ready_next(uuid, text) to anon;

commit;
