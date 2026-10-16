-- Serialize vote submission and round closure on the same vote_rounds row.
-- This migration preserves the existing RPC signatures, validation rules,
-- error messages, presence updates, vote insertion, and closing criteria.
-- Apply only after validating and testing it in an independent Supabase project.

begin;

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

commit;
