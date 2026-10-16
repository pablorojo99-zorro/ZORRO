-- Add privacy-safe vote progress to the canonical V2 game state.
-- Apply after v2-round-engine-rpcs-20261016.sql.

begin;

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
  with canonical_state as (
    select
      g.id as game_id,
      g.flow_version,
      g.transition_version,
      g.active_card_slug,
      g.current_round_number,
      g.current_vote_round_id,
      vr.status,
      vr.card_id,
      vr.round_number,
      vr.source_round_id,
      vr.tie_player_ids,
      vr.winning_player_id,
      vr.winning_votes
    from public.games as g
    left join public.vote_rounds as vr
      on vr.id = g.current_vote_round_id
     and vr.game_id = g.id
    where g.id = p_game_id
      and g.flow_version = 2
      and exists (
        select 1
        from public.players as p
        where p.game_id = p_game_id
          and p.session_id = p_session_id
          and p.active = true
      )
  ),
  eligible_players as (
    select p.id, p.name, p.session_id, p.created_at
    from canonical_state as cs
    join public.players as p
      on p.game_id = cs.game_id
    where cs.status = 'voting'
      and p.active = true
      and (
        p.last_seen_at >= now() - interval '90 seconds'
        or exists (
          select 1
          from public.votes as v
          where v.vote_round_id = cs.current_vote_round_id
            and v.voter_session_id = p.session_id
        )
      )
  )
  select jsonb_build_object(
    'game_id', cs.game_id,
    'flow_version', cs.flow_version,
    'transition_version', cs.transition_version,
    'active_card_slug', cs.active_card_slug,
    'current_round_number', cs.current_round_number,
    'current_vote_round_id', cs.current_vote_round_id,
    'status', cs.status,
    'card_id', cs.card_id,
    'round_number', cs.round_number,
    'source_round_id', cs.source_round_id,
    'tie_player_ids', cs.tie_player_ids,
    'winning_player_id', cs.winning_player_id,
    'winning_votes', cs.winning_votes,
    'vote_count', case
      when cs.status = 'voting' then (
        select count(distinct v.voter_session_id)
        from public.votes as v
        where v.vote_round_id = cs.current_vote_round_id
      )
      else 0
    end,
    'required_vote_count', case
      when cs.status = 'voting' then (
        select count(*)
        from eligible_players
      )
      else 0
    end,
    'already_voted', case
      when cs.status = 'voting' then exists (
        select 1
        from public.votes as v
        where v.vote_round_id = cs.current_vote_round_id
          and v.voter_session_id = p_session_id
      )
      else false
    end,
    'missing_players', case
      when cs.status = 'voting' then coalesce((
        select jsonb_agg(
          jsonb_build_object('id', ep.id, 'name', ep.name)
          order by ep.created_at
        )
        from eligible_players as ep
        where not exists (
          select 1
          from public.votes as v
          where v.vote_round_id = cs.current_vote_round_id
            and v.voter_session_id = ep.session_id
        )
      ), '[]'::jsonb)
      else '[]'::jsonb
    end
  ) into v_result
  from canonical_state as cs;

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

revoke all on function public.get_canonical_game_state_v2(uuid, text) from public;
revoke all on function public.get_canonical_game_state_v2(uuid, text) from authenticated;
grant execute on function public.get_canonical_game_state_v2(uuid, text) to anon;

commit;
