-- Secure vote submission for production.
-- Apply this in Supabase SQL editor before relying on submit_vote from the app.

begin;

create unique index if not exists votes_one_vote_per_round_session_key
  on public.votes (vote_round_id, voter_session_id);

create or replace function public.submit_vote(
  p_vote_round_id uuid,
  p_voter_session_id text,
  p_voted_player_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_round record;
  v_voter record;
  v_target record;
begin
  select id, game_id, status, tie_player_ids
    into v_round
  from public.vote_rounds
  where id = p_vote_round_id;

  if not found then
    raise exception 'vote_round_not_found';
  end if;

  if v_round.status <> 'voting' then
    raise exception 'vote_round_not_open';
  end if;

  select id, game_id
    into v_voter
  from public.players
  where session_id = p_voter_session_id
    and active = true
  limit 1;

  if not found then
    raise exception 'voter_not_found';
  end if;

  if v_voter.game_id <> v_round.game_id then
    raise exception 'voter_not_in_game';
  end if;

  select id, game_id
    into v_target
  from public.players
  where id = p_voted_player_id
    and active = true;

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

revoke all on function public.submit_vote(uuid, text, uuid) from public;
grant execute on function public.submit_vote(uuid, text, uuid) to anon;

alter table public.votes enable row level security;

drop policy if exists "votes can be inserted directly by anon" on public.votes;

commit;
