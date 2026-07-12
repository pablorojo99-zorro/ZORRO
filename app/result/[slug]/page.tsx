
'use client'

import type { FormEvent, PointerEvent } from 'react'
import { useCallback, useEffect, useRef, useState } from 'react'
import { supabase } from '@/lib/supabase'
import {
  getActiveCardRoundId,
  getActiveCardSlug,
  getCardScanMessage,
} from '@/lib/active-card'
import { cardExists, createCardSlugFromCode } from '@/lib/cards'
import {
  activateGameCard,
  clearActiveCardIfCurrent,
  closeVoteRoundIfComplete,
  joinGameByCode,
  markRoundReadyNext,
  resolveRandomTiebreak,
  startTiebreakRound,
} from '@/lib/game-flow'
import { generateSessionId, getErrorMessage } from '@/lib/session'
import Image from 'next/image'
import { useParams, useRouter } from 'next/navigation'

type Player = {
  id: string
  name: string
}

type Game = {
  id: string
  code: string
}

const RESULT_INTRO_TEXT = 'El jugador más votado es...'

type JoinPlayer = {
  id: string
  name: string
}

function getCardTypeFromRound(roundId: string) {
  let total = 0

  for (const char of roundId) {
    total += char.charCodeAt(0)
  }

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
    const nextProgress = Math.min(Math.max((clientX - rect.left - 4 - thumbSize / 2) / travel, 0), 1)

    setMaxTravel(travel)
    setProgress(nextProgress)
  }

  function handlePointerDown(event: PointerEvent<HTMLDivElement>) {
    if (locked) return

    event.currentTarget.setPointerCapture(event.pointerId)
    setDragging(true)
    updateProgress(event.clientX)
  }

  function handlePointerMove(event: PointerEvent<HTMLDivElement>) {
    if (!dragging) return

    updateProgress(event.clientX)
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
    <div
      ref={trackRef}
      role="button"
      tabIndex={0}
      aria-label="Desliza para continuar"
      onPointerDown={handlePointerDown}
      onPointerMove={handlePointerMove}
      onPointerUp={handlePointerEnd}
      onPointerCancel={handlePointerEnd}
      className="relative h-14 select-none overflow-hidden rounded-full bg-neutral-100 touch-none"
    >
      <p
        className="pointer-events-none absolute inset-0 flex items-center justify-center text-sm font-medium text-neutral-500 transition-opacity duration-150"
        style={{ opacity: Math.max(0.28, 1 - progress * 0.72) }}
      >
        Desliza para continuar
      </p>

      <div
        className={`absolute left-1 top-1 flex h-12 w-12 items-center justify-center rounded-full bg-black shadow-sm ${
          dragging ? '' : 'transition-transform duration-300 ease-out'
        }`}
        style={{
          transform: `translateX(${progress * maxTravel}px) scale(${successPulse ? 1.08 : 1})`,
          transitionTimingFunction: successPulse
            ? 'cubic-bezier(0.34, 1.56, 0.64, 1)'
            : undefined,
        }}
      >
        <Image
          src="/zorro-brand-white.svg"
          alt=""
          aria-hidden="true"
          width={33}
          height={33}
          className="h-[33px] w-[33px]"
        />
      </div>
    </div>
  )
}

