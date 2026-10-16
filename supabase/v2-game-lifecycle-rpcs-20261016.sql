-- Phase 2C V2: game and player lifecycle RPCs.
-- Requires v2-structural-schema-20261016.sql.

begin;

create or replace function public.create_game_with_host_v2(
  p_code text,
  p_host_session_id text,
  p_host_name text
)
returns table(game_id uuid, code text)
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_game record;
  v_code text := upper(trim(p_code));
  v_name text := trim(p_host_name);
begin
  if v_code !~ '^[A-Z2-9]{4}$' then
    raise exception 'invalid_game_code';
  end if;

  if length(coalesce(trim(p_host_session_id), '')) < 12 then
    raise exception 'invalid_session';
  end if;

  if length(v_name) < 1 or length(v_name) > 40 then
    raise exception 'invalid_player_name';
  end if;

  insert into public.games (
    code,
    status,
    host_session_id,
    current_round_number,
    flow_version
  )
  values (
    v_code,
    'lobby',
    p_host_session_id,
    0,
    2
  )
  returning id, games.code, games.flow_version
    into v_game;

  select g.id, g.code, g.flow_version
    into v_game
  from public.games as g
  where g.id = v_game.id
  for update;

  if not found or v_game.flow_version <> 2 then
    raise exception 'game_flow_version_mismatch';
  end if;

  insert into public.players (
    game_id,
    name,
    session_id,
    is_host,
    active,
    last_seen_at,
    disconnected_at
  )
  values (
    v_game.id,
    v_name,
    p_host_session_id,
    true,
    true,
    now(),
    null
  );

  return query select v_game.id, v_game.code;
end;
$function$;

create or replace function public.join_game_by_code_v2(
  p_code text,
  p_session_id text,
  p_name text
)
returns table(game_id uuid, code text)
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_game record;
  v_game_id uuid;
  v_code text := upper(trim(p_code));
  v_name text := trim(p_name);
  v_player_id uuid;
begin
  if length(coalesce(trim(p_session_id), '')) < 12 then
    raise exception 'invalid_session';
  end if;

  if length(v_name) < 1 or length(v_name) > 40 then
    raise exception 'invalid_player_name';
  end if;

  select g.id
    into v_game_id
  from public.games as g
  where g.code = v_code
  limit 1;

  if not found then
    raise exception 'game_not_found';
  end if;

  select g.id, g.code, g.flow_version
    into v_game
  from public.games as g
  where g.id = v_game_id
    and g.code = v_code
  for update;

  if not found then
    raise exception 'game_not_found';
  end if;

  if v_game.flow_version <> 2 then
    raise exception 'game_flow_version_mismatch';
  end if;

  select p.id
    into v_player_id
  from public.players as p
  where p.game_id = v_game.id
    and p.session_id = p_session_id
    and p.active = true
  order by p.created_at asc
  limit 1;

  if v_player_id is null then
    select p.id
      into v_player_id
    from public.players as p
    where p.game_id = v_game.id
      and p.session_id = p_session_id
      and p.active = false
    order by p.created_at desc
    limit 1;
  end if;

  if v_player_id is not null then
    update public.players as p
      set name = v_name,
          active = true,
          last_seen_at = now(),
          disconnected_at = null
    where p.id = v_player_id
      and p.game_id = v_game.id;
  else
    insert into public.players (
      game_id,
      name,
      session_id,
      is_host,
      active,
      last_seen_at,
      disconnected_at
    )
    values (
      v_game.id,
      v_name,
      p_session_id,
      false,
      true,
      now(),
      null
    );
  end if;

  return query select v_game.id, v_game.code;
end;
$function$;

create or replace function public.get_player_by_session_v2(
  p_session_id text,
  p_code text default null
)
returns table(
  player_id uuid,
  game_id uuid,
  name text,
  code text,
  is_host boolean
)
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_candidate record;
  v_game record;
