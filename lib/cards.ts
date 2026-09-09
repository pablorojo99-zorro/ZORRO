import { supabase } from '@/lib/supabase'

export function createCardSlugFromCode(code: string) {
  const cleanCode = code.trim()

  if (!/^\d{1,3}$/.test(cleanCode) || Number(cleanCode) === 0) return null

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
    .eq('active', true)
    .maybeSingle()

  if (error) {
    throw error
  }

  return !!data
}
