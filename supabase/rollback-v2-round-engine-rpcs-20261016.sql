-- Roll back only the Phase 2C V2 round engine functions.

begin;

drop function if exists public.get_canonical_game_state_v2(uuid, text);
drop function if exists public.mark_round_ready_next_v2(uuid, text, uuid, bigint);
drop function if exists public.resolve_random_tiebreak_v2(uuid, text, uuid, bigint);
drop function if exists public.start_tiebreak_round_v2(uuid, text, uuid, bigint);
drop function if exists public.close_vote_round_if_complete_v2(uuid, text, uuid, bigint);
drop function if exists public.submit_vote_v2(uuid, text, uuid, uuid, bigint);
drop function if exists public.activate_game_card_v2(uuid, text, text, uuid, bigint);
drop function if exists private.complete_v2_operation(uuid, uuid, jsonb, bigint);
drop function if exists private.prepare_v2_operation(uuid, text, uuid, text, jsonb, bigint);

commit;