export default function ResultPage() {
  const params = useParams()
  const router = useRouter()
  const slug = params.slug as string

  const [winnerText, setWinnerText] = useState('')
  const [winnerName, setWinnerName] = useState('')
  const [cardType, setCardType] = useState('')
  const [displayedCardType, setDisplayedCardType] = useState('')
  const [isSlotRunning, setIsSlotRunning] = useState(false)
  const [slotFinished, setSlotFinished] = useState(false)
  const [roundFinished, setRoundFinished] = useState(false)
  const [resultExiting, setResultExiting] = useState(false)
  const [showContinueSlider, setShowContinueSlider] = useState(false)
  const [showNextCardForm, setShowNextCardForm] = useState(false)
  const [showWinnerIntro, setShowWinnerIntro] = useState(false)
  const [showWinnerName, setShowWinnerName] = useState(false)
  const [showCardType, setShowCardType] = useState(false)
  const [animationKey, setAnimationKey] = useState(0)
  const [tiedPlayers, setTiedPlayers] = useState<Player[]>([])
  const [finalRoundId, setFinalRoundId] = useState<string | null>(null)
  const [currentGameId, setCurrentGameId] = useState<string | null>(null)
  const [currentGameCode, setCurrentGameCode] = useState('')
  const [nextCardCode, setNextCardCode] = useState('')
  const [cardScanMessage, setCardScanMessage] = useState('')
  const [needsGameCode, setNeedsGameCode] = useState(false)
  const [joinCode, setJoinCode] = useState('')
  const [joinName, setJoinName] = useState('')
  const [joinGame, setJoinGame] = useState<Game | null>(null)
  const [joinPlayers, setJoinPlayers] = useState<JoinPlayer[]>([])
  const [joiningGame, setJoiningGame] = useState(false)
  const [startingTiebreak, setStartingTiebreak] = useState(false)
  const [resolvingRandomTiebreak, setResolvingRandomTiebreak] = useState(false)
  const [openingNextCard, setOpeningNextCard] = useState(false)
  const [loadKey, setLoadKey] = useState(0)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const redirectingToCardRef = useRef(false)
  const slotTimersRef = useRef<ReturnType<typeof setTimeout>[]>([])

  const redirectToActiveCard = useCallback((activeCardValue: string) => {
    const activeCardSlug = getActiveCardSlug(activeCardValue)
    const activeCardRoundId = getActiveCardRoundId(activeCardValue)

    if (
      !activeCardSlug ||
      (activeCardSlug === slug && !activeCardRoundId) ||
      activeCardRoundId === finalRoundId ||
      redirectingToCardRef.current
    ) {
      return
    }

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
  }, [finalRoundId, router, slug])

  useEffect(() => {
    const existingStyle = document.getElementById('result-animation-style')

    if (existingStyle) return

    const style = document.createElement('style')
    style.id = 'result-animation-style'
    style.innerHTML = `
      @keyframes pop {
        0% { transform: scale(0.86); opacity: 0; }
        65% { transform: scale(1.035); opacity: 1; }
        100% { transform: scale(1); opacity: 1; }
      }

      @keyframes fadeUp {
        0% { transform: translateY(12px); opacity: 0; }
        100% { transform: translateY(0); opacity: 1; }
      }

      @keyframes resultEnter {
        0% { transform: translateY(10px) scale(0.985); opacity: 0; }
        100% { transform: translateY(0) scale(1); opacity: 1; }
      }

      @keyframes slotPop {
        0% { transform: scale(1); }
        50% { transform: scale(1.045); }
        100% { transform: scale(1); }
      }
    `
    document.head.appendChild(style)
  }, [])

  const resetSlotAnimation = useCallback(() => {
    slotTimersRef.current.forEach((timer) => clearTimeout(timer))
    slotTimersRef.current = []
    setDisplayedCardType('')
    setIsSlotRunning(false)
    setSlotFinished(false)
    setRoundFinished(false)
    setResultExiting(false)
    setShowContinueSlider(false)
    setShowNextCardForm(false)
    setShowWinnerIntro(false)
  }, [])

  const showNextCardPreparation = useCallback(() => {
    slotTimersRef.current.forEach((timer) => clearTimeout(timer))
    slotTimersRef.current = []
    setIsSlotRunning(false)
    setShowContinueSlider(false)
    setResultExiting(true)

    const closeResultTimer = setTimeout(() => {
      setRoundFinished(true)
      setShowNextCardForm(true)
      setResultExiting(false)
    }, 180)

    slotTimersRef.current.push(closeResultTimer)
  }, [])

  useEffect(() => {
    async function loadResults() {
      try {
        const sessionId = localStorage.getItem('session_id')
        const roundFromQuery = new URLSearchParams(window.location.search).get('round')
        const roundFromStorage = localStorage.getItem(`last_round_${slug}`)

        if (!sessionId) {
          setNeedsGameCode(true)
          setLoading(false)
          return
        }

        const { data: currentPlayer, error: currentPlayerError } = await supabase
          .from('players')
          .select('game_id, name')
          .eq('session_id', sessionId)
          .eq('active', true)
          .single()

        if (currentPlayerError || !currentPlayer) {
          console.error('RESULT PLAYER ERROR', currentPlayerError)
          setNeedsGameCode(true)
          setLoading(false)
          return
        }

        setCurrentGameId(currentPlayer.game_id)
        const { data: gameData, error: gameError } = await supabase
          .from('games')
          .select('id, code, active_card_slug')
          .eq('id', currentPlayer.game_id)
          .single()

        if (gameError || !gameData) {
          console.error('RESULT GAME ERROR', gameError)
        } else {
          setCurrentGameCode(gameData.code)

          const activeCardRoundId = getActiveCardRoundId(gameData.active_card_slug)
          const currentResultRoundId = roundFromQuery || roundFromStorage

          if (
            getActiveCardSlug(gameData.active_card_slug) === slug &&
            (!activeCardRoundId || activeCardRoundId === currentResultRoundId)
          ) {
            try {
              await clearActiveCardIfCurrent(gameData.id, sessionId, slug)
            } catch (clearActiveCardError) {
              console.error('RESULT CLEAR ACTIVE CARD ERROR', clearActiveCardError)
            }
          }
        }

        const { data: card, error: cardError } = await supabase
          .from('cards')
          .select('id')
          .eq('slug', slug)
          .single()

        if (cardError || !card) {
          console.error('RESULT CARD ERROR', cardError)
          setError('No se encontró la carta')
          setLoading(false)
          return
        }

        let resolvedRoundId = roundFromQuery || roundFromStorage

        if (!resolvedRoundId) {
          const { data: fallbackRound, error: fallbackRoundError } = await supabase
            .from('vote_rounds')
            .select('id')
            .eq('game_id', currentPlayer.game_id)
            .eq('card_id', card.id)
            .order('created_at', { ascending: false })
            .limit(1)
            .maybeSingle()

          if (fallbackRoundError || !fallbackRound) {
            console.error('RESULT ROUND FALLBACK ERROR', fallbackRoundError)
            setError('No se encontró la ronda de votación')
            setLoading(false)
            return
          }

          resolvedRoundId = fallbackRound.id
        }

        if (!resolvedRoundId) {
          setError('No se encontró la ronda de votación')
          setLoading(false)
          return
        }

        const resultRoundId = resolvedRoundId

        setFinalRoundId(resultRoundId)

        const { data: resultRound, error: resultRoundError } = await supabase
          .from('vote_rounds')
          .select('id, status, tie_player_ids')
          .eq('id', resultRoundId)
          .eq('game_id', currentPlayer.game_id)
          .eq('card_id', card.id)
          .single()

        if (resultRoundError || !resultRound) {
          console.error('RESULT ROUND ERROR', resultRoundError)
          setError('No se encontró la ronda de votación')
          setLoading(false)
          return
        }

        if (resultRound.status === 'ready_next') {
          setWinnerName('')
          setCardType('')
          setShowWinnerName(false)
          setShowCardType(false)
          resetSlotAnimation()
          setTiedPlayers([])
          setWinnerText('')
          setRoundFinished(true)
          setResultExiting(false)
          setShowContinueSlider(false)
          setShowNextCardForm(true)
          setLoading(false)
          return
        }

        if (
          resultRound.status === 'closed' &&
          resultRound.tie_player_ids &&
          resultRound.tie_player_ids.length === 1
        ) {
          const { data: resolvedWinner, error: resolvedWinnerError } = await supabase
            .from('players')
            .select('id, name')
            .eq('id', resultRound.tie_player_ids[0])
            .single()

          if (resolvedWinnerError || !resolvedWinner) {
            console.error('RANDOM TIEBREAK WINNER ERROR', resolvedWinnerError)
            setError('No se pudo cargar el desempate aleatorio')
            setLoading(false)
            return
          }

          setShowWinnerName(false)
          setShowCardType(false)
          resetSlotAnimation()
          setWinnerName(resolvedWinner.name)
          setCardType(getCardTypeFromRound(resultRoundId))
          setTiedPlayers([])
          setWinnerText('')
          setAnimationKey((key) => key + 1)
          setLoading(false)
          return
        }

        const { data: votes, error: votesError } = await supabase
          .from('votes')
          .select('voted_player_id, voter_session_id')
          .eq('vote_round_id', resultRoundId)

        if (votesError) {
          console.error('RESULT VOTES ERROR', votesError)
          setError('Error cargando votos')
          setLoading(false)
          return
        }

        const { data: activePlayers, error: activePlayersError } = await supabase
          .from('players')
          .select('session_id')
          .eq('game_id', currentPlayer.game_id)
          .eq('active', true)

        if (activePlayersError || !activePlayers) {
          console.error('RESULT ACTIVE PLAYERS ERROR', activePlayersError)
          setError('No se pudo comprobar si todos habían votado')
          setLoading(false)
          return
        }

        const requiredVoteCount = activePlayers.length
        const uniqueVoterCount = new Set(
          (votes || []).map((vote) => vote.voter_session_id).filter(Boolean)
        ).size
        const roundIsClosed = resultRound.status === 'closed'
        const roundIsComplete = requiredVoteCount > 0 && uniqueVoterCount >= requiredVoteCount

        if (!roundIsClosed && !roundIsComplete) {
          setWinnerName('')
          setCardType('')
          setShowWinnerName(false)
          setShowCardType(false)
          resetSlotAnimation()
          setTiedPlayers([])
          setWinnerText('Esperando a que todos voten')
          setLoading(false)
          return
        }

        if (!votes || votes.length === 0) {
          setWinnerName('')
          setCardType('')
          setShowWinnerName(false)
          setShowCardType(false)
          resetSlotAnimation()
          setTiedPlayers([])
          setWinnerText('Todavía no hay votos')
          setLoading(false)
          return
        }

        const counts: Record<string, number> = {}
        votes.forEach((vote) => {
          counts[vote.voted_player_id] = (counts[vote.voted_player_id] || 0) + 1
        })

        const playerIds = Object.keys(counts)

        const { data: players, error: playersError } = await supabase
          .from('players')
          .select('id, name')
          .in('id', playerIds)

        if (playersError || !players) {
          console.error('RESULT PLAYERS ERROR', playersError)
          setError('Error cargando jugadores')
          setLoading(false)
          return
        }

        let maxVotes = 0
        let winners: Player[] = []

        players.forEach((player: Player) => {
          const voteCount = counts[player.id] || 0

          if (voteCount > maxVotes) {
            maxVotes = voteCount
            winners = [player]
          } else if (voteCount === maxVotes) {
            winners.push(player)
          }
        })

        if (maxVotes === 0) {
          setWinnerName('')
          setCardType('')
          setShowWinnerName(false)
          setShowCardType(false)
          resetSlotAnimation()
          setTiedPlayers([])
          setWinnerText('Todavía no hay votos')
        } else if (winners.length === 1) {
          setShowWinnerName(false)
          setShowCardType(false)
          resetSlotAnimation()
          setWinnerName(winners[0].name)
          setCardType(getCardTypeFromRound(resultRoundId))
          setTiedPlayers([])
          setWinnerText('')
          setAnimationKey((key) => key + 1)
        } else {
          setWinnerName('')
          setCardType('')
          setShowWinnerName(false)
          setShowCardType(false)
          resetSlotAnimation()
          setTiedPlayers(winners)
          setWinnerText(`Empate entre ${winners.map((winner) => winner.name).join(', ')}`)
        }

        if (winners.length <= 1 && !roundIsClosed) {
          try {
            await closeVoteRoundIfComplete(resultRoundId, sessionId)
          } catch (closeRoundError) {
            console.error('RESULT CLOSE ROUND ERROR', closeRoundError)
          }
        }

        setLoading(false)
      } catch (err) {
        console.error('RESULT LOAD ERROR', err)
        setError('Error cargando resultado')
        setLoading(false)
      }
    }

    loadResults()
  }, [slug, resetSlotAnimation, showNextCardPreparation, loadKey])

  useEffect(() => {
    if (!currentGameId) return

    const channel = supabase
      .channel(`result-game:${currentGameId}`)
      .on(
        'postgres_changes',
        {
          event: 'UPDATE',
          schema: 'public',
          table: 'games',
          filter: `id=eq.${currentGameId}`,
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
  }, [currentGameId, redirectToActiveCard])

  useEffect(() => {
    if (!finalRoundId) return

    const channel = supabase
      .channel(`result-round:${finalRoundId}`)
      .on(
        'postgres_changes',
        {
          event: 'UPDATE',
          schema: 'public',
          table: 'vote_rounds',
          filter: `id=eq.${finalRoundId}`,
        },
        (payload) => {
          const round = payload.new

          if (round.status === 'ready_next' && !roundFinished) {
            showNextCardPreparation()
            return
          }

          if (
            round.status === 'closed' &&
            Array.isArray(round.tie_player_ids) &&
            round.tie_player_ids.length === 1 &&
            tiedPlayers.length >= 2
          ) {
            setLoadKey((key) => key + 1)
          }
        }
      )
      .subscribe()

    return () => {
      supabase.removeChannel(channel)
    }
  }, [finalRoundId, roundFinished, showNextCardPreparation, tiedPlayers.length])

  useEffect(() => {
    if (!finalRoundId || roundFinished) return

    async function checkRoundStatus() {
      const { data: round, error: roundError } = await supabase
        .from('vote_rounds')
        .select('status')
        .eq('id', finalRoundId)
        .single()

      if (roundError) {
        console.error('READY NEXT CHECK ERROR', roundError)
        return
      }

      if (round?.status === 'ready_next') {
        showNextCardPreparation()
      }
    }

    checkRoundStatus()
  }, [finalRoundId, roundFinished, showNextCardPreparation])

  useEffect(() => {
    if (loading || error || !winnerName) return

    const introTimer = setTimeout(() => {
      setShowWinnerIntro(true)
    }, 520)

    const winnerTimer = setTimeout(() => {
      setShowWinnerName(true)
    }, 2150)

    const cardTypeTimer = setTimeout(() => {
      setShowCardType(true)
    }, 3850)

    return () => {
      clearTimeout(introTimer)
      clearTimeout(winnerTimer)
      clearTimeout(cardTypeTimer)
    }
  }, [loading, error, winnerName, animationKey])

  useEffect(() => {
    if (!showCardType || !cardType) return

    const delays = [110, 140, 180, 240, 320, 440, 620]

    slotTimersRef.current.forEach((timer) => clearTimeout(timer))
    slotTimersRef.current = []

    const startTimer = setTimeout(() => {
      let elapsed = 0

      setDisplayedCardType(cardType === 'RETO' ? 'CONFESIÓN' : 'RETO')
      setIsSlotRunning(true)
      setSlotFinished(false)

      delays.forEach((delay, index) => {
        elapsed += delay

        const timer = setTimeout(() => {
          const isLastStep = index === delays.length - 1

          if (isLastStep) {
            setDisplayedCardType(cardType)
            setIsSlotRunning(false)
            setSlotFinished(true)
            vibrateSlotResult()

            const continueSliderTimer = setTimeout(() => {
              setShowContinueSlider(true)
            }, 650)

            slotTimersRef.current.push(continueSliderTimer)
            return
          }

          setDisplayedCardType(index % 2 === 0 ? 'RETO' : 'CONFESIÓN')
        }, elapsed)

        slotTimersRef.current.push(timer)
      })
    }, 0)

    slotTimersRef.current.push(startTimer)

    return () => {
      slotTimersRef.current.forEach((timer) => clearTimeout(timer))
      slotTimersRef.current = []
    }
  }, [showCardType, cardType, animationKey])

  function finishSlotAnimation() {
    if (!isSlotRunning || !cardType) return

    slotTimersRef.current.forEach((timer) => clearTimeout(timer))
    slotTimersRef.current = []
    setDisplayedCardType(cardType)
    setIsSlotRunning(false)
    setSlotFinished(true)
    vibrateSlotResult()
    setShowContinueSlider(true)
  }

  async function handleContinueToNextCardForm() {
    if (!finalRoundId) {
      showNextCardPreparation()
      return
    }

    setError(null)

    const sessionId = localStorage.getItem('session_id')

    if (!sessionId) {
      setError('No se pudo identificar tu sesión')
      return
    }

    try {
      await markRoundReadyNext(finalRoundId, sessionId)
    } catch (updateError) {
      console.error('READY NEXT UPDATE ERROR', updateError)
      setError('No se pudo preparar la siguiente carta')
      return
    }

    showNextCardPreparation()
  }

  async function handleGoToNextCardByCode() {
    const nextCardSlug = createCardSlugFromCode(nextCardCode)

    if (!nextCardSlug || !currentGameId || openingNextCard) return

    setOpeningNextCard(true)
    setError(null)

    try {
      const exists = await cardExists(nextCardSlug)

      if (!exists) {
        setError('No existe esa carta')
        setOpeningNextCard(false)
        return
      }
    } catch (err) {
      console.error('NEXT CARD VALIDATION ERROR', err)
      setError('No se pudo comprobar la siguiente carta')
      setOpeningNextCard(false)
      return
    }

    const sessionId = localStorage.getItem('session_id')

    if (!sessionId) {
      setError('No se pudo identificar tu sesión')
      setOpeningNextCard(false)
      return
    }

    try {
      await activateGameCard(currentGameId, sessionId, nextCardSlug)
    } catch (activeCardError) {
      console.error('NEXT ACTIVE CARD ERROR', activeCardError)
      setError('No se pudo abrir la siguiente carta')
      setOpeningNextCard(false)
      return
    }

    router.push(`/card/${nextCardSlug}`)
  }

  async function handleTiebreak() {
    if (
      !finalRoundId ||
      tiedPlayers.length < 2 ||
      startingTiebreak ||
      resolvingRandomTiebreak
    ) return

    setStartingTiebreak(true)

    const tiedPlayerIds = tiedPlayers.map((player) => player.id)
    const sessionId = localStorage.getItem('session_id')

    if (!sessionId) {
      setError('No se pudo identificar tu sesión')
      setStartingTiebreak(false)
      return
    }

    let tiebreakRoundId: string

    try {
      tiebreakRoundId = await startTiebreakRound(finalRoundId, sessionId, tiedPlayerIds)
    } catch (tiebreakError) {
      console.error('TIEBREAK ROUND ERROR', tiebreakError)
      setError('No se pudo crear el desempate')
      setStartingTiebreak(false)
      return
    }

    localStorage.setItem(`last_round_${slug}`, tiebreakRoundId)
    router.push(`/card/${slug}?auto=1&round=${tiebreakRoundId}`)
  }

  async function handleRandomTiebreak() {
    if (!finalRoundId || tiedPlayers.length < 2 || resolvingRandomTiebreak || startingTiebreak) {
      return
    }

    setResolvingRandomTiebreak(true)
    setError(null)

    const sessionId = localStorage.getItem('session_id')

    if (!sessionId) {
      setError('No se pudo identificar tu sesión')
      setResolvingRandomTiebreak(false)
      return
    }

    try {
      await resolveRandomTiebreak(
        finalRoundId,
        sessionId,
        tiedPlayers.map((player) => player.id)
      )
    } catch (updateError) {
      console.error('RANDOM TIEBREAK UPDATE ERROR', updateError)
      setError('No se pudo resolver el desempate aleatorio')
      setResolvingRandomTiebreak(false)
      return
    }

    localStorage.setItem(`last_round_${slug}`, finalRoundId)
    setLoadKey((key) => key + 1)
    setResolvingRandomTiebreak(false)
  }

  function finishJoinFromResult(newSessionId: string, cleanCode: string, playerName: string) {
    localStorage.setItem('session_id', newSessionId)
    localStorage.setItem('game_code', cleanCode)
    localStorage.setItem('player_name', playerName)

    setNeedsGameCode(false)
    setLoading(true)
    setLoadKey((key) => key + 1)
  }

  async function handleFindGameFromResult(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    setError(null)

    if (!joinCode.trim()) {
      setError('Escribe el código de partida')
      return
    }

    try {
      setJoiningGame(true)

      const cleanCode = joinCode.trim().toUpperCase()
      const { data: gameData, error: gameError } = await supabase
        .from('games')
        .select('id, code')
        .eq('code', cleanCode)
        .single()

      if (gameError || !gameData) {
        setError('No existe esa partida')
        return
      }

      const { data: playerList, error: playersError } = await supabase
        .from('players')
        .select('id, name')
        .eq('game_id', gameData.id)
        .eq('active', true)
        .order('created_at', { ascending: true })

      if (playersError || !playerList) {
        throw new Error(getErrorMessage(playersError))
      }

      setJoinGame(gameData)
      setJoinPlayers(playerList)
    } catch (err) {
      const message = getErrorMessage(err)
      console.error('RESULT FIND GAME ERROR', message, err)
      setError(`No se pudo cargar la partida: ${message}`)
    } finally {
      setJoiningGame(false)
    }
  }

  async function handleJoinResultAsNewPlayer(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()

    if (!joinGame) return

    setError(null)

    if (!joinName.trim()) {
      setError('Escribe tu nombre')
      return
    }

    try {
      setJoiningGame(true)

      const newSessionId = generateSessionId()
      const joinedGame = await joinGameByCode(joinGame.code, newSessionId, joinName.trim())

      finishJoinFromResult(newSessionId, joinedGame.code, joinName.trim())
    } catch (err) {
      const message = getErrorMessage(err)
      console.error('RESULT NEW PLAYER JOIN ERROR', message, err)
      setError(`No se pudo unir a la partida: ${message}`)
    } finally {
      setJoiningGame(false)
    }
  }

  if (needsGameCode) {
    return (
      <main className="min-h-screen bg-neutral-100 flex items-center justify-center">
        <div className="w-full max-w-md px-6 py-10">
          <div className="relative rounded-3xl bg-white p-6 shadow-sm ring-1 ring-black/5">
            <Image
              src="/zorro-brand-black.svg"
              alt=""
              aria-hidden="true"
              width={60}
              height={60}
              className="absolute right-5 top-4 h-[60px] w-[60px] opacity-75"
            />

            <h1 className="pr-12 text-2xl font-bold tracking-tight">
              Recuperar resultado
            </h1>
            <p className="mt-2 text-sm text-neutral-600">
              Introduce el código de partida y elige quién eres para volver al resultado.
            </p>

            {!joinGame ? (
              <form onSubmit={handleFindGameFromResult}>
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

                <form onSubmit={handleJoinResultAsNewPlayer}>
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
                    setError(null)
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

  return (
    <main className="min-h-screen bg-neutral-100 flex items-center justify-center">
      <div className="w-full max-w-md px-6 py-10">
        <div className="relative rounded-3xl bg-white p-6 shadow-sm ring-1 ring-black/5">
          <Image
            src="/zorro-brand-black.svg"
            alt=""
            aria-hidden="true"
            width={60}
            height={60}
            className="absolute right-5 top-4 h-[60px] w-[60px] opacity-75"
          />

          {loading ? (
            <p className="text-neutral-600">Cargando...</p>
          ) : error ? (
            <>
              <p className="text-red-600">{error}</p>
              <button
                onClick={() => router.push('/')}
                className="mt-6 w-full rounded-2xl border px-4 py-3 font-medium"
              >
                Volver
              </button>
            </>
          ) : cardScanMessage ? (
            <p className="rounded-2xl bg-black px-4 py-3 text-center font-medium text-white">
              {cardScanMessage}
            </p>
          ) : (
            <>
              {currentGameCode ? (
                <div className="mb-4 pr-12">
                  <p className="text-sm text-neutral-500">Partida</p>
                  <p className="text-lg font-semibold text-neutral-900">
                    {currentGameCode}
                  </p>
                </div>
              ) : null}

              {!roundFinished ? (
                <div
                  className={`min-h-[320px] rounded-3xl bg-black p-8 text-center text-white flex items-center justify-center animate-[resultEnter_0.42s_ease-out] transition-all duration-200 ease-out ${
                    resultExiting ? 'translate-y-1 scale-[0.985] opacity-0' : 'translate-y-0 scale-100 opacity-100'
                  }`}
                >
                  {winnerName ? (
                    <div className="w-full">
                      <div className="animate-[fadeUp_0.42s_ease-out]">
                        <p
                          aria-label={RESULT_INTRO_TEXT}
                          className={`flex min-h-[1.5rem] items-center justify-center text-lg font-semibold leading-tight text-white/65 transition-opacity duration-700 ease-out ${
                            showWinnerIntro ? 'opacity-100' : 'opacity-0'
                          }`}
                        >
                          {RESULT_INTRO_TEXT}
                        </p>

                        <div className="mt-6 flex min-h-[5.25rem] items-center justify-center">
                          <p
                            className={`overflow-hidden break-words text-[clamp(2.75rem,15vw,4.5rem)] font-extrabold uppercase tracking-tight leading-[0.92] transition-all duration-700 ease-out ${
                              showWinnerName
                                ? 'translate-y-0 scale-100 opacity-100'
                                : 'translate-y-2 scale-[0.98] opacity-0'
                            }`}
                          >
                            {winnerName}
                          </p>
                        </div>

                        {showCardType ? (
                          <div
                            onClick={finishSlotAnimation}
                            className="mt-8 rounded-3xl bg-white px-5 py-5 text-black shadow-sm animate-[fadeUp_0.42s_ease-out]"
                          >
                            <p className="text-xs font-semibold uppercase tracking-[0.25em] text-neutral-500">
                              Coge una carta
                            </p>
                            <p
                              className={`mt-2 text-4xl font-extrabold tracking-tight transition-transform duration-300 ${
                                slotFinished
                                  ? 'animate-[slotPop_0.24s_ease-out]'
                                  : isSlotRunning
                                    ? 'scale-[1.025]'
                                    : 'scale-100'
                              }`}
                            >
                              {displayedCardType || cardType}
                            </p>
                          </div>
                        ) : null}
                      </div>
                    </div>
                  ) : tiedPlayers.length > 1 ? (
                    <div className="w-full animate-[pop_0.52s_ease-out]">
                      <p className="text-5xl font-extrabold leading-tight">
                        ¡Empate!
                      </p>

                      <div className="mt-6 space-y-2">
                        {tiedPlayers.map((player) => (
                          <div
                            key={player.id}
                            className="rounded-2xl bg-white/10 px-4 py-3 text-xl font-bold"
                          >
                            {player.name}
                          </div>
                        ))}
                      </div>
                    </div>
                  ) : (
                    <div className="w-full animate-[pop_0.52s_ease-out]">
                      <p className="text-4xl font-extrabold leading-tight">
                        {winnerText}
                      </p>
                    </div>
                  )}
                </div>
              ) : null}

              {!roundFinished && tiedPlayers.length > 1 ? (
                <div className="mt-6 rounded-3xl border border-neutral-200 p-4 animate-[fadeUp_0.5s_ease-out]">
                  <p className="text-sm font-semibold text-neutral-900">
                    Desempate
                  </p>
                  <p className="mt-1 text-sm text-neutral-500">
                    Todos votan otra vez, pero solo entre estos jugadores.
                  </p>

                  <button
                    onClick={handleTiebreak}
                    disabled={startingTiebreak || resolvingRandomTiebreak}
                    className="mt-4 w-full rounded-2xl bg-black px-4 py-3 font-medium text-white transition hover:opacity-90 disabled:opacity-50"
                  >
                    {startingTiebreak ? 'Preparando desempate...' : 'Empezar desempate'}
                  </button>

                  <button
                    onClick={handleRandomTiebreak}
                    disabled={startingTiebreak || resolvingRandomTiebreak}
                    className="mt-3 w-full rounded-2xl border border-neutral-300 px-4 py-3 font-medium text-neutral-900 transition hover:bg-neutral-50 disabled:opacity-50"
                  >
                    {resolvingRandomTiebreak
                      ? 'Resolviendo desempate...'
                      : 'Desempate aleatorio'}
                  </button>
                </div>
              ) : null}

              {!roundFinished && winnerName && slotFinished && showContinueSlider && !showNextCardForm ? (
                <div className="mt-6 animate-[fadeUp_0.5s_ease-out]">
                  <ContinueSlider onComplete={handleContinueToNextCardForm} />
                </div>
              ) : null}

              {showNextCardForm && (roundFinished || (winnerName && slotFinished)) ? (
                <div className="mt-6 rounded-3xl border border-neutral-200 p-4 animate-[fadeUp_0.5s_ease-out]">
                  <p className="text-sm font-semibold text-neutral-900">
                    Siguiente carta
                  </p>
                  <p className="mt-1 text-sm text-neutral-500">
                    Escanea o introduce el número de la siguiente carta Zorro.
                  </p>

                  <div className="mt-4 flex items-center gap-2">
                    <div className="rounded-2xl bg-neutral-100 px-4 py-3 font-semibold text-neutral-600">
                      Z-
                    </div>
                    <input
                      type="text"
                      inputMode="numeric"
                      value={nextCardCode}
                      onChange={(event) =>
                        setNextCardCode(event.target.value.replace(/\D/g, '').slice(0, 3))
                      }
                      placeholder="001"
                      className="min-w-0 flex-1 rounded-2xl border border-neutral-300 px-4 py-3 outline-none focus:border-neutral-500"
                    />
                  </div>

                  <button
                    onClick={handleGoToNextCardByCode}
                    disabled={!nextCardCode.trim() || openingNextCard}
                    className="mt-3 w-full rounded-2xl bg-black px-4 py-3 font-medium text-white transition hover:opacity-90 disabled:opacity-40"
                  >
                    {openingNextCard ? 'Abriendo carta...' : 'Votar'}
                  </button>
                </div>
              ) : null}
            </>
          )}
        </div>
      </div>
    </main>
  )
}
