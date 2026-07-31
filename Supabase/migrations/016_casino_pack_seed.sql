-- 016: Seed the casino pack into the catalog.
-- The iOS casino pack code shipped in V0.3 but the catalog row
-- was never inserted, so list_available_packs returns nothing
-- and users can't add it to a room. Idempotent.
insert into public.packs (slug, display_name, description, scoring_type, win_points, withdraw_default)
values (
  'casino',
  'Casino',
  'Chip-based. Players withdraw points, receive physical chips, scan at session end.',
  'withdraw_return',
  1,
  10
)
on conflict (slug) do nothing;
