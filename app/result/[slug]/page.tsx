'use client'

import type { PointerEvent } from 'react'
import { Suspense, useEffect, useRef, useState } from 'react'
import Image from 'next/image'
import { useParams, useRouter, useSearchParams } from 'next/navigation'
import { cardExists, createCardSlugFromCode } from '@/lib/cards'
import {
  activateGameCardV2,
  clearOperationId,
  getOrCreateOperationId,
  getPlayerBySessionV2,
  isStaleTransitionError,
  joinGameByCodeV2,
  markRoundReadyNextV2,
  resolveRandomTiebreakV2,
  retryUncertainV2Mutation,
  startTiebreakRoundV2,
  type PlayerSessionResultV2,
} from '@/lib/game-flow-v2'
import { getErrorMessage, getStoredSessionId } from '@/lib/session'
import { supabase } from '@/lib/supabase'
import { usePlayerHeartbeatV2 } from '@/lib/use-player-heartbeat-v2'
import { useV2CanonicalState } from '@/lib/use-v2-canonical-state'

type Player = { id: string; name: string }

const RESULT_INTRO_TEXT = 'El jugador más votado es...'

function getCardTypeFromRound(roundId: string) {
  let total = 0

  for (const char of roundId) total += char.charCodeAt(0)

  return total % 2 === 0 ? 'RETO' : 'CONFESIÓN'
}

function vibrateSlotResult() {
  if (typeof navigator !== 'undefined' && 'vibrate' in navigator) {
    navigator.vibrate([120, 50, 120, 50, 200])
  }
}

function ContinueSlider({ onComplete }: { onComplete: () => void }) {
  const trackRef = useRef<HTMLDivElement | null>(null)
  const [progress, setProgress] = useState(0)
  const [dragging, setDragging] = useState(false)
  const [locked, setLocked] = useState(false)
  const [successPulse, setSuccessPulse] = useState(false)
  const [maxTravel, setMaxTravel] = useState(0)

  function updateProgress(clientX: number) {
    const track = trackRef.current
    if (!track || locked) return
    const rect = track.getBoundingClientRect()
    const thumbSize = 48
    const travel = Math.max(rect.width - thumbSize - 8, 1)
    setMaxTravel(travel)
    setProgress(Math.min(Math.max((clientX - rect.left - 4 - thumbSize / 2) / travel, 0), 1))
  }

  function handlePointerDown(event: PointerEvent<HTMLDivElement>) {
    if (locked) return
    event.currentTarget.setPointerCapture(event.pointerId)
    setDragging(true)
    updateProgress(event.clientX)
  }

  function handlePointerMove(event: PointerEvent<HTMLDivElement>) {
    if (dragging) updateProgress(event.clientX)
  }

  function handlePointerEnd(event: PointerEvent<HTMLDivElement>) {
    if (!dragging || locked) return
    event.currentTarget.releasePointerCapture(event.pointerId)
    setDragging(false)
    if (progress >= 0.88) {
      setProgress(1)
      setLocked(true)
      setSuccessPulse(true)
      window.setTimeout(() => setSuccessPulse(false), 140)
      window.setTimeout(onComplete, 260)
      return
    }
    setProgress(0)
  }

  return (
    <div ref={trackRef} role="button" tabIndex={0} aria-label="Desliza para continuar"
      onPointerDown={handlePointerDown} onPointerMove={handlePointerMove}
      onPointerUp={handlePointerEnd} onPointerCancel={handlePointerEnd}
      className="relative h-14 touch-none select-none overflow-hidden rounded-full bg-neutral-100">
      <p className="pointer-events-none absolute inset-0 flex items-center justify-center text-sm font-medium text-neutral-500 transition-opacity duration-150"
        style={{ opacity: Math.max(0.28, 1 - progress * 0.72) }}>Desliza para continuar</p>
      <div className={`absolute left-1 top-1 flex h-12 w-12 items-center justify-center rounded-full bg-black shadow-sm ${dragging ? '' : 'transition-transform duration-300 ease-out'}`}
        style={{ transform: `translateX(${progress * maxTravel}px) scale(${successPulse ? 1.08 : 1})`, transitionTimingFunction: successPulse ? 'cubic-bezier(0.34, 1.56, 0.64, 1)' : undefined }}>
        <Image src="/zorro-brand-white.svg" alt="" aria-hidden width={33} height={33} className="h-[33px] w-[33px]" />
      </div>
    </div>
  )
}

