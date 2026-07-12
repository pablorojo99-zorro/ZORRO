'use client'

import { Suspense, useCallback, useEffect, useRef, useState } from 'react'
import { supabase } from '@/lib/supabase'
import {
  getActiveCardRoundId,
  getActiveCardSlug,
  getCardScanMessage,
} from '@/lib/active-card'
import { cardExists, createCardSlugFromCode } from '@/lib/cards'
import { activateGameCard } from '@/lib/game-flow'
import Image from 'next/image'
import { useRouter, useSearchParams } from 'next/navigation'

type Player = {
  id: string
  name: string
  is_host: boolean
}

function LobbyContent() {
  const searchParams = useSearchParams()
  const router = useRouter()
  const code = searchParams.get('code')

  const [players, setPlayers] = useState<Player[]>([])
  const [gameId, setGameId] = useState<string | null>(null)
  const [cardCode, setCardCode] = useState('')
  const [cardScanMessage, setCardScanMessage] = useState('')
  const [openingCard, setOpeningCard] = useState(false)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const redirectingToCardRef = useRef(false)

  const redirectToActiveCard = useCallback((activeCardValue: string) => {
    const activeCardSlug = getActiveCardSlug(activeCardValue)
    const activeCardRoundId = getActiveCardRoundId(activeCardValue)

    if (!activeCardSlug || redirectingToCardRef.current) return

    redirectingToCardRef.current = true

    if (activeCardRoundId) {
      const nextParams = new URLSearchParams({
        auto: '1',
        round: activeCardRoundId,
      })

      router.replace(`/card/${activeCardSlug}?${nextParams.toString()}`)
      return
    }

    setCardScanMessage(getCardScanMessage(activeCardValue))

    setTimeout(() => {
      router.replace(`/card/${activeCardSlug}?auto=1`)
    }, 1200)
  }, [router])

  const loadPlayers = useCallback(async (currentGameId: string) => {
    const { data: playerList, error: playersError } = await supabase
      .from('players')
      .select('id, name, is_host')
      .eq('game_id', currentGameId)
      .eq('active', true)
      .order('created_at', { ascending: true })

    if (playersError) {
      console.error('ERROR cargando jugadores', playersError)
      setError('No se pudieron cargar los jugadores')
      return
    }

    setPlayers(playerList || [])
  }, [])

  const loadActiveCard = useCallback(async (currentGameId: string) => {
    const { data: game, error: gameError } = await supabase
      .from('games')
      .select('active_card_slug')
      .eq('id', currentGameId)
      .single()

    if (gameError) {
      console.error('ERROR cargando carta activa', gameError)
      return
    }

    if (game?.active_card_slug) {
      redirectToActiveCard(game.active_card_slug)
    }
  }, [redirectToActiveCard])

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

    try {
      await activateGameCard(gameId, sessionId, nextCardSlug)
    } catch (err) {
      console.error('ACTIVE CARD UPDATE ERROR', err)
      setError('No se pudo abrir la carta.')
      setOpeningCard(false)
      return
    }

    router.push(`/card/${nextCardSlug}`)
  }

  useEffect(() => {
    async function loadLobby() {
      if (!code) {
        setError('No hay código de partida')
        setLoading(false)
        return
      }

      const { data: game, error: gameError } = await supabase
        .from('games')
        .select('id, code, status, active_card_slug')
        .eq('code', code)
        .single()

      if (gameError || !game) {
        setError('No se encontró la partida')
        setLoading(false)
        return
      }

      if (game.active_card_slug) {
        redirectToActiveCard(game.active_card_slug)
        return
      }

      setGameId(game.id)
      await loadPlayers(game.id)
      setLoading(false)
    }

    loadLobby()
  }, [code, loadPlayers, redirectToActiveCard])

  useEffect(() => {
    if (!gameId) return

    const channel = supabase
      .channel(`lobby:${gameId}`)
      .on(
        'postgres_changes',
        {
          event: '*',
          schema: 'public',
          table: 'players',
          filter: `game_id=eq.${gameId}`,
        },
        () => {
          loadPlayers(gameId)
        }
      )
      .on(
        'postgres_changes',
        {
          event: 'UPDATE',
          schema: 'public',
          table: 'games',
          filter: `id=eq.${gameId}`,
        },
        (payload) => {
          const activeCardSlug = payload.new.active_card_slug

          if (typeof activeCardSlug === 'string' && activeCardSlug) {
            redirectToActiveCard(activeCardSlug)
          }
        }
      )
      .subscribe()

    return () => {
      supabase.removeChannel(channel)
    }
  }, [gameId, loadActiveCard, loadPlayers, redirectToActiveCard])

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
                    {player.is_host ? (
                      <span className="text-sm text-neutral-500">Host</span>
                    ) : null}
                  </li>
                ))}
              </ul>

              <div className="mt-6 rounded-3xl border border-neutral-200 p-4">
                <p className="text-sm font-medium text-neutral-900">
                  Escanea una carta o escribe su código
                </p>

                <div className="mt-4 flex items-center gap-2">
                  <div className="rounded-2xl bg-neutral-100 px-4 py-3 font-semibold text-neutral-600">
                    Z-
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
