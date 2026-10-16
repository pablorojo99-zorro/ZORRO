'use client'

import { useCallback, useEffect, useRef, useState } from 'react'
import {
  type CanonicalGameStateV2,
  getCanonicalGameStateV2,
} from '@/lib/game-flow-v2'
import { supabase } from '@/lib/supabase'
import { useStateReconciliation } from '@/lib/use-state-reconciliation'

export function useV2CanonicalState(gameId: string | null, sessionId: string | null) {
  const [state, setState] = useState<CanonicalGameStateV2 | null>(null)
  const [error, setError] = useState<unknown>(null)
  const mountedRef = useRef(true)

  useEffect(() => {
    mountedRef.current = true
    return () => {
      mountedRef.current = false
    }
  }, [])

  const reconcile = useCallback(async () => {
    if (!gameId || !sessionId) return
    try {
      const nextState = await getCanonicalGameStateV2(gameId, sessionId)
      if (!mountedRef.current) return
      setState(nextState)
      setError(null)
    } catch (nextError) {
      if (mountedRef.current) setError(nextError)
    }
  }, [gameId, sessionId])

  const requestReconciliation = useStateReconciliation(
    reconcile,
    !!gameId && !!sessionId
  )

  useEffect(() => {
    if (!gameId || !sessionId) return
    requestReconciliation()
    const pollId = window.setInterval(requestReconciliation, 5000)
    const channel = supabase
      .channel(`v2-canonical:${gameId}`)
      .on(
        'postgres_changes',
        {
          event: '*',
          schema: 'public',
          table: 'realtime_events',
          filter: `game_id=eq.${gameId}`,
        },
        requestReconciliation
      )
      .subscribe((status) => {
        if (status === 'SUBSCRIBED') requestReconciliation()
      })

    return () => {
      window.clearInterval(pollId)
      void supabase.removeChannel(channel)
    }
  }, [gameId, requestReconciliation, sessionId])

  return { state, error, reconcile: requestReconciliation }
}
