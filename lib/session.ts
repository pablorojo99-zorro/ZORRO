export function generateSessionId() {
  if (globalThis.crypto?.randomUUID) {
    return globalThis.crypto.randomUUID()
  }

  const bytes = new Uint8Array(16)

  if (globalThis.crypto?.getRandomValues) {
    globalThis.crypto.getRandomValues(bytes)
  } else {
    for (let index = 0; index < bytes.length; index++) {
      bytes[index] = Math.floor(Math.random() * 256)
    }
  }

  bytes[6] = (bytes[6] & 0x0f) | 0x40
  bytes[8] = (bytes[8] & 0x3f) | 0x80

  const hex = Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0'))
    .join('')

  return [
    hex.slice(0, 8),
    hex.slice(8, 12),
    hex.slice(12, 16),
    hex.slice(16, 20),
    hex.slice(20),
  ].join('-')
}

export function getStoredSessionId() {
  return localStorage.getItem('session_id')
}

export function getOrCreateSessionId() {
  const existingSessionId = getStoredSessionId()

  if (existingSessionId) {
    return existingSessionId
  }

  const sessionId = generateSessionId()
  localStorage.setItem('session_id', sessionId)
  return sessionId
}

export function storeGameSession(sessionId: string, gameCode: string, playerName: string) {
  localStorage.setItem('session_id', sessionId)
  localStorage.setItem('game_code', gameCode)
  localStorage.setItem('player_name', playerName)
}

export function getErrorMessage(err: unknown) {
  if (err instanceof Error) return err.message

  if (err && typeof err === 'object') {
    const maybeError = err as {
      message?: string
      details?: string
      hint?: string
      code?: string
    }

    const message = [
      maybeError.message,
      maybeError.details,
      maybeError.hint,
      maybeError.code,
    ]
      .filter(Boolean)
      .join(' ')

    if (message) return message
  }

  return 'Error desconocido'
}
