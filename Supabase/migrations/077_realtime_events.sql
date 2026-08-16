-- 077: Realtime broadcasts for new events.
--
-- Product decision (V0.77, 2026-08-16): members learn about new
-- events via Supabase Realtime instead of relying on the host's
-- device to schedule their local notifications (which never left
-- the host's device — the old fan-out was architecturally dead).
--
-- The `supabase_realtime` publication currently contains NO tables
-- (verified live 2026-08-16), so no postgres changes were broadcast
-- to any client. This migration adds `public.events` to the
-- publication so INSERTs reach subscribed members in real time.
--
-- RLS is the load-bearing access control: the existing
-- `members can read events` SELECT policy scopes realtime delivery
-- to members of the room — a non-member subscriber receives nothing.

-- =================================================================
-- 1. Add public.events to the realtime publication
-- =================================================================
alter publication supabase_realtime add table public.events;

