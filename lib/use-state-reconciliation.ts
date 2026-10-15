'use client'

import { useCallback, useEffect, useRef } from 'react'

const RECONCILIATION_DEBOUNCE_MS = 200

export function useStateReconciliation(
  reconcile: () => void | Promise<void>,
  enabled = true
) {
  const timeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  const runningRef = useRef(false)
  const rerunRef = useRef(false)
  const mountedRef = useRef(true)

  const runReconciliation = useCallback(async () => {
    if (!enabled || !mountedRef.current) return

    if (runningRef.current) {
      rerunRef.current = true
      return
    }

    runningRef.current = true

    try {
      do {
        rerunRef.current = false
        await reconcile()
      } while (rerunRef.current && mountedRef.current)
    } finally {
      runningRef.current = false
    }
  }, [enabled, reconcile])

  const requestReconciliation = useCallback(() => {
    if (!enabled || !mountedRef.current || timeoutRef.current) return
    if (document.visibilityState === 'hidden' || !navigator.onLine) return

    timeoutRef.current = setTimeout(() => {
      timeoutRef.current = null
      void runReconciliation()
    }, RECONCILIATION_DEBOUNCE_MS)
  }, [enabled, runReconciliation])

  useEffect(() => {
    mountedRef.current = true

    if (!enabled) return

    const reconcileIfVisible = () => {
      if (document.visibilityState === 'visible') {
        requestReconciliation()
      }
    }

    const reconcileIfOnline = () => {
      if (navigator.onLine) {
        requestReconciliation()
      }
    }

    document.addEventListener('visibilitychange', reconcileIfVisible)
    window.addEventListener('pageshow', requestReconciliation)
    window.addEventListener('focus', reconcileIfVisible)
    window.addEventListener('online', reconcileIfOnline)

    return () => {
      mountedRef.current = false
      rerunRef.current = false

      if (timeoutRef.current) {
        clearTimeout(timeoutRef.current)
        timeoutRef.current = null
      }

      document.removeEventListener('visibilitychange', reconcileIfVisible)
      window.removeEventListener('pageshow', requestReconciliation)
      window.removeEventListener('focus', reconcileIfVisible)
      window.removeEventListener('online', reconcileIfOnline)
    }
  }, [enabled, requestReconciliation])

  return requestReconciliation
}
