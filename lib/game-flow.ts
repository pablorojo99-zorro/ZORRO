import { supabase } from '@/lib/supabase'

type GameJoinResult = {
  game_id: string
  code: string
}

export type PlayerSessionResult = {
  player_id: string
  game_id: string
  name: string
  code: string
  is_host: boolean
}

export type VoteRoundResult = {
  id: string
  status: string
  tie_player_ids: string[] | null
  card_id: string
}

export type VoteStateResult = {
  vote_count: number
  required_vote_count: number
  already_voted: boolean
  missing_players: { id: string; name: string }[]
}

export type RoundResult = {
  round_id: string
  status: string
  winners: { id: string; name: string; votes: number }[]
  tied_players: { id: string; name: string }[]
  vote_count: number
  required_vote_count: number
}

export async function getPlayerBySession(
  sessionId: string,
  code?: string | null
): Promise<PlayerSessionResult> {
  const { data, error } = await supabase
    .rpc('get_player_by_session', {
      p_session_id: sessionId,
      p_code: code || null,
    })
    .single()

  if (error) throw error
  return data as PlayerSessionResult
}

export async function heartbeatPlayer(sessionId: string, gameId?: string | null) {
  const { error } = await supabase.rpc('heartbeat_player', {
    p_session_id: sessionId,
    p_game_id: gameId || null,
  })

  if (error) throw error
}

export async function removePlayerFromGame(hostSessionId: string, playerId: string) {
  const { error } = await supabase.rpc('remove_player_from_game', {
    p_host_session_id: hostSessionId,
    p_player_id: playerId,
  })

  if (error) throw error
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

export async function getVoteState(
  roundId: string,
  sessionId: string
): Promise<VoteStateResult> {
  const { data, error } = await supabase
    .rpc('get_vote_state', {
      p_vote_round_id: roundId,
      p_session_id: sessionId,
    })
    .single()

  if (error) throw error
  return data as VoteStateResult
}

export async function getRoundResult(
  roundId: string,
  sessionId: string
): Promise<RoundResult> {
  const { data, error } = await supabase
    .rpc('get_round_result', {
      p_vote_round_id: roundId,
      p_session_id: sessionId,
    })
    .single()

  if (error) throw error
  return data as RoundResult
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
