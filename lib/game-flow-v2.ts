import { supabase } from '@/lib/supabase'
import { generateSessionId, getErrorMessage } from '@/lib/session'

export type GameJoinResultV2 = {
  game_id: string
  code: string
}

export type PlayerSessionResultV2 = {
  player_id: string
  game_id: string
  name: string
  code: string
  is_host: boolean
}

export type CanonicalGameStateV2 = {
  game_id: string
  flow_version: 2
  transition_version: number
  active_card_slug: string | null
  current_round_number: number
  current_vote_round_id: string | null
  status: 'voting' | 'closed' | 'ready_next' | null
  card_id: string | null
  round_number: number | null
  source_round_id: string | null
  tie_player_ids: string[] | null
  winning_player_id: string | null
  winning_votes: number | null
  vote_count: number
  required_vote_count: number
  already_voted: boolean
  missing_players: { id: string; name: string }[]
}

export type MutationEnvelopeV2 = {
  operation_id: string
  game_id: string
  transition_version: number
  current_vote_round_id: string | null
  status: 'voting' | 'closed' | 'ready_next'
  result: Record<string, unknown>
}

type StoredOperation = {
  operationId: string
  payload: string
}

function operationStorageKey(gameId: string, action: string) {
  return `v2_operation:${gameId}:${action}`
}

export function getOrCreateOperationId(
  gameId: string,
  action: string,
  payload: unknown
) {
  const key = operationStorageKey(gameId, action)
  const serializedPayload = JSON.stringify(payload)
  const storedValue = localStorage.getItem(key)

  if (storedValue) {
    try {
      const stored = JSON.parse(storedValue) as StoredOperation
      if (stored.payload === serializedPayload && stored.operationId) {
        return stored.operationId
      }
    } catch {
      // Replace malformed local recovery state below.
    }
  }

  const operationId = generateSessionId()
  localStorage.setItem(
    key,
    JSON.stringify({ operationId, payload: serializedPayload } satisfies StoredOperation)
  )
  return operationId
}

export function clearOperationId(gameId: string, action: string) {
  localStorage.removeItem(operationStorageKey(gameId, action))
}

export function isStaleTransitionError(error: unknown) {
  return getErrorMessage(error).toLowerCase().includes('stale_transition_version')
}

export function isUncertainMutationError(error: unknown) {
  const message = getErrorMessage(error).toLowerCase()
  return (
    error instanceof TypeError ||
    message.includes('failed to fetch') ||
    message.includes('load failed') ||
    message.includes('network') ||
    message.includes('fetch') ||
    message.includes('abort') ||
    message.includes('timeout')
  )
}

async function rpcSingle<T>(name: string, args: Record<string, unknown>) {
  const { data, error } = await supabase.rpc(name, args).single()
  if (error) throw error
  return data as T
}

async function rpcValue<T>(name: string, args: Record<string, unknown>) {
  const { data, error } = await supabase.rpc(name, args)
  if (error) throw error
  return data as T
}

export function createGameWithHostV2(code: string, sessionId: string, name: string) {
  return rpcSingle<GameJoinResultV2>('create_game_with_host_v2', {
    p_code: code,
    p_host_session_id: sessionId,
    p_host_name: name,
  })
}

export function joinGameByCodeV2(code: string, sessionId: string, name: string) {
  return rpcSingle<GameJoinResultV2>('join_game_by_code_v2', {
    p_code: code,
    p_session_id: sessionId,
    p_name: name,
  })
}

export async function getPlayerBySessionV2(sessionId: string, code?: string | null) {
  const { data, error } = await supabase
    .rpc('get_player_by_session_v2', {
      p_session_id: sessionId,
      p_code: code || null,
    })
    .maybeSingle()
  if (error) throw error
  return data as PlayerSessionResultV2 | null
}

export async function heartbeatPlayerV2(sessionId: string, gameId: string) {
  const { error } = await supabase.rpc('heartbeat_player_v2', {
    p_session_id: sessionId,
    p_game_id: gameId,
  })
  if (error) throw error
}

export async function removePlayerFromGameV2(sessionId: string, playerId: string) {
  const { error } = await supabase.rpc('remove_player_from_game_v2', {
    p_host_session_id: sessionId,
    p_player_id: playerId,
  })
  if (error) throw error
}

export function getCanonicalGameStateV2(gameId: string, sessionId: string) {
  return rpcValue<CanonicalGameStateV2>('get_canonical_game_state_v2', {
    p_game_id: gameId,
    p_session_id: sessionId,
  })
}

export function activateGameCardV2(
  gameId: string,
  sessionId: string,
  cardSlug: string,
  operationId: string,
  expectedVersion: number
) {
  return rpcValue<MutationEnvelopeV2>('activate_game_card_v2', {
    p_game_id: gameId,
    p_session_id: sessionId,
    p_card_slug: cardSlug,
    p_operation_id: operationId,
    p_expected_transition_version: expectedVersion,
  })
}

export function submitVoteV2(
  roundId: string,
  sessionId: string,
  playerId: string,
  operationId: string,
  expectedVersion: number
) {
  return rpcValue<MutationEnvelopeV2>('submit_vote_v2', {
    p_vote_round_id: roundId,
    p_voter_session_id: sessionId,
    p_voted_player_id: playerId,
    p_operation_id: operationId,
    p_expected_transition_version: expectedVersion,
  })
}

export function closeVoteRoundV2(
  roundId: string,
  sessionId: string,
  operationId: string,
  expectedVersion: number
) {
  return rpcValue<MutationEnvelopeV2>('close_vote_round_if_complete_v2', {
    p_vote_round_id: roundId,
    p_session_id: sessionId,
    p_operation_id: operationId,
    p_expected_transition_version: expectedVersion,
  })
}

export function startTiebreakRoundV2(
  sourceRoundId: string,
  sessionId: string,
  operationId: string,
  expectedVersion: number
) {
  return rpcValue<MutationEnvelopeV2>('start_tiebreak_round_v2', {
    p_source_round_id: sourceRoundId,
    p_session_id: sessionId,
    p_operation_id: operationId,
    p_expected_transition_version: expectedVersion,
  })
}

export function resolveRandomTiebreakV2(
  roundId: string,
  sessionId: string,
  operationId: string,
  expectedVersion: number
) {
  return rpcValue<MutationEnvelopeV2>('resolve_random_tiebreak_v2', {
    p_vote_round_id: roundId,
    p_session_id: sessionId,
    p_operation_id: operationId,
    p_expected_transition_version: expectedVersion,
  })
}

export function markRoundReadyNextV2(
  roundId: string,
  sessionId: string,
  operationId: string,
  expectedVersion: number
) {
  return rpcValue<MutationEnvelopeV2>('mark_round_ready_next_v2', {
    p_vote_round_id: roundId,
    p_session_id: sessionId,
    p_operation_id: operationId,
    p_expected_transition_version: expectedVersion,
  })
}

export async function retryUncertainV2Mutation<T>(operation: () => Promise<T>) {
  try {
    return await operation()
  } catch (error) {
    if (!isUncertainMutationError(error)) throw error
    return operation()
  }
}
