-- V0.8 pack catalog seed.
--
-- The V0.8 AddEventSheet picker exposes four pack slugs (Track A R6:
-- "Monetisation is constrained — 4 dev-curated packs, at least 2
-- must ship in v1"):
--
--   * casino                     — chip-based casino
--   * cards_against_humanity     — Cards Against Humanity
--   * monopoly_deal              — Monopoly Deal (card-based)
--   * pluto_chess                — Pluto Chess
--
-- Migration 012 seeded the V0.7 catalog (`monopoly-deal`, `blackjack`)
-- using the *hyphen* slug form. The V0.8 picker intentionally diverged
-- to the *underscore* slug form (per the AddEventSheet file header),
-- and the `create_event` RPC in 012 raises `'Unknown pack in
-- p_pack_slug'` (P0002) when the slug doesn't FK-resolve —
-- so every picker entry except the (literally-the-same-name-but-different-slug)
-- `monopoly_deal` was producing an error at event-create time.
--
-- This migration backfills the four V0.8 picker slugs and keeps the
-- V0.7 `monopoly-deal` and `blackjack` rows in place so any legacy
-- events written under the hyphen convention don't lose their FK on
-- the `events.pack_slug` reference (the column is `ON DELETE SET NULL`,
-- which would just null out broken refs anyway, but a kept row is
-- friendlier). Idempotent — re-applies clean on already-seeded DBs.
insert into public.packs (slug, display_name, description, scoring_type, win_points, withdraw_default) values
  ('casino',                  'Casino',                 'Chip-based casino games. Each player withdraws to start, returns winnings at end.',     'withdraw_return',  null, 10),
  ('cards_against_humanity',  'Cards Against Humanity',  'Card-judging party game. Winner is the round''s judge''s pick (single winner per round).', 'single_winner',   1,    null),
  ('monopoly_deal',           'Monopoly Deal',           'Card-based Monopoly. Winner takes the pot.',                                              'single_winner',   1,    null),
  ('pluto_chess',             'Pluto Chess',             'Chess-variant pack.',                                                                     'single_winner',   1,    null)
ON CONFLICT (slug) DO NOTHING;
