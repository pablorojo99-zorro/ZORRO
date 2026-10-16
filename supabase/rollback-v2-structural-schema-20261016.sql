-- Roll back Phase 2C V2 structural schema.
--
-- This rollback is deliberately guarded. It is intended only before any V2
-- game or applied/pending V2 operation exists. It does not modify V1 votes,
-- players, rounds, or game values.

begin;

-- Freeze all V2 structural state before checking that it is unused. The order
-- matches the V2 protocol prefix operation -> games -> vote_rounds, preventing
-- a rollback/RPC lock cycle. ACCESS EXCLUSIVE is appropriate for this explicit
-- maintenance rollback and is held until commit or rollback.
lock table private.v2_operations in access exclusive mode;
lock table public.games in access exclusive mode;
lock table public.vote_rounds in access exclusive mode;

do $$
begin
  if exists (
    select 1
    from public.games as g
    where g.flow_version <> 1
       or g.current_vote_round_id is not null
       or g.transition_version <> 0
  ) then
    raise exception 'v2_structural_rollback_blocked_by_game_state';
  end if;

  if exists (
    select 1
    from public.vote_rounds as vr
    where vr.source_round_id is not null
  ) then
    raise exception 'v2_structural_rollback_blocked_by_round_state';
  end if;

  if exists (
    select 1
    from private.v2_operations
  ) then
    raise exception 'v2_structural_rollback_blocked_by_operation_history';
  end if;
end;
$$;

drop trigger games_prevent_flow_version_change on public.games;
drop function private.prevent_game_flow_version_change();

drop table private.v2_operations;

drop index public.games_current_vote_round_id_idx;

alter table public.games
  drop constraint games_current_vote_round_same_game_fk;

alter table public.vote_rounds
  drop constraint vote_rounds_source_same_game_card_fk;

drop index public.vote_rounds_one_child_per_source_idx;

-- Remove the non-negative CHECK only when this migration created and marked
-- it. Never remove a preexisting constraint with the same name or semantics.
do $$
declare
  v_constraint_oid oid;
begin
  select con.oid
    into v_constraint_oid
  from pg_catalog.pg_constraint as con
  where con.conrelid = 'public.vote_rounds'::regclass
    and con.conname = 'vote_rounds_winning_votes_check'
    and pg_catalog.obj_description(con.oid, 'pg_constraint') =
      'owned_by:v2-structural-schema-20261016';

  if v_constraint_oid is not null then
    alter table public.vote_rounds
      drop constraint vote_rounds_winning_votes_check;
  end if;
end;
$$;

alter table public.vote_rounds
  drop constraint vote_rounds_id_game_card_key,
  drop constraint vote_rounds_id_game_key,
  drop column source_round_id;

alter table public.games
  drop constraint games_transition_version_check,
  drop constraint games_flow_version_check,
  drop column transition_version,
  drop column current_vote_round_id,
  drop column flow_version;

-- The private schema is intentionally retained because it may predate this
-- migration or contain unrelated private objects.

commit;
