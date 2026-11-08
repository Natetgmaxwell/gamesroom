# S2B lane report: notif-server

Lane S2B on branch `s2b/notif-server`, based on `main` @ febbae3 (shipped 1.2.3).
Goal: server-side pieces so reminders reach members who never open the app,
server pushes land at waking hours, the Question Box waits for people to
arrive, and kicked members stop seeing events. Everything ships OFF and
unapplied.

## Steps (7 of 7, all committed)

| Step | Commit | What |
| --- | --- | --- |
| 1 | S2B.1 | `rooms.time_zone` (default Australia/Brisbane) + host-only `set_room_time_zone()` validated against `pg_timezone_names` |
| 2 | S2B.2 | `briefing_push_ledger`, `briefing_push_due()` with all slot kinds, skip rules and eligibility filters, `briefing-push-tick` cron every 15 min via pg_net |
| 3 | S2B.3 | briefing-push edge function: pure plan.ts copy composer (unit-tested), ledger insert before send, shared-secret gate fails closed, 200 no-op until `BRIEFING_PUSH_ENABLED=true` |
| 4 | S2B.4 | anchor push queues outside 09:00-20:00 room-local, `anchor-push-tick` delivers in the next window, never later than played_at - 24h, inviter re-checked at send, no hardcoded Australia/Brisbane |
| 5 | S2B.5 | Question Box opener waits for 3 arrivals or played_at + 30 min, arrival-based fallback rotation, stops when settled / past auto_close_hours / idle 60 min, skips readers with no active token |
| 6 | S2B.6 | events RLS read policy requires active membership, all four events policies keyed on `is_room_host()`; mascot-voice rewritten to a pure state.ts with 25 tests, reads the room's next unplayed night with the hidden filter, active-only roster facts |
| 7 | S2B.7 | docs/S2B_SERVER_PUSH.md rollout doc (apply order 108-112, secrets by name only, `--no-verify-jwt` deploys, 401 probe verification, dedupe plan) |

## Product-rule check

- Calendar maths for all briefing slots computes in the room's time zone.
- No push ever goes to the whole table: briefing sends to one user_id per row
  chosen by `briefing_push_due()`; anchor sends only to the explicit unseated
  inviter. Kicked members get no events row, no voice, no push.
- Copy tone handled in plan.ts: claimed messages are logistics only and never
  contain the word "claim" (case-insensitive test).

## Gates at close

- `bash .maestro/fastgate.sh --compile`: 302 cases passed, 0 failed; SwiftUI
  parse check pass=64 fail=0; final line FASTGATE: PASS.
- `deno check` clean on all four function directories this lane owns
  (briefing-push, anchor-nudge-push, mascot-voice, question-turn-push).
- `deno test`, 0 failed: briefing-push 31, anchor-nudge-push 22,
  question-turn-push 10, mascot-voice 25.
- Migrations 108-112 parsed with pglast and structurally checked (the 112
  checker also ran against 108-111 during earlier steps). 14 statements for
  112; drop/create sets exact, no `rooms.created_by` anywhere in the new SQL.
- Migrations written, never applied. No `supabase db push/query/link`, no
  deploys, no network calls to Supabase from this lane.

## Rollout

See docs/S2B_SERVER_PUSH.md. Apply order 108-112; set vault secrets
`briefing_push_secret` and `anchor_push_secret`; deploy `briefing-push` and
`anchor-nudge-push` with `--no-verify-jwt`; verify with an unauthenticated
probe expecting 401, then a signed probe expecting the disabled no-op; then
set `BRIEFING_PUSH_ENABLED=true`. Dedupe: when the server push lands, the
client stops scheduling local t168h/t48h/morning_of notifications; TARS wires
that flag at integration.

## Notes for TARS

- 109's tick reads the vault secret inside the tick and no-ops when it is
  missing, so applying the SQL changes nothing until the secret is set. Same
  fail-closed shape as 105/097.
- 112 moved the events INSERT policy from `rooms.created_by` to
  `is_room_host()` as well (the brief left it open): the insert policy had the
  same promoted-host defect as update/delete, and two guards that disagree is
  exactly what 095/106 stop. Reasoning is in the 112 header.
- mascot-voice now picks the room's NEXT UNPLAYED night (the live
  `get_active_event__inner` rule) when no explicit `event_id` is passed, with
  the hidden filter the live body lacked. A room whose next night is not yet
  created gets the "no events yet" welcome even with settled history; the
  between-nights and recap lines still fire when the footer passes the
  settled event's id, which is what it does on a settled night.
- One machine-local deno quirk fixed inside an allowed file: the
  `jsr:@supabase/supabase-js@2` import in mascot-voice/index.ts became the
  `https://esm.sh/@supabase/supabase-js@2` import the other three function
  dirs already use, because `jsr:` fails deno check on an empty npm cache.
  One line, no behaviour change.
