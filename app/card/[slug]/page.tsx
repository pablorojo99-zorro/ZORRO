'use client'

import { Suspense, useCallback, useEffect, useRef, useState } from 'react'
import Image from 'next/image'
import { useParams, useRouter, useSearchParams } from 'next/navigation'
import {
  activateGameCardV2,
  clearOperationId,
  closeVoteRoundV2,
  getOrCreateOperationId,
  getPlayerBySessionV2,
  isStaleTransitionError,
  isUncertainMutationError,
  joinGameByCodeV2,
  retryUncertainV2Mutation,
  submitVoteV2,
  type PlayerSessionResultV2,
} from '@/lib/game-flow-v2'
import { getVisibleCardCode } from '@/lib/cards'
import { getErrorMessage, getStoredSessionId, storeGameSession } from '@/lib/session'
import { supabase } from '@/lib/supabase'
import { usePlayerHeartbeatV2 } from '@/lib/use-player-heartbeat-v2'
import { useV2CanonicalState } from '@/lib/use-v2-canonical-state'

type Card = { id: string; slug: string; question_text: string }
type Player = { id: string; name: string }

function CardContent() {
  const router = useRouter()
  const slug = useParams<{ slug: string }>().slug
  const codeFromQuery = useSearchParams().get('code')?.toUpperCase() || ''
  const [sessionId, setSessionId] = useState<string | null>(null)
  const [player, setPlayer] = useState<PlayerSessionResultV2 | null>(null)
  const [gameCode, setGameCode] = useState('')
  const [card, setCard] = useState<Card | null>(null)
  const [players, setPlayers] = useState<Player[]>([])
  const [alreadyVoted, setAlreadyVoted] = useState(false)
  const [busy, setBusy] = useState(false)
  const [loading, setLoading] = useState(true)
  const [message, setMessage] = useState('')
  const closeAttemptRef = useRef<string | null>(null)
  const activationAttemptRef = useRef<string | null>(null)
  const staleActivationRef = useRef<string | null>(null)
  const { state, error: canonicalError, reconcile } = useV2CanonicalState(player?.game_id || null, sessionId)
  usePlayerHeartbeatV2(player?.game_id || null)

  const loadPlayers = useCallback(async (gameId: string) => {
    const { data: playerRows, error } = await supabase
      .from('public_players')
      .select('id, name')
      .eq('game_id', gameId)
      .order('created_at', { ascending: true })
    if (error) throw error
    setPlayers((playerRows || []) as Player[])
  }, [])

  useEffect(() => {
    let cancelled = false
    async function recover() {
      const storedSessionId = getStoredSessionId()
      const storedName = localStorage.getItem('player_name')
      const storedCode = localStorage.getItem('game_code')?.toUpperCase() || ''
      const targetCode = codeFromQuery || storedCode
      if (!storedSessionId || !targetCode) {
        setMessage('Vuelve al inicio y entra en una partida antes de escanear una carta.')
        setLoading(false)
        return
      }
      try {
        let recovered = await getPlayerBySessionV2(storedSessionId, targetCode)
        if (!recovered && storedName && storedCode === targetCode) {
          await joinGameByCodeV2(targetCode, storedSessionId, storedName)
          recovered = await getPlayerBySessionV2(storedSessionId, targetCode)
        }
        if (cancelled) return
        if (!recovered) throw new Error('player_not_in_game')
        const { data: cardData, error: cardError } = await supabase.from('cards').select('id, slug, question_text').eq('slug', slug).eq('active', true).single()
        if (cardError) throw cardError
        if (cancelled) return
        setSessionId(storedSessionId)
        setPlayer(recovered)
        setGameCode(recovered.code)
        setCard(cardData as Card)
        storeGameSession(storedSessionId, recovered.code, recovered.name)
      } catch (error) {
        if (!cancelled) {
          const reason = getErrorMessage(error)
          setMessage(reason.includes('player_not_in_game')
            ? 'Esta sesión no pertenece a la partida indicada. Vuelve al inicio para entrar correctamente.'
            : `No se pudo cargar la carta: ${reason}`)
        }
      } finally {
        if (!cancelled) setLoading(false)
      }
    }
    void recover()
    return () => { cancelled = true }
  }, [codeFromQuery, slug])

  useEffect(() => {
    if (!state || !player || !sessionId || !card || !gameCode) return

    const canonicalSlug = state.active_card_slug
    const canonicalRoundId = state.current_vote_round_id

    if (state.status === 'closed') {
      router.replace(`/result/${canonicalSlug || slug}?code=${encodeURIComponent(gameCode)}`)
      return
    }

    if (state.status === 'voting') {
      if (canonicalSlug !== slug) {
        if (canonicalSlug) router.replace(`/card/${canonicalSlug}?code=${encodeURIComponent(gameCode)}`)
        else router.replace(`/lobby?code=${encodeURIComponent(gameCode)}`)
        return
      }

      if (canonicalRoundId) {
        const refreshId = window.setTimeout(() => {
          setMessage('')
          setAlreadyVoted(localStorage.getItem(`v2_voted:${player.game_id}:${canonicalRoundId}`) === 'true')
          void loadPlayers(player.game_id).catch((error) => setMessage(getErrorMessage(error)))
        }, 0)
        return () => window.clearTimeout(refreshId)
      }
      return
    }

    const mayActivateFirstCard = !canonicalRoundId && !canonicalSlug && state.status === null
    const mayActivateNextCard = state.status === 'ready_next' && canonicalSlug !== slug

    if (!mayActivateFirstCard && !mayActivateNextCard) {
      if (state.status === 'ready_next') {
        router.replace(`/result/${canonicalSlug || slug}?code=${encodeURIComponent(gameCode)}`)
      }
      return
    }

    const expectedVersion = state.transition_version
    const attemptSignature = `${player.game_id}:${slug}:${expectedVersion}`
    const activationTarget = `${player.game_id}:${slug}`
    if (staleActivationRef.current === activationTarget) return
    if (activationAttemptRef.current === attemptSignature) return
    activationAttemptRef.current = attemptSignature

    const action = `activate:${slug}`
    const payload = { slug, expectedVersion }
    const operationId = getOrCreateOperationId(player.game_id, action, payload)
    setMessage('Activando carta…')

    void retryUncertainV2Mutation(() =>
      activateGameCardV2(player.game_id, sessionId, slug, operationId, expectedVersion)
    ).then(async () => {
      clearOperationId(player.game_id, action)
      await reconcile()
    }).catch(async (error) => {
      await reconcile()
      if (isStaleTransitionError(error)) {
        staleActivationRef.current = activationTarget
        clearOperationId(player.game_id, action)
        setMessage('Otra carta o transición se confirmó antes. Cargando el estado actual…')
        return
      }
      if (isUncertainMutationError(error)) {
        setMessage('No se pudo confirmar la activación. Conservamos la operación para recuperarla al recargar.')
        return
      }
      clearOperationId(player.game_id, action)
      setMessage(`No se pudo activar la carta: ${getErrorMessage(error)}`)
    })
  }, [card, gameCode, loadPlayers, player, reconcile, router, sessionId, slug, state])

  async function attemptClose() {
    if (!state?.current_vote_round_id || !sessionId || !player || state.status !== 'voting') return
    const signature = `${state.current_vote_round_id}:${state.transition_version}`
    if (closeAttemptRef.current === signature) return
    closeAttemptRef.current = signature
    const action = `close:${state.current_vote_round_id}`
    const payload = { roundId: state.current_vote_round_id, expectedVersion: state.transition_version }
    const operationId = getOrCreateOperationId(player.game_id, action, payload)
    try {
      await retryUncertainV2Mutation(() => closeVoteRoundV2(state.current_vote_round_id!, sessionId, operationId, state.transition_version))
      clearOperationId(player.game_id, action)
    } catch (error) {
      const text = getErrorMessage(error).toLowerCase()
      if (!text.includes('vote_round_not_complete') && !isStaleTransitionError(error)) {
        setMessage(`No se pudo cerrar la votación: ${getErrorMessage(error)}`)
      }
      if (!text.includes('fetch') && !text.includes('network') && !text.includes('timeout')) {
        clearOperationId(player.game_id, action)
      }
    } finally {
      await reconcile()
    }
  }

  async function handleVote(targetPlayerId: string) {
    if (!state?.current_vote_round_id || !sessionId || !player || busy || alreadyVoted) return
    setBusy(true)
    setMessage('')
    const action = `vote:${state.current_vote_round_id}`
    const payload = { roundId: state.current_vote_round_id, targetPlayerId, expectedVersion: state.transition_version }
    const operationId = getOrCreateOperationId(player.game_id, action, payload)
    try {
      await retryUncertainV2Mutation(() => submitVoteV2(state.current_vote_round_id!, sessionId, targetPlayerId, operationId, state.transition_version))
      clearOperationId(player.game_id, action)
      localStorage.setItem(`v2_voted:${player.game_id}:${state.current_vote_round_id}`, 'true')
      setAlreadyVoted(true)
      setMessage('¡Voto guardado!')
      await loadPlayers(player.game_id)
      await attemptClose()
      await reconcile()
    } catch (error) {
      const errorCode = typeof error === 'object' && error && 'code' in error
        ? String(error.code)
        : ''
      if (errorCode === '23505') {
        clearOperationId(player.game_id, action)
        localStorage.setItem(`v2_voted:${player.game_id}:${state.current_vote_round_id}`, 'true')
        setAlreadyVoted(true)
        setMessage('Tu voto ya estaba guardado. Esperando al resto…')
        await attemptClose()
        await reconcile()
        return
      }
      await reconcile()
      if (!isUncertainMutationError(error)) clearOperationId(player.game_id, action)
      setMessage(isStaleTransitionError(error) ? 'La votación cambió. Se ha cargado el estado actual.' : `No se pudo guardar el voto: ${getErrorMessage(error)}`)
    } finally {
      setBusy(false)
    }
  }

  const candidates = players.filter((candidate) => candidate.id !== player?.player_id && (!state?.tie_player_ids?.length || state.tie_player_ids.includes(candidate.id)))
  const effectiveMessage = canonicalError ? `Recuperando estado: ${getErrorMessage(canonicalError)}` : message
  return (
    <main className="min-h-screen bg-neutral-100 text-neutral-900"><div className="mx-auto max-w-md px-6 py-10"><div className="relative rounded-3xl bg-white p-6 shadow-sm ring-1 ring-black/5">
      <Image src="/zorro-brand-black.svg" alt="" aria-hidden width={60} height={60} className="absolute right-5 top-4 h-[60px] w-[60px] opacity-75" />
      <p className="text-sm font-medium text-neutral-500">{getVisibleCardCode(slug) || slug}</p>
      <h1 className="mt-2 pr-12 text-2xl font-bold">{card?.question_text || 'Votación'}</h1>
      {state?.source_round_id ? <p className="mt-3 rounded-2xl bg-amber-100 px-4 py-3 text-sm font-medium">Ronda de desempate</p> : null}
      {loading ? <p className="mt-6">Cargando votación…</p> : null}
      {!loading && state?.status === 'voting' ? <><div className="mt-6 space-y-3">{candidates.map((candidate) => <button key={candidate.id} disabled={busy || alreadyVoted} onClick={() => void handleVote(candidate.id)} className="w-full rounded-2xl border border-neutral-300 px-4 py-3 text-left font-medium transition hover:bg-neutral-50 disabled:opacity-40">{candidate.name}</button>)}</div>{alreadyVoted ? <p className="mt-5 rounded-2xl bg-green-50 px-4 py-3 text-sm font-medium text-green-800">Tu voto está guardado. Esperando al resto…</p> : null}</> : null}
      {effectiveMessage ? <p className="mt-4 text-sm font-medium text-red-600">{effectiveMessage}</p> : null}
    </div></div></main>
  )
}

export default function CardPage() {
  return <Suspense fallback={<p className="p-6">Cargando carta...</p>}><CardContent /></Suspense>
}
