'use client'

import { useCallback, useEffect, useRef } from 'react'

const NAVIGATION_RECOVERY_MS = 4000

export function useRecoverableNavigation(router: { replace: (href: string) => void }) {
  const pendingTargetRef = useRef<string | null>(null)
  const navigationTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  const recoveryTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  const generationRef = useRef(0)

  const clearTimers = useCallback(() => {
    if (navigationTimerRef.current) {
      clearTimeout(navigationTimerRef.current)
      navigationTimerRef.current = null
    }

    if (recoveryTimerRef.current) {
      clearTimeout(recoveryTimerRef.current)
      recoveryTimerRef.current = null
    }
  }, [])

  const navigate = useCallback((target: string, delayMs = 0) => {
    if (pendingTargetRef.current === target) return false

    clearTimers()
    generationRef.current += 1
    const generation = generationRef.current
    pendingTargetRef.current = target

    navigationTimerRef.current = setTimeout(() => {
      navigationTimerRef.current = null

      if (generationRef.current !== generation) return

      router.replace(target)

      recoveryTimerRef.current = setTimeout(() => {
        if (generationRef.current === generation) {
          pendingTargetRef.current = null
          recoveryTimerRef.current = null
        }
      }, NAVIGATION_RECOVERY_MS)
    }, delayMs)

    return true
  }, [clearTimers, router])

  useEffect(() => {
    return () => {
      generationRef.current += 1
      pendingTargetRef.current = null
      clearTimers()
    }
  }, [clearTimers])

  return navigate
}
