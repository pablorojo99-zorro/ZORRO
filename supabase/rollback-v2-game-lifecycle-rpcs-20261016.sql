-- Roll back only the Phase 2C V2 lifecycle RPCs.

begin;

drop function if exists public.remove_player_from_game_v2(text, uuid);
drop function if exists public.heartbeat_player_v2(text, uuid);
drop function if exists public.get_player_by_session_v2(text, text);
drop function if exists public.join_game_by_code_v2(text, text, text);
drop function if exists public.create_game_with_host_v2(text, text, text);

commit;
