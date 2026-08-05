'use client'

import type { FormEvent } from 'react'
import { Suspense, useEffect, useState } from 'react'
import { supabase } from '@/lib/supabase'
import {
  activateGameCard,
  getOrCreateVoteRound,
  getPlayerBySession,
  getVoteState,
  joinGameByCode,
} from '@/lib/game-flow'
import {
  getErrorMessage,
  getOrCreateSessionId,
  storeGameSession,
} from '@/lib/session'
import { usePlayerHeartbeat } from '@/lib/use-player-heartbeat'
import Image from 'next/image'
import { useParams, useRouter, useSearchParams } from 'next/navigation'

type CardData = {
  id: string
  slug: string
  question_text: string
}

type Player = {
  id: string
  name: string
}

type Game = {
  id: string
  code: string
}

type JoinPlayer = {
  id: string
  name: string
}

type VoteRound = {
  id: string
  status: string
  tie_player_ids: string[] | null
}

function hasTiebreakPlayers(round: VoteRound | null) {
  return !!round?.tie_player_ids && round.tie_player_ids.length > 0
}

function haveSamePlayers(firstPlayers: Player[], secondPlayers: Player[]) {
  if (firstPlayers.length !== secondPlayers.length) return false

  return firstPlayers.every((player, index) => {
    const nextPlayer = secondPlayers[index]
    return nextPlayer?.id === player.id && nextPlayer.name === player.name
  })
}

function haveSameMissingVoters(
  firstPlayers: Player[],
  secondPlayers: Player[]
) {
  if (firstPlayers.length !== secondPlayers.length) return false

  return firstPlayers.every((player, index) => {
    const nextPlayer = secondPlayers[index]
    return nextPlayer?.id === player.id && nextPlayer.name === player.name
  })
}