begin
  if length(coalesce(trim(p_session_id), '')) < 12 then
    raise exception 'invalid_session';
  end if;

  select p.id, p.game_id
    into v_candidate
  from public.players as p
  join public.games as g on g.id = p.game_id
  where p.session_id = p_session_id
    and p.active = true
    and (
      p_code is null
      or g.code = upper(trim(p_code))
    )
  order by p.last_seen_at desc, p.created_at desc
  limit 1;

  if not found then
    return;
  end if;

  select g.id, g.code, g.flow_version
    into v_game
  from public.games as g
  where g.id = v_candidate.game_id
  for update;

  if not found then
    return;
  end if;

  if v_game.flow_version <> 2 then
    raise exception 'game_flow_version_mismatch';
  end if;

  return query
  with updated_player as (
    update public.players as p
      set last_seen_at = now(),
          disconnected_at = null
    where p.id = v_candidate.id
      and p.game_id = v_game.id
      and p.session_id = p_session_id
      and p.active = true
    returning p.id, p.game_id, p.name, p.is_host
  )
  select up.id, up.game_id, up.name, v_game.code, up.is_host
  from updated_player as up;
end;
$function$;

create or replace function public.heartbeat_player_v2(
  p_session_id text,
  p_game_id uuid
)
returns void
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_game record;
begin
  if length(coalesce(trim(p_session_id), '')) < 12 then
    raise exception 'invalid_session';
  end if;

  if p_game_id is null then
    raise exception 'game_id_required';
  end if;

  select g.id, g.flow_version
    into v_game
  from public.games as g
  where g.id = p_game_id
  for update;

  if not found then
    return;
  end if;

  if v_game.flow_version <> 2 then
    raise exception 'game_flow_version_mismatch';
  end if;

  update public.players as p
    set last_seen_at = now(),
        disconnected_at = null
  where p.session_id = p_session_id
    and p.game_id = v_game.id
    and p.active = true
    and p.last_seen_at < now() - interval '15 seconds';
end;
$function$;

create or replace function public.remove_player_from_game_v2(
  p_host_session_id text,
  p_player_id uuid
)
returns void
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_game record;
  v_host record;
  v_target record;
  v_target_game_id uuid;
begin
  select p.game_id
    into v_target_game_id
  from public.players as p
  where p.id = p_player_id
    and p.active = true;

  if not found then
    raise exception 'player_not_in_game';
  end if;

  select g.id, g.flow_version
    into v_game
  from public.games as g
  where g.id = v_target_game_id
  for update;

  if not found then
    raise exception 'player_not_in_game';
  end if;

  if v_game.flow_version <> 2 then
    raise exception 'game_flow_version_mismatch';
  end if;

  select p.id, p.game_id
    into v_target
  from public.players as p
  where p.id = p_player_id
    and p.game_id = v_game.id
    and p.active = true;

  if not found then
    raise exception 'player_not_in_game';
  end if;

  select p.id, p.game_id, p.is_host
    into v_host
  from public.players as p
  where p.session_id = p_host_session_id
    and p.game_id = v_game.id
    and p.active = true
  limit 1;

  if not found or v_host.is_host <> true then
    raise exception 'host_not_found';
  end if;

  if v_target.id = v_host.id then
    raise exception 'cannot_remove_self';
  end if;

  update public.players as p
    set active = false,
        disconnected_at = now()
  where p.id = v_target.id
    and p.game_id = v_game.id
    and p.active = true;
end;
$function$;

revoke all on function public.create_game_with_host_v2(text, text, text) from public;
revoke all on function public.join_game_by_code_v2(text, text, text) from public;
revoke all on function public.get_player_by_session_v2(text, text) from public;
revoke all on function public.heartbeat_player_v2(text, uuid) from public;
revoke all on function public.remove_player_from_game_v2(text, uuid) from public;

revoke all on function public.create_game_with_host_v2(text, text, text) from authenticated;
revoke all on function public.join_game_by_code_v2(text, text, text) from authenticated;
revoke all on function public.get_player_by_session_v2(text, text) from authenticated;
revoke all on function public.heartbeat_player_v2(text, uuid) from authenticated;
revoke all on function public.remove_player_from_game_v2(text, uuid) from authenticated;

grant execute on function public.create_game_with_host_v2(text, text, text) to anon;
grant execute on function public.join_game_by_code_v2(text, text, text) to anon;
grant execute on function public.get_player_by_session_v2(text, text) to anon;
grant execute on function public.heartbeat_player_v2(text, uuid) to anon;
grant execute on function public.remove_player_from_game_v2(text, uuid) to anon;

commit;