function ResultContent() {
  const router = useRouter()
  const slug = useParams<{ slug: string }>().slug
  const code = useSearchParams().get('code') || ''
  const [sessionId, setSessionId] = useState<string | null>(null)
  const [player, setPlayer] = useState<PlayerSessionResultV2 | null>(null)
  const [namedPlayers, setNamedPlayers] = useState<Record<string, string>>({})
  const [nextCardCode, setNextCardCode] = useState('')
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState('')
  const [displayedCardType, setDisplayedCardType] = useState('')
  const [isSlotRunning, setIsSlotRunning] = useState(false)
  const [slotFinished, setSlotFinished] = useState(false)
  const [showContinueSlider, setShowContinueSlider] = useState(false)
  const [showWinnerIntro, setShowWinnerIntro] = useState(false)
  const [showWinnerName, setShowWinnerName] = useState(false)
  const [showCardType, setShowCardType] = useState(false)
  const displayedResultKeyRef = useRef<string | null>(null)
  const slotTimersRef = useRef<number[]>([])
  const { state, error: canonicalError, reconcile } = useV2CanonicalState(player?.game_id || null, sessionId)
  usePlayerHeartbeatV2(player?.game_id || null)

  useEffect(() => {
    if (document.getElementById('result-animation-style')) return
    const style = document.createElement('style')
    style.id = 'result-animation-style'
    style.innerHTML = `
      @keyframes pop { 0% { transform: scale(0.86); opacity: 0; } 65% { transform: scale(1.035); opacity: 1; } 100% { transform: scale(1); opacity: 1; } }
      @keyframes fadeUp { 0% { transform: translateY(12px); opacity: 0; } 100% { transform: translateY(0); opacity: 1; } }
      @keyframes resultEnter { 0% { transform: translateY(10px) scale(0.985); opacity: 0; } 100% { transform: translateY(0) scale(1); opacity: 1; } }
      @keyframes slotPop { 0% { transform: scale(1); } 50% { transform: scale(1.045); } 100% { transform: scale(1); } }
    `
    document.head.appendChild(style)
  }, [])

  useEffect(() => {
    let cancelled = false
    async function recover() {
      const storedSessionId = getStoredSessionId()
      const storedName = localStorage.getItem('player_name')
      const targetCode = code || localStorage.getItem('game_code') || ''
      if (!storedSessionId || !targetCode) {
        setMessage('Vuelve a entrar en la partida.')
        setLoading(false)
        return
      }
      try {
        let recovered = await getPlayerBySessionV2(storedSessionId, targetCode)
        if (!recovered && storedName) {
          await joinGameByCodeV2(targetCode, storedSessionId, storedName)
          recovered = await getPlayerBySessionV2(storedSessionId, targetCode)
        }
        if (cancelled) return
        if (!recovered) throw new Error('player_not_in_game')
        const { data, error } = await supabase.from('public_players').select('id, name').eq('game_id', recovered.game_id)
        if (error) throw error
        if (cancelled) return
        setNamedPlayers(Object.fromEntries(((data || []) as Player[]).map((item) => [item.id, item.name])))
        setSessionId(storedSessionId)
        setPlayer(recovered)
      } catch (error) {
        if (!cancelled) setMessage(`No se pudo recuperar el resultado: ${getErrorMessage(error)}`)
      } finally {
        if (!cancelled) setLoading(false)
      }
    }
    void recover()
    return () => { cancelled = true }
  }, [code])

  useEffect(() => {
    if (!state) return
    if (state.active_card_slug && state.active_card_slug !== slug) {
      router.replace(`/card/${state.active_card_slug}?code=${encodeURIComponent(code || localStorage.getItem('game_code') || '')}`)
      return
    }
    if (state.status === 'voting') {
      router.replace(`/card/${slug}?code=${encodeURIComponent(code || localStorage.getItem('game_code') || '')}`)
    }
  }, [code, router, slug, state])

  const winnerId = state?.status === 'closed' ? state.winning_player_id : null
  const resultRoundId = state?.current_vote_round_id || null
  const cardType = resultRoundId ? getCardTypeFromRound(resultRoundId) : ''
  const resultKey = winnerId && resultRoundId ? `winner:${resultRoundId}:${winnerId}:${cardType}` : null

  useEffect(() => {
    if (!resultKey || displayedResultKeyRef.current === resultKey) return
    displayedResultKeyRef.current = resultKey
    slotTimersRef.current.forEach((timer) => clearTimeout(timer))
    slotTimersRef.current = []
    setDisplayedCardType('')
    setIsSlotRunning(false)
    setSlotFinished(false)
    setShowContinueSlider(false)
    setShowWinnerIntro(false)
    setShowWinnerName(false)
    setShowCardType(false)

    const introTimer = window.setTimeout(() => setShowWinnerIntro(true), 520)
    const winnerTimer = window.setTimeout(() => setShowWinnerName(true), 2150)
    const cardTypeTimer = window.setTimeout(() => setShowCardType(true), 3850)
    slotTimersRef.current.push(introTimer, winnerTimer, cardTypeTimer)

    return () => {
      slotTimersRef.current.forEach((timer) => clearTimeout(timer))
      slotTimersRef.current = []
    }
  }, [resultKey])

  useEffect(() => {
    if (!showCardType || !cardType || !resultKey) return
    const delays = [110, 140, 180, 240, 320, 440, 620]
    const startTimer = window.setTimeout(() => {
      let elapsed = 0
      setDisplayedCardType(cardType === 'RETO' ? 'CONFESIÓN' : 'RETO')
      setIsSlotRunning(true)
      setSlotFinished(false)

      delays.forEach((delay, index) => {
        elapsed += delay
        const timer = window.setTimeout(() => {
          if (index === delays.length - 1) {
            setDisplayedCardType(cardType)
            setIsSlotRunning(false)
            setSlotFinished(true)
            vibrateSlotResult()
            slotTimersRef.current.push(window.setTimeout(() => setShowContinueSlider(true), 650))
            return
          }
          setDisplayedCardType(index % 2 === 0 ? 'RETO' : 'CONFESIÓN')
        }, elapsed)
        slotTimersRef.current.push(timer)
      })
    }, 0)
    slotTimersRef.current.push(startTimer)
  }, [cardType, resultKey, showCardType])

  function finishSlotAnimation() {
    if (!isSlotRunning || !cardType) return
    slotTimersRef.current.forEach((timer) => clearTimeout(timer))
    slotTimersRef.current = []
    setDisplayedCardType(cardType)
    setIsSlotRunning(false)
    setSlotFinished(true)
    setShowContinueSlider(true)
    vibrateSlotResult()
  }

  async function runTransition(
    action: string,
    call: (operationId: string, expectedVersion: number) => Promise<unknown>
  ) {
    if (!player || !state || busy) return false
    setBusy(true)
    setMessage('')
    const expectedVersion = state.transition_version
    const operationId = getOrCreateOperationId(player.game_id, action, { action, roundId: state.current_vote_round_id, expectedVersion })
    try {
      await retryUncertainV2Mutation(() => call(operationId, expectedVersion))
      clearOperationId(player.game_id, action)
      await reconcile()
      return true
    } catch (error) {
      await reconcile()
      setMessage(isStaleTransitionError(error) ? 'La partida cambió. Se ha cargado el estado actual.' : `No se pudo completar la acción: ${getErrorMessage(error)}`)
      return false
    } finally {
      setBusy(false)
    }
  }

  async function handleStartTiebreak() {
    if (!state?.current_vote_round_id || !sessionId) return
    await runTransition(`tiebreak:${state.current_vote_round_id}`, (operationId, expectedVersion) => startTiebreakRoundV2(state.current_vote_round_id!, sessionId, operationId, expectedVersion))
  }

  async function handleRandomTiebreak() {
    if (!state?.current_vote_round_id || !sessionId) return
    await runTransition(`random:${state.current_vote_round_id}`, (operationId, expectedVersion) => resolveRandomTiebreakV2(state.current_vote_round_id!, sessionId, operationId, expectedVersion))
  }

  async function handleReadyNext() {
    if (!state?.current_vote_round_id || !sessionId) return
    await runTransition(`ready:${state.current_vote_round_id}`, (operationId, expectedVersion) => markRoundReadyNextV2(state.current_vote_round_id!, sessionId, operationId, expectedVersion))
  }

  async function handleNextCard() {
    const nextSlug = createCardSlugFromCode(nextCardCode)
    if (!nextSlug || !player || !state || !sessionId || busy) return
    if (!(await cardExists(nextSlug))) {
      setMessage('No existe esa carta.')
      return
    }
    const succeeded = await runTransition(`activate:${nextSlug}`, (operationId, expectedVersion) => activateGameCardV2(player.game_id, sessionId, nextSlug, operationId, expectedVersion))
    if (succeeded) router.replace(`/card/${nextSlug}?code=${encodeURIComponent(code || player.code)}`)
  }

  const tiedIds = state?.tie_player_ids && state.tie_player_ids.length > 1 ? state.tie_player_ids : []
  const winnerName = winnerId ? namedPlayers[winnerId] || 'Jugador' : ''
  const effectiveMessage = canonicalError ? `Recuperando estado: ${getErrorMessage(canonicalError)}` : message

  return (
    <main className="min-h-screen bg-neutral-100 text-neutral-900"><div className="mx-auto flex min-h-screen max-w-md flex-col justify-center px-6 py-10"><div className="relative rounded-3xl bg-white px-6 pb-6 pt-20 text-center shadow-sm ring-1 ring-black/5">
      <Image src="/zorro-brand-black.svg" alt="" aria-hidden width={60} height={60} className="absolute right-5 top-4 h-[60px] w-[60px] opacity-75" />
      {loading || !state ? <p className="mt-2">Recuperando resultado…</p> : null}
      {state?.status === 'closed' && winnerName ? <>
        <div className="mt-2 flex min-h-[320px] items-center justify-center rounded-3xl bg-black p-8 text-center text-white animate-[resultEnter_0.42s_ease-out]">
          <div className="w-full animate-[fadeUp_0.42s_ease-out]">
            <p aria-label={RESULT_INTRO_TEXT} className={`flex min-h-[1.5rem] items-center justify-center text-lg font-semibold leading-tight text-white/65 transition-opacity duration-700 ease-out ${showWinnerIntro ? 'opacity-100' : 'opacity-0'}`}>{RESULT_INTRO_TEXT}</p>
            <div className="mt-6 flex min-h-[5.25rem] items-center justify-center"><p className={`overflow-hidden break-words text-[clamp(2.75rem,15vw,4.5rem)] font-extrabold uppercase leading-[0.92] tracking-tight transition-all duration-700 ease-out ${showWinnerName ? 'translate-y-0 scale-100 opacity-100' : 'translate-y-2 scale-[0.98] opacity-0'}`}>{winnerName}</p></div>
            {showCardType ? <div onClick={finishSlotAnimation} className="mt-8 rounded-3xl bg-white px-5 py-5 text-black shadow-sm animate-[fadeUp_0.42s_ease-out]">
              <p className="text-xs font-semibold uppercase tracking-[0.25em] text-neutral-500">Coge una carta</p>
              <p className={`mt-2 text-4xl font-extrabold tracking-tight transition-transform duration-300 ${slotFinished ? 'animate-[slotPop_0.24s_ease-out]' : isSlotRunning ? 'scale-[1.025]' : 'scale-100'}`}>{displayedCardType || cardType}</p>
            </div> : null}
          </div>
        </div>
        {slotFinished && showContinueSlider ? <div className="mt-6 animate-[fadeUp_0.5s_ease-out]"><ContinueSlider onComplete={() => void handleReadyNext()} /></div> : null}
      </> : null}
      {state?.status === 'closed' && tiedIds.length > 1 ? <><div className="mt-2 flex min-h-[320px] items-center justify-center rounded-3xl bg-black p-8 text-center text-white animate-[resultEnter_0.42s_ease-out]"><div className="w-full animate-[pop_0.52s_ease-out]"><p className="text-5xl font-extrabold leading-tight">¡Empate!</p><div className="mt-6 space-y-2">{tiedIds.map((id) => <div key={id} className="rounded-2xl bg-white/10 px-4 py-3 text-xl font-bold">{namedPlayers[id] || 'Jugador'}</div>)}</div></div></div><div className="mt-6 rounded-3xl border border-neutral-200 p-4 animate-[fadeUp_0.5s_ease-out]"><p className="text-sm font-semibold">Desempate</p><p className="mt-1 text-sm text-neutral-500">Todos votan otra vez, pero solo entre estos jugadores.</p><button disabled={busy} onClick={() => void handleStartTiebreak()} className="mt-4 w-full rounded-2xl bg-black px-4 py-3 font-medium text-white disabled:opacity-40">Nueva votación de desempate</button><button disabled={busy} onClick={() => void handleRandomTiebreak()} className="mt-3 w-full rounded-2xl border border-neutral-300 px-4 py-3 font-medium disabled:opacity-40">Resolver por sorteo</button></div></> : null}
      {state?.status === 'ready_next' ? <div className="mt-2 rounded-3xl border border-neutral-200 p-4 text-left"><p className="font-medium">Escanea la siguiente carta</p><div className="mt-4 flex gap-2"><span className="rounded-2xl bg-neutral-100 px-4 py-3 font-semibold">V-</span><input value={nextCardCode} onChange={(event) => setNextCardCode(event.target.value.replace(/\D/g, '').slice(0, 3))} inputMode="numeric" placeholder="001" className="min-w-0 flex-1 rounded-2xl border px-4 py-3" /></div><button disabled={busy || !nextCardCode} onClick={() => void handleNextCard()} className="mt-3 w-full rounded-2xl bg-black px-4 py-3 font-medium text-white disabled:opacity-40">Abrir siguiente carta</button></div> : null}
      {effectiveMessage ? <p className="mt-5 text-sm font-medium text-red-600">{effectiveMessage}</p> : null}
    </div></div></main>
  )
}

export default function ResultPage() {
  return <Suspense fallback={<p className="p-6">Cargando resultado...</p>}><ResultContent /></Suspense>
}
