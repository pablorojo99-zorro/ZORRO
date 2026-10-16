#!/usr/bin/env node

import { createClient } from '@supabase/supabase-js'
import process from 'node:process'
import { randomUUID } from 'node:crypto'
import { pathToFileURL } from 'node:url'

const REQUIRED_CONFIRMATION = 'CREATE_REMOTE_V2_TEST_DATA'
const allowedCodeCharacters = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'
const report = []
let testGameCode = null
let supabase
let cardSlug

function fail(message) {
  throw new Error(message)
}

function assert(condition, message) {
  if (!condition) fail(message)
}

function record(name, status, details = '') {
  report.push({ name, status, details })
  console.log(`${status.padEnd(4)} ${name}${details ? ` — ${details}` : ''}`)
}

function session() {
  return `v2test-${randomUUID()}`
}

function operation() {
  return randomUUID()
}

function gameCode() {
  return Array.from({ length: 4 }, () =>
    allowedCodeCharacters[Math.floor(Math.random() * allowedCodeCharacters.length)]
  ).join('')
}

function errorMessage(error) {
  if (error instanceof Error) return error.message
  if (error && typeof error === 'object' && 'message' in error) return String(error.message)
  return String(error)
}

function hasError(error, expected) {
  return errorMessage(error).toLowerCase().includes(expected.toLowerCase())
}

async function expectError(name, expected, action) {
  let caughtError
  try {
    await action()
  } catch (error) {
    caughtError = error
  }

  if (!caughtError) fail(`${name}: expected ${expected}, but the call succeeded`)
  if (!hasError(caughtError, expected)) throw caughtError
  record(name, 'PASS', expected)
}

function assertEnvelope(value, operationId) {
  assert(value && typeof value === 'object', 'mutation did not return a JSON object')
  assert(value.operation_id === operationId, 'operation_id mismatch')
  assert(typeof value.transition_version === 'number', 'transition_version is not a number')
  return value
}

function sameJson(left, right) {
  return JSON.stringify(left) === JSON.stringify(right)
}

function requireOptIn() {
  if (!process.argv.includes('--confirm-write-tests')) {
    fail('Missing --confirm-write-tests. This executor creates persistent remote test data.')
  }
  if (process.env.V2_TEST_CONFIRM !== REQUIRED_CONFIRMATION) {
    fail(`Set V2_TEST_CONFIRM=${REQUIRED_CONFIRMATION} to confirm remote writes.`)
  }
  for (const name of [
    'NEXT_PUBLIC_SUPABASE_URL',
    'NEXT_PUBLIC_SUPABASE_ANON_KEY',
    'V2_TEST_CARD_SLUG',
  ]) {
    if (!process.env[name]) fail(`Missing required environment variable: ${name}`)
  }
}

async function rpc(name, args) {
  const { data, error } = await supabase.rpc(name, args)
  if (error) throw error
  return data
}

async function rpcOne(name, args) {
  const data = await rpc(name, args)
  assert(Array.isArray(data) && data.length === 1, `${name} did not return exactly one row`)
  return data[0]
}

async function canonical(gameId, playerSession) {
  return rpc('get_canonical_game_state_v2', {
    p_game_id: gameId,
    p_session_id: playerSession,
  })
}

async function createFreshGame(hostSession, hostName) {
  let lastError
  for (let attempt = 0; attempt < 12; attempt += 1) {
    const code = gameCode()
    try {
      const created = await rpcOne('create_game_with_host_v2', {
        p_code: code,
        p_host_session_id: hostSession,
        p_host_name: hostName,
      })
      return created
    } catch (error) {
      if (!error || typeof error !== 'object' || error.code !== '23505') throw error
      lastError = error
    }
  }
  throw lastError
}

async function submitVote(roundId, voterSession, targetId, version, operationId = operation()) {
  return rpc('submit_vote_v2', {
    p_vote_round_id: roundId,
    p_voter_session_id: voterSession,
    p_voted_player_id: targetId,
    p_operation_id: operationId,
    p_expected_transition_version: version,
  })
}

