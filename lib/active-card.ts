const ACTIVE_CARD_SEPARATOR = '::scanned_by::'
const ACTIVE_CARD_ROUND_SEPARATOR = '::round::'

export function createActiveCardValue(
  slug: string,
  playerName: string | null,
  roundId?: string | null
) {
  const cleanName = playerName?.trim()
  const cardValue = roundId ? `${slug}${ACTIVE_CARD_ROUND_SEPARATOR}${roundId}` : slug

  if (!cleanName) return cardValue

  return `${cardValue}${ACTIVE_CARD_SEPARATOR}${encodeURIComponent(cleanName)}`
}

export function getActiveCardSlug(value: string | null | undefined) {
  if (!value) return null

  const cardValue = value.split(ACTIVE_CARD_SEPARATOR)[0] || ''
  return cardValue.split(ACTIVE_CARD_ROUND_SEPARATOR)[0] || null
}

export function getActiveCardRoundId(value: string | null | undefined) {
  if (!value || !value.includes(ACTIVE_CARD_ROUND_SEPARATOR)) return null

  const cardValue = value.split(ACTIVE_CARD_SEPARATOR)[0] || ''
  const roundId = cardValue.split(ACTIVE_CARD_ROUND_SEPARATOR)[1]

  return roundId || null
}

export function getActiveCardScannerName(value: string | null | undefined) {
  if (!value || !value.includes(ACTIVE_CARD_SEPARATOR)) return null

  const encodedName = value.split(ACTIVE_CARD_SEPARATOR)[1]

  if (!encodedName) return null

  try {
    return decodeURIComponent(encodedName)
  } catch {
    return encodedName
  }
}

export function getCardScanMessage(value: string | null | undefined) {
  const scannerName = getActiveCardScannerName(value)

  if (!scannerName) return 'Alguien ha escaneado una carta'

  return `${scannerName} ha escaneado una carta`
}
