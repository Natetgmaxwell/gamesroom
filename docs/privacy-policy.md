# Games Room — Privacy Policy

> **Status.** Drafted for the V0.8.1 TestFlight upload (Wave 0, 2026-08-06).
> Apple App Store Connect requires a reachable privacy-policy URL before a
> build can be uploaded. This document ships as the policy text and is
> rendered at `https://gamesroom.nateterrence.net/privacy` (per the V0.43
> website build).
>
> **Source of truth.** The data-handling claims below mirror
> `docs/legal-posture.md` and the operational reality of the V0.8 build —
> not marketing copy. If you find a claim that contradicts the live app,
> `docs/legal-posture.md` is the canonical reference; this file is the
> user-facing one.

Last updated: 2026-08-06

## What Games Room is

Games Room is a private games-night app for self-hosted tables. A host
creates a room with a six-character invite code; members join, the host
sets the rhythm (events, packs, seasons), and the room's mascot voices
the page with the personality and political ideology you picked at room
create.

We do not run a marketplace, a community, or a public feed. Every room
is invite-only. The app's job is to coordinate an in-person night — not
to be a social network.

## Data we collect

| Data | What it is | Why we collect it | Stored where |
|------|-----------|-------------------|--------------|
| Apple user identifier | The opaque id Apple returns from Sign in with Apple. | Identifies you across sessions. | Supabase `public.users.id`. We never see your email. |
| Display name | The name you choose to show in your rooms. | Lets members recognise each other in rooms. | Supabase `public.users.display_name`. |
| Per-room membership | Your role + join date + last-seen timestamp per room. | Drives the leaderboard, briefing trio, and access control. | Supabase `public.room_memberships`. |
| Per-room app activity | RSVPs, scores, season deltas, season awards, pack enablements. | The product surface — without it, the app has nothing to do. | Supabase `public.events`, `public.transactions`, `public.season_awards`, `public.room_packs`. |
| Notifications | Local notifications scheduled by the briefing trio (3×3 cadence × RSVP matrix). | Remind members about events they RSVPed to. | Local on your device. We do not send push notifications. |
| Per-room mascot API key | The OpenAI-compatible key you set in a room, if you set one. | Lets the mascot voice fan out per-event notifications in your voice. | Plaintext in `public.rooms.mascot_api_key` for the rooms that set it. Encryption-at-rest is a deferred item (V0.10+). |

## Data we do NOT collect

- Email addresses. Sign in with Apple hides them by default.
- Contact info, location, health data, browsing history, search history,
  purchase history, financial info.
- Identifiers beyond the Apple user id.
- Diagnostics or crash data — we do not run Firebase Crashlytics, Sentry,
  Bugsnag, or any other crash reporter. We do not run analytics
  (Mixpanel, Amplitude, PostHog, etc.).
- Third-party advertising SDKs. There are no ads.

## How we use your data

- To render the room you are a member of. Without the per-room
  membership, the app has no data to show.
- To enforce room-scoped access via Supabase Row Level Security. Every
  read of a room's data passes an RLS check that derives `room_id`
  from `events.id`. A user who is not a member of a room cannot read
  any of that room's data.
- To send notifications. Notifications are scheduled locally; they do
  not pass through any third-party push service.
- To generate mascot voice. When a room has a `mascot_api_key` set,
  the mascot notification body is generated via the configured
  OpenAI-compatible endpoint. We send the mascot's name, the room
  name, the event title, the venue, and the host's note — nothing
  else. No member PII leaves the device. No member display names
  leave the device. LLM generation falls back to a template on any
  failure (network error, timeout, invalid key, empty response).

## Data we share

We do not sell your data. We do not share it with advertisers. We do
not share it with analytics vendors.

The only data that leaves your device in any operational sense is:

1. **Reads and writes to Supabase**, scoped to the rooms you are a
   member of (enforced by RLS).
2. **Per-room mascot LLM calls**, made only when the room's host has
   configured a `mascot_api_key`. The host chooses to make those calls
   happen by setting the key. Members who do not want their room's
   mascot to call out to an LLM should ask the host to leave the key
   unset.

## Drowning awards — a specific note

The "Drowning" season-end award (migration 039 + 045) surfaces only
to the recipient by default. The host cannot see other members'
Drowning awards. A member can opt in to sharing their Drowning award
with the room; until they opt in, the row is invisible to everyone
except them. The opt-in default is `false` (privacy-respecting).

## Photos

The Casino pack supports per-member scanning of a chip-stack photo.
The default behavior is **discard the photo, keep the hash and the
vision snapshot** (F-CAS-03). The iOS app does not upload the original
photo. It uploads a hash and a vision-snapshot record (no image bytes).
A future version may add a photo-persistence opt-in; that opt-in will
be off by default.

## Your rights

- **Export.** You can ask for a copy of all data we hold about you.
  Email the address below.
- **Delete.** You can ask for your account to be deleted. Deletion
  cascades to your memberships, RSVPs, and per-room activity. Season
  award rows that name you are kept in their room (the room keeps its
  history) but the recipient display name is replaced with "Former
  member."
- **Correct.** You can change your display name in the in-app settings
  sheet.

## Children

The App Store age rating is 12+. We do not knowingly collect data from
children under 13. The "mild simulated gambling" age-rating trigger is
the Casino pack's virtual-chip withdrawal/return cycle, which is
virtual points only — not real currency.

## Data retention

- Per-room activity: kept for the life of the room. When a room is
  deleted, the activity cascades.
- RSVPs and event activity: kept for the life of the event. When an
  event is archived (V0.12 host-tools path), the activity is soft-
  deleted but the season-score deltas are preserved.
- Notifications: scheduled locally on your device; cleared when the
  event settles or you leave the room.

## Security

- Row Level Security on every table in `public.*`. There is no path
  to a room's data that does not pass through RLS.
- Apple Sign In is the only authentication mechanism. No passwords,
  no magic-link logins, no social logins.
- Supabase project `bnrgkdcluopicqdpmrtu`. Project dashboard is the
  operational source for the live database; we do not run a separate
  replica.

## International transfers

The Supabase project is hosted in the region its dashboard shows. If
you are accessing the app from outside that region, your data crosses
the public internet to reach the project. The connection is TLS 1.2+.

## Changes to this policy

We will update this policy when the data surface changes (a new
migration that adds a column with personally identifying implications,
a new SDK, a new LLM endpoint). The "Last updated" date at the top of
this document reflects the most recent change. Material changes will
also be flagged in the V0.x release notes.

## Contact

Email: the address published at `https://gamesroom.nateterrence.net` (the
games-room support page is at `https://gamesroom.nateterrence.net/support`).

## License

This policy text is licensed CC-BY-4.0. You may reuse the structure;
please write your own data-handling claims.
