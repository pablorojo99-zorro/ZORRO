'use client'

import { useEffect } from 'react'
import { heartbeatPlayerV2 } from '@/lib/game-flow-v2'
import { getStoredSessionId } from '@/lib/session'

export function usePlayerHeartbeatV2(gameId: string | null) {
  useEffect(() => {
    if (!gameId) return
    const sessionId = getStoredSessionId()
    if (!sessionId) return

    let cancelled = false
    const beat = async () => {
      try {
        await heartbeatPlayerV2(sessionId, gameId)
      } catch (error) {
        if (!cancelled) console.error('V2 PLAYER HEARTBEAT ERROR', error)
      }
    }

    void beat()
    const heartbeatId = window.setInterval(beat, 20000)
    return () => {
      cancelled = true
      window.clearInterval(heartbeatId)
    }
  }, [gameId])
}
