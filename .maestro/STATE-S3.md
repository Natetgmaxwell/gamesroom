# STATE S3

STATE: step 1 of 8 done. Next: step 2.

BLOCKED: none

Notes for step 2:
- `Supabase/migrations/113_seat_flows.sql` written (NOT applied). New `release_seat(uuid, text)`, `claim_seat_with_deposit` and `upsert_event_rsvp` rebuilt with the `night_full` capacity guard (P0001, message `night_full`), `list_arrival_candidates` now only lists claimed RSVPs.
- Live bodies used: `docs/audit/2026-11-08/live-functions.sql`. Live `delete_event` and `update_event_played_at` authorise with `created_by OR is_room_host` already, so step 2 may only need `cancel_event` plus the `delete_event` body re-created with `is_room_host` and `set search_path`.
- Live `delete_event` has no `set search_path`; recreate it with `set search_path = public` when step 2 rewrites it.

Ticks are in .maestro/briefs/BRIEF-S3.md (tick the checkbox there too).
