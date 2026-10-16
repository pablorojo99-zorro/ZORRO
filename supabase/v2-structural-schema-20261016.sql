-- Phase 2C V2: additive structural schema only.
--
-- This migration intentionally does not create or replace application RPCs,
-- change existing views, or create V2 games. Existing rows remain flow_version 1.

begin;

alter table public.games
  add column flow_version smallint not null default 1,
  add column current_vote_round_id uuid,
  add column transition_version bigint not null default 0;

alter table public.games
  add constraint games_flow_version_check
    check (flow_version in (1, 2)),
  add constraint games_transition_version_check
    check (transition_version >= 0);

alter table public.vote_rounds
  add column source_round_id uuid;

-- winning_player_id and winning_votes predate V2 in the deployed schema.
-- Preserve both columns and the existing winning-player foreign key. Add the
-- non-negative invariant only when no equivalent CHECK already exists. A
-- marker comment lets the rollback distinguish a V2-owned CHECK from one that
-- existed before this migration.
do $$
declare
  v_vote_rounds_oid oid := 'public.vote_rounds'::regclass::oid;
  v_constraint_oid oid;
begin
  select con.oid
    into v_constraint_oid
  from pg_catalog.pg_constraint as con
  where con.conrelid = v_vote_rounds_oid
    and con.contype = 'c'
    and lower(
      pg_catalog.regexp_replace(
        pg_catalog.pg_get_expr(con.conbin, con.conrelid),
        '[[:space:]()]',
        '',
        'g'
      )
    ) in (
      'winning_votes>=0',
      'winning_votesisnullorwinning_votes>=0'
    )
  limit 1;

  if v_constraint_oid is not null then
    return;
  end if;

  if exists (
    select 1
    from pg_catalog.pg_constraint as con
    where con.conrelid = v_vote_rounds_oid
      and con.conname = 'vote_rounds_winning_votes_check'
  ) then
    raise exception 'vote_rounds_winning_votes_check_name_collision';
  end if;

  alter table public.vote_rounds
    add constraint vote_rounds_winning_votes_check
    check (winning_votes is null or winning_votes >= 0);

  comment on constraint vote_rounds_winning_votes_check
    on public.vote_rounds
    is 'owned_by:v2-structural-schema-20261016';
end;
$$;

-- PostgreSQL requires an exact UNIQUE/PRIMARY KEY candidate matching every
-- referenced composite column list. The existing primary key on id alone does
-- not provide the composite candidates used by the same-game/same-card FKs.
alter table public.vote_rounds
  add constraint vote_rounds_id_game_key
    unique (id, game_id),
  add constraint vote_rounds_id_game_card_key
    unique (id, game_id, card_id);

-- At most one direct child can be created from a given source round. NULL is
-- intentionally unrestricted for original/non-V2 rounds.
create unique index vote_rounds_one_child_per_source_idx
  on public.vote_rounds (source_round_id)
  where source_round_id is not null;

-- The game id is included on both sides, making it impossible to point a game
-- at a round belonging to another game. Deleting the selected round clears only
-- the nullable pointer, never games.id. The constraint is deferred so a whole
-- game can be deleted together with its ON DELETE CASCADE vote_rounds.
alter table public.games
  add constraint games_current_vote_round_same_game_fk
  foreign key (current_vote_round_id, id)
  references public.vote_rounds (id, game_id)
  on delete set null (current_vote_round_id)
  deferrable initially deferred;

-- A child must reference a source from the same game and card. Deleting a
-- source also removes its descendants; deleting a game remains compatible with
-- the existing vote_rounds.game_id ON DELETE CASCADE path.
alter table public.vote_rounds
  add constraint vote_rounds_source_same_game_card_fk
  foreign key (source_round_id, game_id, card_id)
  references public.vote_rounds (id, game_id, card_id)
  on delete cascade
  deferrable initially deferred;

-- Supporting lookup indexes. The unique source index already covers
-- source_round_id, while this index serves current-round reverse lookups.
create index games_current_vote_round_id_idx
  on public.games (current_vote_round_id)
  where current_vote_round_id is not null;

create schema if not exists private;

revoke all on schema private from public;
revoke all on schema private from anon;
revoke all on schema private from authenticated;

-- Private idempotency journal. It deliberately has no FK to games or players:
-- historical responses must remain recoverable even after gameplay advances,
-- and journal writes must not introduce implicit row locks on those tables.
create table private.v2_operations (
  game_id uuid not null,
  operation_id uuid not null,
  actor_player_id uuid not null,
  operation_name text not null,
  request_fingerprint text not null,
  request_payload jsonb not null,
  status text not null default 'pending',
  result jsonb,
  result_transition_version bigint,
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  constraint v2_operations_pkey
    primary key (game_id, operation_id),
  constraint v2_operations_status_check
    check (status in ('pending', 'applied')),
  constraint v2_operations_applied_result_check
    check (
      (
        status = 'pending'
        and result is null
        and result_transition_version is null
        and completed_at is null
      )
      or
      (
        status = 'applied'
        and result is not null
        and result_transition_version is not null
        and completed_at is not null
      )
    ),
  constraint v2_operations_result_transition_version_check
    check (
      result_transition_version is null
      or result_transition_version >= 0
    )
);

-- A V2 RPC must create and complete its journal row in the same transaction.
-- No RPC may commit a row whose status is still 'pending'. The pending state is
-- only an uncommitted serialization point for concurrent calls using the same
-- (game_id, operation_id).

create index v2_operations_game_created_idx
  on private.v2_operations (game_id, created_at desc);

alter table private.v2_operations enable row level security;

revoke all on table private.v2_operations from public;
revoke all on table private.v2_operations from anon;
revoke all on table private.v2_operations from authenticated;

create or replace function private.prevent_game_flow_version_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.flow_version is distinct from old.flow_version then
    raise exception 'game_flow_version_immutable';
  end if;

  return new;
end;
$$;

revoke all on function private.prevent_game_flow_version_change() from public;
revoke all on function private.prevent_game_flow_version_change() from anon;
revoke all on function private.prevent_game_flow_version_change() from authenticated;

create trigger games_prevent_flow_version_change
before update of flow_version on public.games
for each row
execute function private.prevent_game_flow_version_change();

commit;
