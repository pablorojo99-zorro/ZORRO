'use client'

import { Suspense, useCallback, useEffect, useState } from 'react'
import Image from 'next/image'
import { useRouter, useSearchParams } from 'next/navigation'
import { cardExists, createCardSlugFromCode } from '@/lib/cards'
import {
  activateGameCardV2,
  clearOperationId,
  getOrCreateOperationId,
  getPlayerBySessionV2,
  isStaleTransitionError,
  joinGameByCodeV2,
  removePlayerFromGameV2,
  retryUncertainV2Mutation,
  type PlayerSessionResultV2,
} from '@/lib/game-flow-v2'
import { getErrorMessage, getStoredSessionId } from '@/lib/session'
import { supabase } from '@/lib/supabase'
import { usePlayerHeartbeatV2 } from '@/lib/use-player-heartbeat-v2'
import { useV2CanonicalState } from '@/lib/use-v2-canonical-state'

type Player = {
  id: string
  name: string
  is_host: boolean
  presence_status?: 'online' | 'reconnecting' | 'offline'
}

function LobbyContent() {
  const router = useRouter()
  const code = useSearchParams().get('code')?.toUpperCase() || ''
  const [sessionId, setSessionId] = useState<string | null>(null)
  const [player, setPlayer] = useState<PlayerSessionResultV2 | null>(null)
  const [players, setPlayers] = useState<Player[]>([])
  const [cardCode, setCardCode] = useState('')
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState('')
  const { state, error: canonicalError, reconcile } = useV2CanonicalState(player?.game_id || null, sessionId)
  usePlayerHeartbeatV2(player?.game_id || null)

  const loadPlayers = useCallback(async (gameId: string) => {
    const { data, error } = await supabase.from('public_players').select('id, name, is_host, presence_status').eq('game_id', gameId).order('created_at', { ascending: true })
    if (error) throw error
    setPlayers((data || []) as Player[])
  }, [])

  useEffect(() => {
    let cancelled = false
    async function recoverSession() {
      const storedSessionId = getStoredSessionId()
      const storedName = localStorage.getItem('player_name')
      if (!storedSessionId || !code) {
        setMessage('No se pudo recuperar la sesión de la partida.')
        setLoading(false)
        return
      }
      try {
        let recovered = await getPlayerBySessionV2(storedSessionId, code)
        if (!recovered && storedName) {
          await joinGameByCodeV2(code, storedSessionId, storedName)
          recovered = await getPlayerBySessionV2(storedSessionId, code)
        }
        if (cancelled) return
        if (!recovered) throw new Error('player_not_in_game')
        setSessionId(storedSessionId)
        setPlayer(recovered)
        await loadPlayers(recovered.game_id)
      } catch (error) {
        if (!cancelled) setMessage(`No se pudo recuperar la partida: ${getErrorMessage(error)}`)
      } finally {
        if (!cancelled) setLoading(false)
      }
    }
    void recoverSession()
    return () => { cancelled = true }
  }, [code, loadPlayers])

  useEffect(() => {
    if (!player?.game_id) return
    const channel = supabase.channel(`lobby:${player.game_id}`).on('postgres_changes', { event: '*', schema: 'public', table: 'realtime_events', filter: `game_id=eq.${player.game_id}` }, () => void loadPlayers(player.game_id)).subscribe()
    return () => { void supabase.removeChannel(channel) }
  }, [loadPlayers, player?.game_id])

  useEffect(() => {
    if (!state?.active_card_slug || !state.current_vote_round_id) return
    router.replace(`/card/${state.active_card_slug}?code=${encodeURIComponent(code)}`)
  }, [code, router, state?.active_card_slug, state?.current_vote_round_id])

  async function handleActivateCard() {
    const slug = createCardSlugFromCode(cardCode)
    if (!slug || !player || !sessionId || !state || busy) return
    setBusy(true)
    setMessage('')
    try {
      if (!(await cardExists(slug))) throw new Error('card_not_found')
      const expectedVersion = state.transition_version
      const action = `activate:${slug}`
      const operationId = getOrCreateOperationId(player.game_id, action, { slug, expectedVersion })
      await retryUncertainV2Mutation(() => activateGameCardV2(player.game_id, sessionId, slug, operationId, expectedVersion))
      clearOperationId(player.game_id, action)
      await reconcile()
    } catch (error) {
      await reconcile()
      setMessage(isStaleTransitionError(error) ? 'La partida cambió. Se ha cargado el estado actual.' : `No se pudo abrir la carta: ${getErrorMessage(error)}`)
    } finally {
      setBusy(false)
    }
  }

  async function handleRemovePlayer(playerId: string) {
    if (!sessionId || !player || busy) return
    setBusy(true)
    setMessage('')
    try {
      await removePlayerFromGameV2(sessionId, playerId)
      await loadPlayers(player.game_id)
    } catch (error) {
      setMessage(`No se pudo quitar al jugador: ${getErrorMessage(error)}`)
    } finally {
      setBusy(false)
    }
  }

  const effectiveMessage = canonicalError ? `No se pudo reconciliar la partida: ${getErrorMessage(canonicalError)}` : message
  return (
    <main className="min-h-screen bg-neutral-100 text-neutral-900"><div className="mx-auto max-w-md px-6 py-10"><div className="relative rounded-3xl bg-white p-6 shadow-sm ring-1 ring-black/5">
      <Image src="/zorro-brand-black.svg" alt="" aria-hidden width={60} height={60} className="absolute right-5 top-4 h-[60px] w-[60px] opacity-75" />
      <div className="pr-12"><p className="text-sm text-neutral-500">Código de partida</p><h1 className="mt-1 text-3xl font-bold tracking-tight">{code}</h1></div>
      {loading ? <p className="mt-6 text-neutral-600">Cargando lobby...</p> : null}
      {!loading && player ? <>
        <h2 className="mt-6 text-lg font-semibold">Jugadores</h2>
        <ul className="mt-4 space-y-3">{players.map((item) => <li key={item.id} className="flex items-center justify-between rounded-2xl border border-neutral-200 px-4 py-3"><span>{item.name}</span><span className="flex items-center gap-2 text-sm text-neutral-500">{item.presence_status === 'online' ? 'Online' : null}{item.presence_status === 'reconnecting' ? 'Reconectando' : null}{item.presence_status === 'offline' ? 'Sin conexión' : null}{item.is_host ? 'Host' : null}{player.is_host && item.id !== player.player_id ? <button type="button" disabled={busy} onClick={() => void handleRemovePlayer(item.id)} className="rounded-full border border-neutral-300 px-2 py-1 text-xs disabled:opacity-40">Quitar</button> : null}</span></li>)}</ul>
        <div className="mt-6 rounded-3xl border border-neutral-200 p-4"><p className="text-sm font-medium">Escanea una carta o escribe su código</p><div className="mt-4 flex items-center gap-2"><div className="rounded-2xl bg-neutral-100 px-4 py-3 font-semibold text-neutral-600">V-</div><input value={cardCode} onChange={(event) => setCardCode(event.target.value.replace(/\D/g, '').slice(0, 3))} inputMode="numeric" placeholder="001" className="min-w-0 flex-1 rounded-2xl border border-neutral-300 px-4 py-3 outline-none focus:border-neutral-500" /></div><button onClick={() => void handleActivateCard()} disabled={!cardCode || busy || !state} className="mt-3 w-full rounded-2xl bg-black px-4 py-3 font-medium text-white disabled:opacity-40">{busy ? 'Abriendo carta...' : 'Votar'}</button></div>
      </> : null}
      {effectiveMessage ? <p className="mt-4 text-sm font-medium text-red-600">{effectiveMessage}</p> : null}
    </div></div></main>
  )
}

export default function LobbyPage() {
  return <Suspense fallback={<p className="p-6">Cargando lobby...</p>}><LobbyContent /></Suspense>
}
