import { supabase } from '@/lib/supabase'

export function createCardSlugFromCode(code: string) {
  const cleanCode = code.trim().replace(/\D/g, '')

  if (!cleanCode) return null

  return `carta-${cleanCode.padStart(3, '0')}`
}

export function getVisibleCardCode(slug: string) {
  const match = /^carta-(\d{3})$/.exec(slug)

  return match ? `V-${match[1]}` : null
}

export async function cardExists(slug: string) {
  const { data, error } = await supabase
    .from('cards')
    .select('id')
    .eq('slug', slug)
    .maybeSingle()

  if (error) {
    throw error
  }

  return !!data
}
