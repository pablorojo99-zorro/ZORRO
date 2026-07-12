-- Production hardening for ZORRO QR.
-- Review in Supabase SQL editor before running on an existing database.
-- The current client app reads public game data from the browser. These read
-- policies are transitional. For a stricter production model, move reads that
-- reveal players/votes behind RPCs that require a valid game code.

begin;

alter table public.cards enable row level security;
alter table public.games enable row level security;
alter table public.players enable row level security;
alter table public.vote_rounds enable row level security;
alter table public.votes enable row level security;

create unique index if not exists cards_slug_key on public.cards (slug);
create unique index if not exists games_code_key on public.games (code);
create unique index if not exists votes_one_vote_per_round_session_key
  on public.votes (vote_round_id, voter_session_id);

create index if not exists players_game_active_created_idx
  on public.players (game_id, active, created_at);
create index if not exists vote_rounds_game_card_status_created_idx
  on public.vote_rounds (game_id, card_id, status, created_at);
create index if not exists votes_round_idx
  on public.votes (vote_round_id);

drop policy if exists "cards are publicly readable" on public.cards;
create policy "cards are publicly readable"
  on public.cards
  for select
  to anon
  using (true);

drop policy if exists "games are publicly readable for the game flow" on public.games;
create policy "games are publicly readable for the game flow"
  on public.games
  for select
  to anon
  using (true);

drop policy if exists "players are publicly readable for the game flow" on public.players;
create policy "players are publicly readable for the game flow"
  on public.players
  for select
  to anon
  using (true);

drop policy if exists "vote rounds are publicly readable for the game flow" on public.vote_rounds;
create policy "vote rounds are publicly readable for the game flow"
  on public.vote_rounds
  for select
  to anon
  using (true);

drop policy if exists "votes are publicly readable for the game flow" on public.votes;
create policy "votes are publicly readable for the game flow"
  on public.votes
  for select
  to anon
  using (true);

-- Do not add anon insert/update/delete policies for games, players,
-- vote_rounds, or votes in production. Keep those mutations behind
-- SECURITY DEFINER RPCs or server-side code that validates:
-- - game code exists and is active
-- - card slug exists before active_card_slug is updated
-- - voter belongs to the game and is active
-- - voted player belongs to the same game
-- - voter is not voting for themselves
-- - tiebreak votes target only tie_player_ids
-- - result finalization happens only after all required voters voted

commit;
