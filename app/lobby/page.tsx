'use client'

import { Suspense, useCallback, useEffect, useRef, useState } from 'react'
import { supabase } from '@/lib/supabase'
import {
  getActiveCardRoundId,
  getActiveCardSlug,
  getCardScanMessage,
} from '@/lib/active-card'
import { cardExists, createCardSlugFromCode } from '@/lib/cards'
import {
  activateGameCard,
  getPlayerBySession,
  joinGameByCode,
  removePlayerFromGame,
} from '@/lib/game-flow'
import { getErrorMessage, getStoredSessionId, isMissingRowError } from '@/lib/session'
import { usePlayerHeartbeat } from '@/lib/use-player-heartbeat'
import { useRecoverableNavigation } from '@/lib/use-recoverable-navigation'
import { useStateReconciliation } from '@/lib/use-state-reconciliation'
import Image from 'next/image'
import { useRouter, useSearchParams } from 'next/navigation'

type Player = {
  id: string
  name: string
  is_host: boolean
  presence_status: 'online' | 'reconnecting' | 'offline'
}

function LobbyContent() {
  const searchParams = useSearchParams()
  const router = useRouter()
  const code = searchParams.get('code')

  const [players, setPlayers] = useState<Player[]>([])
  const [gameId, setGameId] = useState<string | null>(null)
  const [currentPlayerId, setCurrentPlayerId] = useState<string | null>(null)
  const [currentPlayerIsHost, setCurrentPlayerIsHost] = useState(false)
  const [cardCode, setCardCode] = useState('')
  const [cardScanMessage, setCardScanMessage] = useState('')
  const [openingCard, setOpeningCard] = useState(false)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [sessionRecoveryPending, setSessionRecoveryPending] = useState(false)
  const [recoveryKey, setRecoveryKey] = useState(0)
  const [removingPlayerId, setRemovingPlayerId] = useState<string | null>(null)
  const mountedRef = useRef(true)
  const playersRequestIdRef = useRef(0)
  const activeCardRequestIdRef = useRef(0)
  const lobbyLoadRequestIdRef = useRef(0)
  const navigateRecoverably = useRecoverableNavigation(router)
  usePlayerHeartbeat(gameId)

  useEffect(() => {
    mountedRef.current = true

    return () => {
      mountedRef.current = false
      playersRequestIdRef.current += 1
      activeCardRequestIdRef.current += 1
      lobbyLoadRequestIdRef.current += 1
    }
  }, [])

  const redirectToActiveCard = useCallback((activeCardValue: string, gameCode?: string | null) => {
    const activeCardSlug = getActiveCardSlug(activeCardValue)
    const activeCardRoundId = getActiveCardRoundId(activeCardValue)

    if (!activeCardSlug) return

    if (activeCardRoundId) {
      const nextParams = new URLSearchParams({ auto: '1', round: activeCardRoundId })

      if (gameCode) {
        nextParams.set('code', gameCode)
      }

      navigateRecoverably(`/card/${activeCardSlug}?${nextParams.toString()}`)
      return
    }

    const nextParams = new URLSearchParams({ auto: '1' })

    if (gameCode) {
      nextParams.set('code', gameCode)
    }

    if (navigateRecoverably(`/card/${activeCardSlug}?${nextParams.toString()}`, 1200)) {
      setCardScanMessage(getCardScanMessage(activeCardValue))
    }
  }, [navigateRecoverably])

  const loadPlayers = useCallback(async (currentGameId: string) => {
    const requestId = ++playersRequestIdRef.current
    const { data: playerList, error: playersError } = await supabase
      .from('public_players')
      .select('id, name, is_host, presence_status')
      .eq('game_id', currentGameId)
      .order('created_at', { ascending: true })

    if (!mountedRef.current || requestId !== playersRequestIdRef.current) return

    if (playersError) {
      console.error('ERROR cargando jugadores', playersError)
      setError('No se pudieron cargar los jugadores')
      return
    }

    setPlayers(playerList || [])
  }, [])

  const loadActiveCard = useCallback(async (currentGameId: string) => {
    const requestId = ++activeCardRequestIdRef.current
    const { data: game, error: gameError } = await supabase
      .from('public_games')
      .select('active_card_slug')
      .eq('id', currentGameId)
      .single()

    if (!mountedRef.current || requestId !== activeCardRequestIdRef.current) return

    if (gameError) {
      console.error('ERROR cargando carta activa', gameError)
      return
    }

    if (game?.active_card_slug) {
      redirectToActiveCard(game.active_card_slug, code)
    }
  }, [code, redirectToActiveCard])

  const reconcileLobby = useCallback(async () => {
    if (!gameId) return

    await Promise.all([
      loadPlayers(gameId),
      loadActiveCard(gameId),
    ])
  }, [gameId, loadActiveCard, loadPlayers])

  const requestLobbyReconciliation = useStateReconciliation(
    reconcileLobby,
    !!gameId
  )

  const reconcileSession = useCallback(() => {
    setRecoveryKey((key) => key + 1)
  }, [])

  const requestSessionRecovery = useStateReconciliation(
    reconcileSession,
    sessionRecoveryPending
  )

  useEffect(() => {
    if (!sessionRecoveryPending) return

    requestSessionRecovery()
    const retryId = window.setInterval(requestSessionRecovery, 5000)

    return () => window.clearInterval(retryId)
  }, [requestSessionRecovery, sessionRecoveryPending])

  async function handleGoToCardByCode() {
    const nextCardSlug = createCardSlugFromCode(cardCode)

    if (!nextCardSlug || !gameId || openingCard) return

    setOpeningCard(true)
    setError('')

    try {
      const exists = await cardExists(nextCardSlug)

      if (!exists) {
        setError('No existe esa carta.')
        setOpeningCard(false)
        return
      }
    } catch (err) {
      console.error('CARD VALIDATION ERROR', err)
      setError('No se pudo comprobar la carta.')
      setOpeningCard(false)
      return
    }

    const sessionId = localStorage.getItem('session_id')

    if (!sessionId) {
      setError('No se pudo identificar tu sesión.')
      setOpeningCard(false)
      return
    }

    if (!currentPlayerId) {
      const storedPlayerName = localStorage.getItem('player_name')

      if (!code || !storedPlayerName) {
        setError('Vuelve a entrar en la partida antes de abrir carta.')
        setOpeningCard(false)
        return
      }

      try {
        await joinGameByCode(code, sessionId, storedPlayerName)
        const player = await getPlayerBySession(sessionId, code)

        if (!player) {
          throw new Error('player_not_found_after_reconnect')
        }

        setCurrentPlayerId(player.player_id)
        setCurrentPlayerIsHost(player.is_host)
      } catch (err) {
        console.error('LOBBY RECONNECT BEFORE CARD ERROR', err)
        setError(`No se pudo recuperar tu jugador: ${getErrorMessage(err)}`)
        setOpeningCard(false)
        return
      }
    }

    try {
      await activateGameCard(gameId, sessionId, nextCardSlug)
    } catch (err) {
      console.error('ACTIVE CARD UPDATE ERROR', err)
      setError(`No se pudo abrir la carta: ${getErrorMessage(err)}`)
      setOpeningCard(false)
      return
    }

    router.push(`/card/${nextCardSlug}`)
  }

  async function handleRemovePlayer(playerId: string) {
    const sessionId = getStoredSessionId()

    if (!sessionId || removingPlayerId) return

    setRemovingPlayerId(playerId)
    setError('')

    try {
      await removePlayerFromGame(sessionId, playerId)
      if (gameId) {
        await loadPlayers(gameId)
      }
    } catch (err) {
      console.error('REMOVE PLAYER ERROR', err)
      setError(`No se pudo quitar al jugador: ${getErrorMessage(err)}`)
    } finally {
      setRemovingPlayerId(null)
    }
  }

  useEffect(() => {
    async function loadLobby() {
      const requestId = ++lobbyLoadRequestIdRef.current
      const isCurrent = () =>
        mountedRef.current && requestId === lobbyLoadRequestIdRef.current

      if (!code) {
        setError('No hay código de partida')
        setLoading(false)
        return
      }

      const { data: game, error: gameError } = await supabase
        .from('public_games')
        .select('id, code, status, active_card_slug')
        .eq('code', code)
        .single()

      if (!isCurrent()) return

      if (gameError && !isMissingRowError(gameError)) {
        console.error('LOBBY GAME RECOVERY ERROR', gameError)
        setSessionRecoveryPending(true)
        setError('Recuperando tu partida…')
        setLoading(false)
        return
      }

      if (!game) {
        setError('No se encontró la partida')
        setLoading(false)
        return
      }

      setGameId(game.id)

      const sessionId = getStoredSessionId()
      if (sessionId) {
        let player

        try {
          player = await getPlayerBySession(sessionId, game.code)
        } catch (playerError) {
          if (!isCurrent()) return
          console.error('LOBBY PLAYER SESSION ERROR', playerError)
          setSessionRecoveryPending(true)
          setError('Recuperando tu partida…')
          setLoading(false)
          return
        }

        if (!isCurrent()) return

        if (!player) {
          const storedPlayerName = localStorage.getItem('player_name')

          if (storedPlayerName) {
            try {
              await joinGameByCode(game.code, sessionId, storedPlayerName)
              player = await getPlayerBySession(sessionId, game.code)
            } catch (reconnectError) {
              if (!isCurrent()) return
              console.error('LOBBY AUTO RECONNECT ERROR', reconnectError)
              setSessionRecoveryPending(true)
              setError('Recuperando tu partida…')
              setLoading(false)
              return
            }
          }
        }

        if (!isCurrent()) return

        setCurrentPlayerId(player?.player_id || null)
        setCurrentPlayerIsHost(!!player?.is_host)
      }

      setSessionRecoveryPending(false)
      setError('')

      if (game.active_card_slug) {
        redirectToActiveCard(game.active_card_slug, game.code)
        return
      }

      await loadPlayers(game.id)
      if (!isCurrent()) return
      setLoading(false)
    }

    loadLobby()
  }, [code, loadPlayers, recoveryKey, redirectToActiveCard])

  useEffect(() => {
    if (!gameId) return

    const pollIntervalId = window.setInterval(
      requestLobbyReconciliation,
      10000
    )

    const channel = supabase
      .channel(`lobby:${gameId}`)
      .on(
        'postgres_changes',
        {
          event: '*',
          schema: 'public',
          table: 'realtime_events',
          filter: `game_id=eq.${gameId}`,
        },
        (payload) => {
          const eventType = (payload.new as { event_type?: string }).event_type

          if (eventType === 'players_changed') {
            void loadPlayers(gameId)
          } else if (eventType === 'game_changed') {
            void loadActiveCard(gameId)
          }
        }
      )
      .subscribe((status) => {
        if (status === 'SUBSCRIBED') {
          requestLobbyReconciliation()
        } else if (
          status === 'CHANNEL_ERROR' ||
          status === 'TIMED_OUT' ||
          status === 'CLOSED'
        ) {
          console.warn(`LOBBY REALTIME ${status}`)
        }
      })

    return () => {
      window.clearInterval(pollIntervalId)
      supabase.removeChannel(channel)
    }
  }, [gameId, loadActiveCard, loadPlayers, requestLobbyReconciliation])

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
            <p className="text-sm text-neutral-500">Código de partida</p>
            <h1 className="mt-1 text-3xl font-bold tracking-tight">{code}</h1>
          </div>

          {loading ? (
            <p className="mt-6 text-neutral-600">Cargando lobby...</p>
          ) : error ? (
            <p className="mt-6 text-red-600">{error}</p>
          ) : cardScanMessage ? (
            <p className="mt-6 rounded-2xl bg-black px-4 py-3 text-center font-medium text-white">
              {cardScanMessage}
            </p>
          ) : (
            <>
              <h2 className="mt-6 text-lg font-semibold">Jugadores</h2>

              <ul className="mt-4 space-y-3">
                {players.map((player) => (
                  <li
                    key={player.id}
                    className="flex items-center justify-between rounded-2xl border border-neutral-200 px-4 py-3"
                  >
                    <span>{player.name}</span>
                    <span className="flex items-center gap-2 text-sm text-neutral-500">
                      {player.presence_status === 'online' ? 'Online' : null}
                      {player.presence_status === 'reconnecting' ? 'Reconectando' : null}
                      {player.presence_status === 'offline' ? 'Sin conexión' : null}
                      {player.is_host ? 'Host' : null}
                      {currentPlayerIsHost && player.id !== currentPlayerId ? (
                        <button
                          type="button"
                          onClick={() => handleRemovePlayer(player.id)}
                          disabled={removingPlayerId === player.id}
                          className="rounded-full border border-neutral-300 px-2 py-1 text-xs text-neutral-700 disabled:opacity-40"
                        >
                          Quitar
                        </button>
                      ) : null}
                    </span>
                  </li>
                ))}
              </ul>

              <div className="mt-6 rounded-3xl border border-neutral-200 p-4">
                <p className="text-sm font-medium text-neutral-900">
                  Escanea una carta o escribe su código
                </p>

                <div className="mt-4 flex items-center gap-2">
                  <div className="rounded-2xl bg-neutral-100 px-4 py-3 font-semibold text-neutral-600">
                    V-
                  </div>
                  <input
                    type="text"
                    inputMode="numeric"
                    value={cardCode}
                    onChange={(e) =>
                      setCardCode(e.target.value.replace(/\D/g, '').slice(0, 3))
                    }
                    placeholder="001"
                    className="min-w-0 flex-1 rounded-2xl border border-neutral-300 px-4 py-3 outline-none focus:border-neutral-500"
                  />
                </div>

                <button
                  onClick={handleGoToCardByCode}
                  disabled={!cardCode.trim() || openingCard}
                  className="mt-3 w-full rounded-2xl bg-black px-4 py-3 font-medium text-white transition hover:opacity-90 disabled:opacity-40"
                >
                  {openingCard ? 'Abriendo carta...' : 'Votar'}
                </button>
              </div>

              <p className="mt-6 text-sm text-neutral-500">
                Cuando alguien escanee una carta, entraréis automáticamente a votar.
              </p>
            </>
          )}
        </div>
      </div>
    </main>
  )
}

export default function LobbyPage() {
  return (
    <Suspense fallback={<p className="p-6">Cargando lobby...</p>}>
      <LobbyContent />
    </Suspense>
  )
}