function CardContent() {
  const params = useParams()
  const router = useRouter()
  const searchParams = useSearchParams()
  const slug = params.slug as string
  const roundFromQuery = searchParams.get('round')
  const cameFromAutoRedirect = searchParams.get('auto') === '1'
  const codeFromQuery = searchParams.get('code')

  const [card, setCard] = useState<CardData | null>(null)
  const [game, setGame] = useState<Game | null>(null)
  const [players, setPlayers] = useState<Player[]>([])
  const [currentPlayerId, setCurrentPlayerId] = useState<string | null>(null)
  const [voteCount, setVoteCount] = useState(0)
  const [requiredVoteCount, setRequiredVoteCount] = useState(0)
  const [missingVoters, setMissingVoters] = useState<Player[]>([])
  const [voteRound, setVoteRound] = useState<VoteRound | null>(null)
  const [sessionId, setSessionId] = useState<string | null>(null)
  const [alreadyVoted, setAlreadyVoted] = useState(false)
  const [allVoted, setAllVoted] = useState(false)
  const [submittingVote, setSubmittingVote] = useState(false)
  const [voteSaved, setVoteSaved] = useState(false)
  const [needsGameCode, setNeedsGameCode] = useState(false)
  const [joinName, setJoinName] = useState('')
  const [joinCode, setJoinCode] = useState('')
  const [joinGame, setJoinGame] = useState<Game | null>(null)
  const [joinPlayers, setJoinPlayers] = useState<JoinPlayer[]>([])
  const [joiningGame, setJoiningGame] = useState(false)
  const [loadKey, setLoadKey] = useState(0)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  usePlayerHeartbeat(game?.id || null)

  useEffect(() => {
    async function load() {
      try {
        const sId = localStorage.getItem('session_id')

        if (!sId) {
          setNeedsGameCode(true)
          setLoading(false)
          return
        }

        setSessionId(sId)

        const targetGameCode = codeFromQuery || localStorage.getItem('game_code')
        let player = await getPlayerBySession(sId, targetGameCode).catch((playerError) => {
          console.error('PLAYER ERROR', playerError)
          return null
        })

        if (!player && targetGameCode) {
          const storedPlayerName = localStorage.getItem('player_name')

          if (storedPlayerName) {
            player = await joinGameByCode(targetGameCode, sId, storedPlayerName)
              .then(() => getPlayerBySession(sId, targetGameCode))
              .catch((reconnectError) => {
                console.error('CARD AUTO RECONNECT ERROR', reconnectError)
                return null
              })
          }
        }

        if (!player) {
          setNeedsGameCode(true)
          setLoading(false)
          return
        }

        setCurrentPlayerId(player.player_id)

        if (targetGameCode) {
          storeGameSession(sId, targetGameCode, player.name)
        }

        const { data: gameData, error: gameError } = await supabase
          .from('public_games')
          .select('id, code')
          .eq('id', player.game_id)
          .single()

        if (gameError || !gameData) {
          console.error('GAME ERROR', gameError)
          setError('No se encontró la partida.')
          setLoading(false)
          return
        }

        const { data: cardData, error: cardError } = await supabase
          .from('cards')
          .select('id, slug, question_text')
          .eq('slug', slug)
          .single()

        if (cardError || !cardData) {
          console.error('CARD ERROR', cardError)
          setError('No se encontró esta carta.')
          setLoading(false)
          return
        }

        if (!cameFromAutoRedirect && !roundFromQuery) {
          try {
            await activateGameCard(gameData.id, sId, slug)
          } catch (activeCardError) {
            console.error('ACTIVE CARD ERROR', activeCardError)
          }
        }

        const roundData = await getOrCreateVoteRound(
          gameData.id,
          sId,
          slug,
          roundFromQuery
        )

        if (roundData.status === 'closed') {
          localStorage.setItem(`last_round_${slug}`, roundData.id)
          router.push(`/result/${slug}?round=${roundData.id}`)
          return
        }

        let playersQuery = supabase
          .from('public_players')
          .select('id, name')
          .eq('game_id', gameData.id)

        if (roundData.tie_player_ids && roundData.tie_player_ids.length > 0) {
          playersQuery = playersQuery.in('id', roundData.tie_player_ids)
        }

        const { data: playerList, error: playersError } = await playersQuery

        if (playersError || !playerList) {
          console.error('PLAYERS ERROR', playersError)
          setError('No se pudieron cargar los jugadores.')
          setLoading(false)
          return
        }

        const voteState = await getVoteState(roundData.id, sId).catch((voteStateError) => {
          console.error('VOTE STATE ERROR', voteStateError)
          return null
        })

        if (!voteState) {
          setError('No se pudo comprobar tu voto.')
          setLoading(false)
          return
        }

        setVoteCount(voteState.vote_count)
        setAllVoted(
          voteState.vote_count >= voteState.required_vote_count &&
            voteState.required_vote_count > 0
        )
        setAlreadyVoted(voteState.already_voted)
        setVoteSaved(voteState.already_voted)
        setVoteRound(roundData)
        localStorage.setItem(`last_round_${slug}`, roundData.id)
        setCard(cardData)
        setGame(gameData)
        setRequiredVoteCount(voteState.required_vote_count)
        setPlayers(playerList)
        setMissingVoters(voteState.missing_players)
        setLoading(false)
      } catch (err) {
        console.error('LOAD ERROR', err)
        setError('Ha ocurrido un error cargando la carta.')
        setLoading(false)
      }
    }

    load()
  }, [slug, roundFromQuery, cameFromAutoRedirect, codeFromQuery, loadKey, router])

  useEffect(() => {
    if (allVoted || !voteRound || !game) return

    const currentVoteRound = voteRound
    const currentGame = game
    const currentSessionId = sessionId

    async function refreshVoteState() {
      if (!currentSessionId) return

      const voteState = await getVoteState(currentVoteRound.id, currentSessionId)

      let playersQuery = supabase
        .from('public_players')
        .select('id, name')
        .eq('game_id', currentGame.id)

      if (
        currentVoteRound.tie_player_ids &&
        currentVoteRound.tie_player_ids.length > 0
      ) {
        playersQuery = playersQuery.in('id', currentVoteRound.tie_player_ids)
      }

      const { data: playerList, error: playersError } = await playersQuery

      if (playersError) {
        console.error('PLAYERS REFRESH ERROR', playersError)
        return
      }

      const pendingVoters = voteState.missing_players
      const nextRequiredVoteCount = voteState.required_vote_count

      setVoteCount(voteState.vote_count)
      setPlayers((currentPlayers) => {
        const nextPlayers = playerList || []
        return haveSamePlayers(currentPlayers, nextPlayers) ? currentPlayers : nextPlayers
      })
      setRequiredVoteCount(nextRequiredVoteCount)
      setAlreadyVoted(voteState.already_voted)
      setVoteSaved(voteState.already_voted)
      setMissingVoters((currentMissingVoters) =>
        haveSameMissingVoters(currentMissingVoters, pendingVoters)
          ? currentMissingVoters
          : pendingVoters
      )

      if (voteState.vote_count >= nextRequiredVoteCount && nextRequiredVoteCount > 0) {
        setAllVoted(true)
      }
    }

    refreshVoteState()
    const refreshIntervalId = window.setInterval(refreshVoteState, 15000)

    const channel = supabase
      .channel(`card:${currentVoteRound.id}`)
      .on(
        'postgres_changes',
        {
          event: '*',
          schema: 'public',
          table: 'realtime_events',
          filter: `vote_round_id=eq.${currentVoteRound.id}`,
        },
        refreshVoteState
      )
      .on(
        'postgres_changes',
        {
          event: '*',
          schema: 'public',
          table: 'realtime_events',
          filter: `game_id=eq.${currentGame.id}`,
        },
        refreshVoteState
      )
      .subscribe()

    return () => {
      window.clearInterval(refreshIntervalId)
      supabase.removeChannel(channel)
    }
  }, [allVoted, game, sessionId, voteRound])

  useEffect(() => {
    if (!allVoted || !voteRound) return

    localStorage.setItem(`last_round_${slug}`, voteRound.id)
    router.push(`/result/${slug}?round=${voteRound.id}`)
  }, [allVoted, router, slug, voteRound])

  async function handleVote(playerId: string) {
    if (!voteRound || !sessionId || alreadyVoted || submittingVote) return

    setSubmittingVote(true)

    const { error } = await supabase.rpc('submit_vote', {
      p_vote_round_id: voteRound.id,
      p_voter_session_id: sessionId,
      p_voted_player_id: playerId,
    })

    if (error) {
      console.error('ERROR guardando voto', error)
      setError('No se pudo guardar tu voto.')
      setSubmittingVote(false)
      return
    }

    const voteState = await getVoteState(voteRound.id, sessionId)

    setVoteCount(voteState.vote_count)
    setRequiredVoteCount(voteState.required_vote_count)
    setMissingVoters(voteState.missing_players)
    setVoteSaved(true)
    setAlreadyVoted(true)
    setAllVoted(
      voteState.vote_count >= voteState.required_vote_count &&
        voteState.required_vote_count > 0
    )
    setSubmittingVote(false)
  }

  function finishJoinFromCard(newSessionId: string, cleanCode: string, playerName: string) {
    storeGameSession(newSessionId, cleanCode, playerName)

    setSessionId(newSessionId)
    setNeedsGameCode(false)
    setLoading(true)
    setLoadKey((key) => key + 1)
  }

  async function handleFindGameFromCard(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    setError('')

    if (!joinCode.trim()) {
      setError('Escribe el código de partida')
      return
    }

    try {
      setJoiningGame(true)

      const cleanCode = joinCode.trim().toUpperCase()

      const { data: gameData, error: gameError } = await supabase
        .from('public_games')
        .select('id, code')
        .eq('code', cleanCode)
        .single()

      if (gameError || !gameData) {
        setError('No existe esa partida')
        return
      }

      const { data: playerList, error: playersError } = await supabase
        .from('public_players')
        .select('id, name')
        .eq('game_id', gameData.id)
        .order('created_at', { ascending: true })

      if (playersError || !playerList) {
        throw new Error(getErrorMessage(playersError))
      }

      setJoinGame(gameData)
      setJoinPlayers(playerList)
    } catch (err) {
      const message = getErrorMessage(err)
      console.error('CARD FIND GAME ERROR', message, err)
      setError(`No se pudo cargar la partida: ${message}`)
    } finally {
      setJoiningGame(false)
    }
  }

  async function handleJoinAsNewPlayer(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()

    if (!joinGame) return

    setError('')

    if (!joinName.trim()) {
      setError('Escribe tu nombre')
      return
    }

    try {
      setJoiningGame(true)

      const newSessionId = getOrCreateSessionId()

      const joinedGame = await joinGameByCode(joinGame.code, newSessionId, joinName.trim())

      finishJoinFromCard(newSessionId, joinedGame.code, joinName.trim())
    } catch (err) {
      const message = getErrorMessage(err)
      console.error('CARD NEW PLAYER JOIN ERROR', message, err)
      setError(`No se pudo unir a la partida: ${message}`)
    } finally {
      setJoiningGame(false)
    }
  }

  if (loading) {
    return <p className="p-6">Cargando...</p>
  }

  if (needsGameCode) {
    return (
      <main className="min-h-screen bg-neutral-100 text-neutral-900">
        <div className="mx-auto max-w-md px-6 py-10">
          <div className="relative rounded-3xl bg-white p-6 shadow-sm ring-1 ring-black/5">
            <Image
              src="/zorro-brand-black.svg"
              alt=""
              aria-hidden="true"
              width={60}
              height={60}
              className="absolute right-5 top-4 h-[60px] w-[60px] opacity-75"
            />

            <h1 className="pr-12 text-2xl font-bold tracking-tight">Votar</h1>
            <p className="mt-2 text-sm text-neutral-600">
              Para abrir esta carta, únete primero a la partida.
            </p>

            {!joinGame ? (
              <form onSubmit={handleFindGameFromCard}>
                <div className="mt-6">
                  <label className="mb-2 block text-sm font-medium">
                    Código de partida
                  </label>
                  <input
                    type="text"
                    value={joinCode}
                    onChange={(event) => setJoinCode(event.target.value.toUpperCase())}
                    placeholder="Ej. A7KD"
                    className="w-full rounded-2xl border border-neutral-300 px-4 py-3 uppercase outline-none focus:border-neutral-500"
                  />
                </div>

                <button
                  type="submit"
                  disabled={joiningGame}
                  className="mt-5 w-full rounded-2xl bg-black px-4 py-3 font-medium text-white transition hover:opacity-90 disabled:opacity-50"
                >
                  {joiningGame ? 'Buscando...' : 'Continuar'}
                </button>
              </form>
            ) : (
              <>
                <p className="mt-6 text-sm font-semibold text-neutral-900">
                  ¿Quién eres?
                </p>

                {joinPlayers.length > 0 ? (
                  <div className="mt-3 space-y-2">
                    {joinPlayers.map((player) => (
                      <div
                        key={player.id}
                        className="w-full rounded-2xl border border-neutral-200 px-4 py-3 font-medium text-neutral-500"
                      >
                        {player.name}
                      </div>
                    ))}
                  </div>
                ) : (
                  <p className="mt-3 text-sm text-neutral-500">
                    Todavía no hay jugadores en esta partida.
                  </p>
                )}

                <div className="my-5 h-px bg-neutral-200" />

                <p className="text-sm text-neutral-500">
                  Por seguridad, no se puede recuperar otro jugador desde este dispositivo.
                </p>

                <form onSubmit={handleJoinAsNewPlayer}>
                  <label className="mb-2 block text-sm font-medium">
                    Soy alguien nuevo
                  </label>
                  <input
                    type="text"
                    value={joinName}
                    onChange={(event) => setJoinName(event.target.value)}
                    placeholder="Tu nombre"
                    className="w-full rounded-2xl border border-neutral-300 px-4 py-3 outline-none focus:border-neutral-500"
                  />

                  <button
                    type="submit"
                    disabled={joiningGame}
                    className="mt-3 w-full rounded-2xl bg-black px-4 py-3 font-medium text-white transition hover:opacity-90 disabled:opacity-50"
                  >
                    {joiningGame ? 'Entrando...' : 'Entrar como nuevo jugador'}
                  </button>
                </form>

                <button
                  type="button"
                  onClick={() => {
                    setJoinGame(null)
                    setJoinPlayers([])
                    setError('')
                  }}
                  className="mt-3 w-full rounded-2xl border border-neutral-300 px-4 py-3 font-medium text-neutral-900 transition hover:bg-neutral-50"
                >
                  Cambiar código
                </button>
              </>
            )}

            {error ? (
              <p className="mt-4 text-sm font-medium text-red-600">{error}</p>
            ) : null}
          </div>
        </div>
      </main>
    )
  }

  if (error) {
    return (
      <main className="min-h-screen bg-neutral-100 text-neutral-900">
        <div className="mx-auto max-w-md px-6 py-10">
          <div className="rounded-3xl bg-white p-6 shadow-sm ring-1 ring-black/5">
            <p className="text-red-600">{error}</p>
            <button
              onClick={() => router.push('/')}
              className="mt-4 w-full rounded-2xl bg-black px-4 py-3 font-medium text-white"
            >
              Volver
            </button>
          </div>
        </div>
      </main>
    )
  }

  return (
    <main className="min-h-screen bg-neutral-100 text-neutral-900">
      <div className="mx-auto max-w-md px-6 py-10">
        <div className="relative rounded-3xl bg-white p-6 shadow-sm ring-1 ring-black/5">
          <Image
            src="/zorro-brand-black.svg"
            alt=""
            aria-hidden="true"
            width={60}
            height={60}
            className="absolute right-5 top-4 h-[60px] w-[60px] opacity-75"
          />

          <div className="pr-12">
            <p className="text-sm text-neutral-500">Partida</p>
            <p className="text-lg font-semibold">{game?.code}</p>
          </div>

          <h1 className="mt-6 text-2xl font-bold leading-tight">
            {card?.question_text}
          </h1>

          {!alreadyVoted && (
            <div className="mt-6 space-y-3">
              {players
                .filter((player) => player.id !== currentPlayerId)
                .map((p) => (
                  <button
                    key={p.id}
                    onClick={() => handleVote(p.id)}
                    disabled={submittingVote}
                    className="w-full rounded-2xl border border-neutral-200 px-4 py-4 text-left transition hover:bg-neutral-50 disabled:opacity-50"
                  >
                    {p.name}
                  </button>
                ))}
            </div>
          )}

          {alreadyVoted && !allVoted && (
            <div className="mt-6 text-center">
              <p className="text-sm font-medium text-neutral-900">
                {voteSaved ? 'Voto guardado' : 'Votando...'}
              </p>
              <p className="mt-1 text-sm text-neutral-500">
                {hasTiebreakPlayers(voteRound)
                  ? 'Esperando a que todos voten el desempate...'
                  : 'Esperando a que todos voten...'}
              </p>
              <p className="mt-2 text-2xl font-bold tabular-nums">
                {voteCount}/{requiredVoteCount}
              </p>
              <p className="mt-1 text-xs font-medium uppercase tracking-[0.2em] text-neutral-400">
                votos
              </p>
              {missingVoters.length > 0 ? (
                <p className="mt-3 text-sm text-neutral-500">
                  {missingVoters.length === 1 ? 'Falta' : 'Faltan'}{' '}
                  {missingVoters.map((player) => player.name).join(', ')}
                </p>
              ) : null}
            </div>
          )}

          {alreadyVoted && allVoted && (
            <p className="mt-6 text-center text-sm text-neutral-500">
              Cargando resultado...
            </p>
          )}
        </div>
      </div>
    </main>
  )
}

export default function CardPage() {
  return (
    <Suspense fallback={<p className="p-6">Cargando...</p>}>
      <CardContent />
    </Suspense>
  )
}
