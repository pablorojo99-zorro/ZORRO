import { supabase } from '@/lib/supabase'

type GameJoinResult = {
  game_id: string
  code: string
}

export type VoteRoundResult = {
  id: string
  status: string
  tie_player_ids: string[] | null
  card_id: string
}

export async function createGameWithHost(
  code: string,
  hostSessionId: string,
  hostName: string
): Promise<GameJoinResult> {
  const { data, error } = await supabase
    .rpc('create_game_with_host', {
      p_code: code,
      p_host_session_id: hostSessionId,
      p_host_name: hostName,
    })
    .single()

  if (error) throw error
  return data as GameJoinResult
}

export async function joinGameByCode(
  code: string,
  sessionId: string,
  name: string
): Promise<GameJoinResult> {
  const { data, error } = await supabase
    .rpc('join_game_by_code', {
      p_code: code,
      p_session_id: sessionId,
      p_name: name,
    })
    .single()

  if (error) throw error
  return data as GameJoinResult
}

export async function activateGameCard(
  gameId: string,
  sessionId: string,
  cardSlug: string
) {
  const { data, error } = await supabase.rpc('activate_game_card', {
    p_game_id: gameId,
    p_session_id: sessionId,
    p_card_slug: cardSlug,
  })

  if (error) throw error
  return data as string
}

export async function clearActiveCardIfCurrent(
  gameId: string,
  sessionId: string,
  cardSlug: string
) {
  const { error } = await supabase.rpc('clear_active_card_if_current', {
    p_game_id: gameId,
    p_session_id: sessionId,
    p_card_slug: cardSlug,
  })

  if (error) throw error
}

export async function getOrCreateVoteRound(
  gameId: string,
  sessionId: string,
  cardSlug: string,
  roundId: string | null
): Promise<VoteRoundResult> {
  const { data, error } = await supabase
    .rpc('get_or_create_vote_round', {
      p_game_id: gameId,
      p_session_id: sessionId,
      p_card_slug: cardSlug,
      p_round_id: roundId,
    })
    .single()

  if (error) throw error
  return data as VoteRoundResult
}

export async function closeVoteRoundIfComplete(roundId: string, sessionId: string) {
  const { error } = await supabase.rpc('close_vote_round_if_complete', {
    p_vote_round_id: roundId,
    p_session_id: sessionId,
  })

  if (error) throw error
}

export async function markRoundReadyNext(roundId: string, sessionId: string) {
  const { data, error } = await supabase.rpc('mark_round_ready_next', {
    p_vote_round_id: roundId,
    p_session_id: sessionId,
  })

  if (error) throw error
  return data as string
}

export async function startTiebreakRound(
  sourceRoundId: string,
  sessionId: string,
  tiedPlayerIds: string[]
) {
  const { data, error } = await supabase.rpc('start_tiebreak_round', {
    p_source_round_id: sourceRoundId,
    p_session_id: sessionId,
    p_tied_player_ids: tiedPlayerIds,
  })

  if (error) throw error
  return data as string
}

export async function resolveRandomTiebreak(
  roundId: string,
  sessionId: string,
  tiedPlayerIds: string[]
) {
  const { data, error } = await supabase.rpc('resolve_random_tiebreak', {
    p_vote_round_id: roundId,
    p_session_id: sessionId,
    p_tied_player_ids: tiedPlayerIds,
  })

  if (error) throw error
  return data as string
}
