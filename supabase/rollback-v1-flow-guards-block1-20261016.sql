BEGIN;

CREATE OR REPLACE FUNCTION public.activate_game_card(
  p_game_id uuid,
  p_session_id text,
  p_card_slug text
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
declare
  v_player record;
  v_card record;
  v_active_card_slug text;
begin
  select p.id, p.name, p.game_id
    into v_player
  from public.players as p
  where p.session_id = p_session_id
    and p.game_id = p_game_id
    and p.active = true
  limit 1;

  if not found then
    raise exception 'player_not_in_game';
  end if;

  select c.id, c.slug
    into v_card
  from public.cards as c
  where c.slug = p_card_slug
    and c.active = true;

  if not found then
    raise exception 'card_not_found';
  end if;

  update public.players as p
    set last_seen_at = now(),
        disconnected_at = null
  where p.id = v_player.id;

  v_active_card_slug :=
    v_card.slug || '::scanned_by::' || v_player.name;

  update public.games as g
    set active_card_slug = v_active_card_slug
  where g.id = p_game_id;

  return v_active_card_slug;
end;
$function$;

CREATE OR REPLACE FUNCTION public.clear_active_card_if_current(
  p_game_id uuid,
  p_session_id text,
  p_card_slug text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
declare
  v_player record;
begin
  select p.id, p.game_id, p.name
    into v_player
  from public.players as p
  where p.session_id = p_session_id
    and p.game_id = p_game_id
    and p.active = true
  limit 1;

  if not found then
    raise exception 'player_not_in_game';
  end if;

  update public.players as p
    set last_seen_at = now(),
        disconnected_at = null
  where p.id = v_player.id;

  update public.games as g
    set active_card_slug = null
  where g.id = p_game_id
    and split_part(
      split_part(
        coalesce(g.active_card_slug, ''),
        '::scanned_by::',
        1
      ),
      '::round::',
      1
    ) = p_card_slug;
end;
$function$;

CREATE OR REPLACE FUNCTION public.get_or_create_vote_round(
  p_game_id uuid,
  p_session_id text,
  p_card_slug text,
  p_round_id uuid DEFAULT NULL::uuid
)
RETURNS TABLE(
  id uuid,
  status text,
  tie_player_ids uuid[],
  card_id uuid
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
declare
  v_player record;
  v_card record;
  v_round record;
  v_next_round_number integer;
begin
  select p.id, p.game_id, p.name
    into v_player
  from public.players as p
  where p.session_id = p_session_id
    and p.game_id = p_game_id
    and p.active = true
  limit 1;

  if not found then
    raise exception 'player_not_in_game';
  end if;

  select c.id, c.slug
    into v_card
  from public.cards as c
  where c.slug = p_card_slug
    and c.active = true;

  if not found then
    raise exception 'card_not_found';
  end if;

  update public.players as p
    set last_seen_at = now(),
        disconnected_at = null
  where p.id = v_player.id;

  if p_round_id is not null then
    select
      vr.id,
      vr.status,
      vr.tie_player_ids,
      vr.card_id
      into v_round
    from public.vote_rounds as vr
    where vr.id = p_round_id
      and vr.game_id = p_game_id
      and vr.card_id = v_card.id;

    if not found then
      raise exception 'vote_round_not_found';
    end if;

    return query
      select
        v_round.id,
        v_round.status,
        v_round.tie_player_ids,
        v_round.card_id;

    return;
  end if;

  perform pg_advisory_xact_lock(
    hashtext(p_game_id::text || ':' || v_card.id::text)
  );

  select
    vr.id,
    vr.status,
    vr.tie_player_ids,
    vr.card_id
    into v_round
  from public.vote_rounds as vr
  where vr.game_id = p_game_id
    and vr.card_id = v_card.id
    and vr.status = 'voting'
  order by vr.created_at desc
  limit 1;

  if not found then
    select coalesce(max(vr.round_number), 0) + 1
      into v_next_round_number
    from public.vote_rounds as vr
    where vr.game_id = p_game_id
      and vr.card_id = v_card.id;

    insert into public.vote_rounds (
      game_id,
      card_id,
      round_number,
      status
    )
    values (
      p_game_id,
      v_card.id,
      v_next_round_number,
      'voting'
    )
    returning
      vote_rounds.id,
      vote_rounds.status,
      vote_rounds.tie_player_ids,
      vote_rounds.card_id
    into v_round;
  end if;

  return query
    select
      v_round.id,
      v_round.status,
      v_round.tie_player_ids,
      v_round.card_id;
end;
$function$;

COMMIT;
