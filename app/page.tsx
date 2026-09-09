'use client'

import { useState } from 'react'
import { createGameWithHost, joinGameByCode } from '@/lib/game-flow'
import { getErrorMessage, getOrCreateSessionId, storeGameSession } from '@/lib/session'
import Image from 'next/image'
import { useRouter } from 'next/navigation'

function generateCode(length = 4) {
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'
  let result = ''

  for (let i = 0; i < length; i++) {
    result += chars.charAt(Math.floor(Math.random() * chars.length))
  }

  return result
}

function isUniqueViolation(err: unknown) {
  return (
    !!err &&
    typeof err === 'object' &&
    'code' in err &&
    (err as { code?: string }).code === '23505'
  )
}

export default function HomePage() {
  const router = useRouter()

  const [name, setName] = useState('')
  const [joinCode, setJoinCode] = useState('')
  const [loadingCreate, setLoadingCreate] = useState(false)
  const [loadingJoin, setLoadingJoin] = useState(false)
  const [error, setError] = useState('')

  async function handleCreateGame() {
    setError('')

    if (!name.trim()) {
      setError('Escribe tu nombre')
      return
    }

    try {
      setLoadingCreate(true)

      const sessionId = getOrCreateSessionId()
      let code = generateCode()
      let game: { game_id: string; code: string } | null = null

      for (let attempt = 0; attempt < 5; attempt++) {
        code = generateCode()

        try {
          const createdGame = await createGameWithHost(code, sessionId, name.trim())
          game = createdGame
          break
        } catch (gameError) {
          if (!isUniqueViolation(gameError) || attempt === 4) {
            const message = getErrorMessage(gameError)
            console.error('CREATE GAME ERROR', message, gameError)
            throw new Error(message)
          }
        }
      }

      if (!game) {
        throw new Error('No se pudo generar un código de partida')
      }

      storeGameSession(sessionId, game.code, name.trim())

      router.push(`/lobby?code=${game.code}`)
    } catch (err) {
      const message = getErrorMessage(err)
      console.error('CREATE FLOW ERROR', message, err)
      setError(`No se pudo crear la partida: ${message}`)
    } finally {
      setLoadingCreate(false)
    }
  }

  async function handleJoinGame() {
    setError('')

    if (!name.trim()) {
      setError('Escribe tu nombre')
      return
    }

    if (!joinCode.trim()) {
      setError('Escribe un código de partida')
      return
    }

    try {
      setLoadingJoin(true)

      const cleanCode = joinCode.trim().toUpperCase()
      const sessionId = getOrCreateSessionId()

      const game = await joinGameByCode(cleanCode, sessionId, name.trim())

      storeGameSession(sessionId, game.code, name.trim())

      router.push(`/lobby?code=${game.code}`)
    } catch (err) {
      const message = getErrorMessage(err)
      console.error('JOIN FLOW ERROR', message, err)
      setError(`No se pudo unir a la partida: ${message}`)
    } finally {
      setLoadingJoin(false)
    }
  }

  return (
    <main className="min-h-screen bg-neutral-100 text-neutral-900">
      <div className="mx-auto flex min-h-screen max-w-md flex-col justify-center px-6 py-10">
        <div className="relative rounded-3xl bg-white p-6 shadow-sm ring-1 ring-black/5">
          <Image
            src="/zorro-brand-black.svg"
            alt=""
            aria-hidden="true"
            width={60}
            height={60}
            className="absolute right-5 top-4 h-[60px] w-[60px] opacity-75"
          />

          <h1 className="pr-12 text-3xl font-bold tracking-tight">EL GALLINERO</h1>
          <p className="mt-2 text-sm text-neutral-600">
            Crea una partida o únete con un código.
          </p>

          <div className="mt-6">
            <label className="mb-2 block text-sm font-medium">Tu nombre</label>
            <input
              type="text"
              value={name}
              onChange={(e) => setName(e.target.value)}
              placeholder="Ej. Pablo"
              className="w-full rounded-2xl border border-neutral-300 px-4 py-3 outline-none focus:border-neutral-500"
            />
          </div>

          <div className="mt-6">
            <button
              onClick={handleCreateGame}
              disabled={loadingCreate}
              className="w-full rounded-2xl border border-neutral-300 bg-white px-4 py-3 font-medium text-neutral-900 transition hover:bg-neutral-50 disabled:opacity-50"
            >
              {loadingCreate ? 'Creando partida...' : 'Crear partida'}
            </button>
          </div>

          <div className="my-6 h-px bg-neutral-200" />

          <div>
            <label className="mb-2 block text-sm font-medium">
              Código de partida
            </label>
            <input
              type="text"
              value={joinCode}
              onChange={(e) => setJoinCode(e.target.value.toUpperCase())}
              placeholder="Ej. A7KD"
              className="w-full rounded-2xl border border-neutral-300 px-4 py-3 uppercase outline-none focus:border-neutral-500"
            />
          </div>

          <div className="mt-4">
            <button
              onClick={handleJoinGame}
              disabled={loadingJoin}
              className="w-full rounded-2xl bg-black px-4 py-3 font-medium text-white transition hover:opacity-90 disabled:opacity-50"
            >
              {loadingJoin ? 'Uniéndome...' : 'Unirme a partida'}
            </button>
          </div>

          {error ? (
            <p className="mt-4 text-sm font-medium text-red-600">{error}</p>
          ) : null}
        </div>
      </div>
    </main>
  )
}
