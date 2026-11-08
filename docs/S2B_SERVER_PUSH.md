# S2B server push rollout

Lane S2B (branch `s2b/notif-server`). Everything below ships OFF and unapplied:
the five migrations are written but never applied to live, and the two new edge
functions deploy disabled until Nathan sets the vault and function secrets.

Copy for this doc: Australian spelling, no em dashes.

## What this lane changes

| Migration | What it does |
| --- | --- |
| 108_room_time_zone | `rooms.time_zone text not null default 'Australia/Brisbane'` plus host-only RPC `set_room_time_zone(uuid, text)` |
| 109_briefing_push | briefing push ledger, `briefing_push_due()` eligibility query, `briefing_push_cron_tick()` sends to briefing-push via pg_net, cron job `briefing-push-tick` every 15 min |
| 110_anchor_push_waking_hours | anchor nudge queues outside 09:00-20:00 room-local, cron job `anchor-push-tick` delivers queued rows in the next window (never later than played_at - 24h), re-checks the inviter at send time, room-local weekday |
| 111_question_box_timing | Question Box opener waits for 3 distinct arrivals or played_at + 30 min, arrival-based fallback rotation, stops when settled, past auto_close_hours, or idle 60 min, skips readers with no active device token |
| 112_events_rls_active | events read policy requires `membership_status = 'active'`; insert/update/delete policies move from `rooms.created_by` to `is_room_host()` |

Edge functions: `briefing-push` (new, ships disabled), `anchor-nudge-push`
(updated to waking hours), `mascot-voice` (updated to active-only reads plus
event selection that matches the live `get_active_event__inner` rule).

## Apply order

Apply in order 108, 109, 110, 111, 112. Later files depend on earlier ones:
109 and 110 read `rooms.time_zone` from 108; 112 rewrites policies that earlier
migrations do not touch, so it is safe last. Nothing applies twice poorly:
every migration is `create or replace` guarded or idempotent, but run each
exactly once in the order above:

```
psql "$GAMES_ROOM_DB_URL" -v ON_ERROR_STOP=1 -f Supabase/migrations/108_room_time_zone.sql
psql "$GAMES_ROOM_DB_URL" -v ON_ERROR_STOP=1 -f Supabase/migrations/109_briefing_push.sql
psql "$GAMES_ROOM_DB_URL" -v ON_ERROR_STOP=1 -f Supabase/migrations/110_anchor_push_waking_hours.sql
psql "$GAMES_ROOM_DB_URL" -v ON_ERROR_STOP=1 -f Supabase/migrations/111_question_box_timing.sql
psql "$GAMES_ROOM_DB_URL" -v ON_ERROR_STOP=1 -f Supabase/migrations/112_events_rls_active.sql
```

Rollback notes are in the header of each migration. 111's rollback restores the
097 bodies; 112's restores the previous events policies; 109/110 have drop
lines for their functions and cron jobs.

## Secrets

Set by Nathan, by name only. No agent ever reads a value.

Vault (Postgres, read by `briefing_push_secret()` and `anchor_push_secret()`):

| Vault secret name | Used by |
| --- | --- |
| `briefing_push_secret` | the 109 cron tick, sent as header `X-Briefing-Push-Secret` |
| `anchor_push_secret` | the 105 trigger and 110 ticks, sent as header `X-Anchor-Push-Secret` |

Edge function env (set per project, `supabase secrets set`):

| Name | Function | Effect |
| --- | --- | --- |
| `BRIEFING_PUSH_ENABLED` | briefing-push | `"true"` turns the sender on. Anything else keeps a 200 `{status:"disabled"}` no-op |
| `BRIEFING_PUSH_SECRET` | briefing-push | must equal the vault secret above, else 401 |
| `ANCHOR_PUSH_SECRET` | anchor-nudge-push | must equal the vault secret above, else 401 |
| `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_KEY_P8`, `APNS_BUNDLE_ID` | both push functions | reused from the existing question-turn-push setup, no new values |

The cron ticks read the vault secret themselves and no-op when it is missing,
so applying 109/110 does nothing until the vault secret exists. That is the
ship-closed design; the enabling act is setting the secret, not applying SQL.

## Deploy

Project ref `bnrgkdcluopicqdpmrtu`. `--no-verify-jwt` is required on both push
functions because the caller is pg_net with no user JWT; the shared-secret
header is the auth gate instead. `mascot-voice` is called by clients with a
user JWT and deploys normally.

```
supabase functions deploy briefing-push --no-verify-jwt --project-ref bnrgkdcluopicqdpmrtu
supabase functions deploy anchor-nudge-push --no-verify-jwt --project-ref bnrgkdcluopicqdpmrtu
supabase functions deploy mascot-voice --project-ref bnrgkdcluopicqdpmrtu
```

## Verify

1. Unauthenticated probe expects 401, which proves the function is deployed
   and the shared-secret gate fails closed:

```
curl -s -o /dev/null -w "%{http_code}\n" \
  -X POST "https://bnrgkdcluopicqdpmrtu.supabase.co/functions/v1/briefing-push"
# expect 401

curl -s -o /dev/null -w "%{http_code}\n" \
  -X POST "https://bnrgkdcluopicqdpmrtu.supabase.co/functions/v1/anchor-nudge-push"
# expect 401
```

2. With the vault secret set but `BRIEFING_PUSH_ENABLED` unset, a correctly
   signed probe returns 200 with `{"status":"disabled"}` and sends nothing.
3. After setting `BRIEFING_PUSH_ENABLED=true`, watch the next `*/15` tick:
   eligible slots appear in `briefing_push_cron_tick()` output and land in
   `briefing_push_ledger` before the send. Anchor queued rows deliver in the
   next 09:00-20:00 room-local window.

## Dedupe plan

Each briefing slot is computed on both clients and server today: the client
schedules local notifications for `t168h`, `t48h` and `morning_of` (plus the
on_create handoff) when a member opens the room; the server sends the same
kinds through briefing-push. Once the server push is on, the client stops
scheduling those three local slots. TARS wires that flag at integration: a
remote-config or build flag read at scheduling time, so both sides are never
sending the same slot. The ledger row keyed on
`(event_id, user_id, kind)` already prevents server-side repeats, but it
cannot see a client-scheduled local notification, hence the flag.
