'use client'

import { useEffect } from 'react'
import { heartbeatPlayer } from '@/lib/game-flow'
import { getStoredSessionId } from '@/lib/session'

export function usePlayerHeartbeat(gameId: string | null) {
  useEffect(() => {
    if (!gameId) return

    const activeGameId = gameId
    const sessionId = getStoredSessionId()

    if (!sessionId) return
    const activeSessionId = sessionId

    let cancelled = false

    async function beat() {
      try {
        await heartbeatPlayer(activeSessionId, activeGameId)
      } catch (error) {
        if (!cancelled) {
          console.error('PLAYER HEARTBEAT ERROR', error)
        }
      }
    }

    beat()
    const heartbeatId = window.setInterval(beat, 20000)

    return () => {
      cancelled = true
      window.clearInterval(heartbeatId)
    }
  }, [gameId])
}