async function run() {
  console.log('MUTATING REMOTE V2 TESTS: data will be retained; no cleanup is performed.')

  const suffix = randomUUID().slice(0, 8)
  const players = [
    { label: 'host', name: `V2TEST-HOST-${suffix}`, session: session() },
    { label: 'p2', name: `V2TEST-P2-${suffix}`, session: session() },
    { label: 'p3', name: `V2TEST-P3-${suffix}`, session: session() },
    { label: 'p4', name: `V2TEST-P4-${suffix}`, session: session() },
  ]

  const created = await createFreshGame(players[0].session, players[0].name)
  testGameCode = created.code
  const gameId = created.game_id
  record('create V2 game', 'PASS', `code=${testGameCode}`)

  for (const player of players.slice(1)) {
    const joined = await rpcOne('join_game_by_code_v2', {
      p_code: testGameCode,
      p_session_id: player.session,
      p_name: player.name,
    })
    assert(joined.game_id === gameId, `${player.label} joined the wrong game`)
  }
  record('join three players', 'PASS')

  for (const player of players) {
    const recovered = await rpcOne('get_player_by_session_v2', {
      p_session_id: player.session,
      p_code: testGameCode,
    })
    player.id = recovered.player_id
    assert(recovered.game_id === gameId, `${player.label} recovered the wrong game`)
    assert(recovered.is_host === (player.label === 'host'), `${player.label} role mismatch`)
  }
  record('recover four sessions', 'PASS')

  let state = await canonical(gameId, players[0].session)
  assert(state.flow_version === 2 && state.transition_version === 0, 'invalid initial state')
  record('initial canonical state', 'PASS')

  const firstActivationId = operation()
  const firstActivationArgs = {
    p_game_id: gameId,
    p_session_id: players[0].session,
    p_card_slug: cardSlug,
    p_operation_id: firstActivationId,
    p_expected_transition_version: state.transition_version,
  }
  const firstActivation = assertEnvelope(
    await rpc('activate_game_card_v2', firstActivationArgs),
    firstActivationId
  )
  const replay = await rpc('activate_game_card_v2', firstActivationArgs)
  assert(sameJson(firstActivation, replay), 'idempotent replay returned a different result')
  state = await canonical(gameId, players[0].session)
  assert(state.transition_version === firstActivation.transition_version,
    'activation replay advanced the transition version')
  assert(state.current_vote_round_id === firstActivation.current_vote_round_id,
    'activation replay changed the canonical round')
  record('activate card and replay same operation', 'PASS')

  await expectError('same operation_id with different payload', 'operation_id_conflict', () =>
    rpc('activate_game_card_v2', {
      ...firstActivationArgs,
      p_expected_transition_version: firstActivation.transition_version,
    })
  )
  await expectError('NULL expected transition version', 'stale_transition_version', () =>
    rpc('activate_game_card_v2', {
      ...firstActivationArgs,
      p_operation_id: operation(),
      p_expected_transition_version: null,
    })
  )
  await expectError('stale transition version', 'stale_transition_version', () =>
    rpc('activate_game_card_v2', {
      ...firstActivationArgs,
      p_operation_id: operation(),
      p_expected_transition_version: 0,
    })
  )

  state = await canonical(gameId, players[0].session)
  const firstRound = state.current_vote_round_id
  const votingVersion = state.transition_version
  assert(firstRound && state.status === 'voting', 'first round is not voting')

  const uniqueVotes = [
    [players[0], players[1]],
    [players[1], players[0]],
    [players[2], players[1]],
    [players[3], players[1]],
  ]
  const voteResults = await Promise.allSettled(uniqueVotes.map(([voter, target]) =>
    submitVote(firstRound, voter.session, target.id, votingVersion)
  ))
  assert(voteResults.every((item) => item.status === 'fulfilled'), 'simultaneous votes did not all succeed')
  assert(voteResults.every((item) =>
    item.value.transition_version === votingVersion
      && item.value.current_vote_round_id === firstRound
      && item.value.status === 'voting'
  ), 'a vote changed or reported the wrong canonical transition')
  record('simultaneous votes with shared version', 'PASS')

  const closeCalls = [players[0], players[1]].map((actor) => {
    const operationId = operation()
    return rpc('close_vote_round_if_complete_v2', {
      p_vote_round_id: firstRound,
      p_session_id: actor.session,
      p_operation_id: operationId,
      p_expected_transition_version: votingVersion,
    })
  })
  const closeResults = await Promise.allSettled(closeCalls)
  const closeSuccesses = closeResults.filter((item) => item.status === 'fulfilled')
  const closeFailures = closeResults.filter((item) => item.status === 'rejected')
  assert(closeSuccesses.length === 1, 'exactly one concurrent close must succeed')
  assert(closeFailures.length === 1 && hasError(closeFailures[0].reason, 'stale_transition_version'),
    'losing close must be stale')

  state = await canonical(gameId, players[0].session)
  const winningClose = closeSuccesses[0].value
  assert(state.transition_version === winningClose.transition_version,
    'canonical version does not match the winning close')
  assert(state.current_vote_round_id === winningClose.current_vote_round_id,
    'canonical round does not match the winning close')
  assert(state.status === 'closed', 'first round was not closed')
  assert(state.winning_player_id === players[1].id && state.winning_votes === 3,
    'unique winner was not persisted')
  record('two simultaneous closes', 'PASS')
  record('unique winner in canonical state', 'PASS')

  const readyId = operation()
  await rpc('mark_round_ready_next_v2', {
    p_vote_round_id: firstRound,
    p_session_id: players[0].session,
    p_operation_id: readyId,
    p_expected_transition_version: state.transition_version,
  })
  state = await canonical(gameId, players[0].session)
  assert(state.status === 'ready_next', 'round did not become ready_next')

  const activationCalls = [players[0], players[1]].map((actor) => rpc('activate_game_card_v2', {
    p_game_id: gameId,
    p_session_id: actor.session,
    p_card_slug: cardSlug,
    p_operation_id: operation(),
    p_expected_transition_version: state.transition_version,
  }))
  const activationResults = await Promise.allSettled(activationCalls)
  const activationSuccesses = activationResults.filter((item) => item.status === 'fulfilled')
  assert(activationSuccesses.length === 1,
    'exactly one concurrent activation must succeed')
  const activationFailure = activationResults.find((item) => item.status === 'rejected')
  assert(activationFailure && hasError(activationFailure.reason, 'stale_transition_version'),
    'losing activation must be stale')
  state = await canonical(gameId, players[0].session)
  const winningActivation = activationSuccesses[0].value
  assert(state.transition_version === winningActivation.transition_version,
    'canonical version does not match the winning activation')
  assert(state.current_vote_round_id === winningActivation.current_vote_round_id,
    'canonical round does not match the winning activation')
  const tieRound = state.current_vote_round_id
  const tieVotingVersion = state.transition_version
  assert(tieRound && tieRound !== firstRound && state.winning_player_id === null,
    'new round retained prior result data')
  record('ready_next and two simultaneous activations', 'PASS')

  const tieVotes = [
    [players[0], players[1]],
    [players[1], players[0]],
    [players[2], players[0]],
    [players[3], players[1]],
  ]
  await Promise.all(tieVotes.map(([voter, target]) =>
    submitVote(tieRound, voter.session, target.id, tieVotingVersion)
  ))
  await rpc('close_vote_round_if_complete_v2', {
    p_vote_round_id: tieRound,
    p_session_id: players[0].session,
    p_operation_id: operation(),
    p_expected_transition_version: tieVotingVersion,
  })
  state = await canonical(gameId, players[0].session)
  assert(state.winning_player_id === null && state.winning_votes === 2,
    'tie result was not persisted correctly')
  assert(Array.isArray(state.tie_player_ids) && state.tie_player_ids.length === 2,
    'tie candidates are incorrect')
  record('persist tied result', 'PASS')

  const tiebreakCalls = [players[0], players[1]].map((actor) => rpc('start_tiebreak_round_v2', {
    p_source_round_id: tieRound,
    p_session_id: actor.session,
    p_operation_id: operation(),
    p_expected_transition_version: state.transition_version,
  }))
  const tiebreakResults = await Promise.allSettled(tiebreakCalls)
  const tiebreakSuccesses = tiebreakResults.filter((item) => item.status === 'fulfilled')
  assert(tiebreakSuccesses.length === 1,
    'exactly one tiebreak creation must succeed')
  const tiebreakFailure = tiebreakResults.find((item) => item.status === 'rejected')
  assert(tiebreakFailure && hasError(tiebreakFailure.reason, 'stale_transition_version'),
    'losing tiebreak creation must be stale')
  state = await canonical(gameId, players[0].session)
  const winningTiebreak = tiebreakSuccesses[0].value
  assert(state.transition_version === winningTiebreak.transition_version,
    'canonical version does not match the winning tiebreak creation')
  assert(state.current_vote_round_id === winningTiebreak.current_vote_round_id,
    'canonical round does not match the winning tiebreak creation')
  const childRound = state.current_vote_round_id
  const childVersion = state.transition_version
  assert(state.source_round_id === tieRound && state.status === 'voting', 'invalid child round')
  record('two simultaneous tiebreak creations', 'PASS')

  await Promise.all(tieVotes.map(([voter, target]) =>
    submitVote(childRound, voter.session, target.id, childVersion)
  ))
  await rpc('close_vote_round_if_complete_v2', {
    p_vote_round_id: childRound,
    p_session_id: players[0].session,
    p_operation_id: operation(),
    p_expected_transition_version: childVersion,
  })
  state = await canonical(gameId, players[0].session)
  assert(state.status === 'closed' && state.winning_player_id === null,
    'child round did not close as a tie')

  const randomId = operation()
  const randomArgs = {
    p_vote_round_id: childRound,
    p_session_id: players[0].session,
    p_operation_id: randomId,
    p_expected_transition_version: state.transition_version,
  }
  const randomResult = await rpc('resolve_random_tiebreak_v2', randomArgs)
  const randomReplay = await rpc('resolve_random_tiebreak_v2', randomArgs)
  assert(sameJson(randomResult, randomReplay), 'random winner changed on replay')
  state = await canonical(gameId, players[0].session)
  assert(state.winning_player_id === randomResult.result.winning_player_id,
    'canonical random winner mismatch')
  assert(state.tie_player_ids.length === 1 && state.tie_player_ids[0] === state.winning_player_id,
    'resolved tie representation is incorrect')
  record('random tiebreak and idempotent replay', 'PASS')

  await rpc('heartbeat_player_v2', {
    p_session_id: players[2].session,
    p_game_id: gameId,
  })
  await expectError('non-host removal rejected', 'host_not_found', () =>
    rpc('remove_player_from_game_v2', {
      p_host_session_id: players[1].session,
      p_player_id: players[2].id,
    })
  )
  await expectError('host self-removal rejected', 'cannot_remove_self', () =>
    rpc('remove_player_from_game_v2', {
      p_host_session_id: players[0].session,
      p_player_id: players[0].id,
    })
  )
  await rpc('remove_player_from_game_v2', {
    p_host_session_id: players[0].session,
    p_player_id: players[3].id,
  })
  const removed = await rpc('get_player_by_session_v2', {
    p_session_id: players[3].session,
    p_code: testGameCode,
  })
  assert(Array.isArray(removed) && removed.length === 0, 'removed player session was still active')
  await expectError('removed player canonical access rejected', 'player_not_in_game', () =>
    canonical(gameId, players[3].session)
  )
  const rejoined = await rpcOne('join_game_by_code_v2', {
    p_code: testGameCode,
    p_session_id: players[3].session,
    p_name: players[3].name,
  })
  const recoveredAgain = await rpcOne('get_player_by_session_v2', {
    p_session_id: players[3].session,
    p_code: testGameCode,
  })
  assert(rejoined.game_id === gameId && recoveredAgain.player_id === players[3].id,
    'rejoin did not reactivate the same player')
  record('presence, removal and rejoin', 'PASS')

  const beforeV1 = await canonical(gameId, players[0].session)
  await expectError('V1 mutation rejects V2 game', 'client_upgrade_required', () =>
    rpc('activate_game_card', {
      p_game_id: gameId,
      p_session_id: players[0].session,
      p_card_slug: cardSlug,
    })
  )
  const afterV1 = await canonical(gameId, players[0].session)
  assert(sameJson(beforeV1, afterV1), 'V1 rejection changed canonical V2 state')
  record('V1/V2 isolation', 'PASS')
}

async function main() {
  requireOptIn()
  supabase = createClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY,
    { auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false } }
  )
  cardSlug = process.env.V2_TEST_CARD_SLUG

  try {
    await run()
    console.log(`\nRESULT PASS — ${report.length} checks; retained game code=${testGameCode}`)
  } catch (error) {
    record('test run', 'FAIL', errorMessage(error))
    console.error(`\nRESULT FAIL — retained game code=${testGameCode ?? 'not-created'}`)
    process.exitCode = 1
  }
}

const isDirectExecution = Boolean(process.argv[1])
  && import.meta.url === pathToFileURL(process.argv[1]).href

if (isDirectExecution) await main()
