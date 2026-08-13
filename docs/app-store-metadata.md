# Games Room — App Store metadata

> **Audience.** The TestFlight → App Store review pipeline. Filled
> in once M6.3 lands, validated by `xcrun altool --validate-app`
> in M6.5.

## App identity

| Field | Value |
|-------|-------|
| App name | **Games Room** |
| Subtitle (30 chars) | _Filled in M6.3 — vision brief §1 brand voice_ |
| Bundle id | `com.gamesroom.app` |
| Apple Developer Team | `37S7KT7W83` |
| Primary category | Social Networking |
| Secondary category | Entertainment |
| Age rating | 12+ (mild simulated gambling in the casino pack) |

## Description (~3700 chars)

> **Status.** Drafted in M6.3. Mirror to the App Store Connect
> "App Description" field once M6.5 uploads a TestFlight build.

[ TBD — fill in once the brand voice Q-TONE decision lands.
  Working draft:

> Games Room is a private games-night app for self-hosted
> tables. You bring your people — friends, family, your weekly
> poker group, your book club — and a host sets the rhythm.
> Four packs ship pre-installed: Casino, Cards Against
> Humanity, Monopoly Deal, and Pluto Chess. Seasons give each
> pack a score arc; the chapter title tracks the high water
> mark. The mascot voices the page with the personality and
> political ideology you picked at room-create, and the
> footer caption always answers "what just happened?" in
> one line.
>
> No ads. No analytics. No third-party SDKs. Sign in with
> Apple; we don't see your email. Six-character join codes
> keep every room invite-only. iPad renders the iPhone
> column centered — no stretched two-pane layouts.
>
> V0.8 is the connection-tested self-host model: the host
> sets up the room, the members show up, the mascot wraps
> the night. V0.9 ships Camera/Vision chip-scan and LLM
> mascot voice; V2 brings iPad split-view and the in-app
> pack store.

]

## Keywords (100 chars, comma-separated)

> games, poker, cards, monopoly, chess, mascot, social, table, invite, score

## Support URL

- **Required:** `https://gamesroom.nateterrence.net/support` (live —
  set up in V0.43).

## Privacy nutrition labels

The app uses:

- **Sign in with Apple** — user identifier only, no email capture.
- **Local `@AppStorage` / `UserDefaults`** — `lastViewedRoomIdString`
  for resume-to-room, plus sign-out cleanup.
- **Notifications** — `UserNotifications` for the 3×3 cadence ×
  RSVP matrix (event-create push, T-48h reminder, morning-of
  reminder). User can disable in Settings.
- **Supabase** — `supabase-swift` SDK, scoped to a per-room
  membership via RLS. No third-party analytics, no third-party
  crash reporting, no ad SDKs.

Per Apple App Store Connect's privacy nutrition label schema:

| Data type | Collected | Used for tracking | Linked to user |
|-----------|-----------|-------------------|----------------|
| User ID (Apple-provided) | Yes | No | Yes |
| App activity (in-app scores, RSVPs) | Yes | No | Yes |
| Notifications | Yes | No | N/A |

"Data not collected" applies to: contact info, financial info,
health info, location, sensitive info, contacts, browsing
history, search history, identifiers (other than the Apple
user id), usage data, diagnostics, purchases.

## Privacy policy URL

- **Required:** `https://gamesroom.nateterrence.net/privacy` (live —
  set up in V0.43. Must be reachable from a public web client.)

## Screenshot spec

Per App Store Connect (2026 spec), the screenshot sets are:

### iPhone 6.7" (iPhone 17 Pro) — required

| # | Surface | Why this surface |
|---|---------|------------------|
| 1 | **Create room** | Onboarding hero; sets the brand voice. |
| 2 | **Briefing slot** | Shows the seat grid + CTA. The 80/20/10 wash in action. |
| 3 | **Witness slot** | Casino pack's at-play screen with chip tray + Withdraw CTA. |
| 4 | **Ceremonial card** | The justSettled state — chapter title + delta. The display-serif voice. |
| 5 | **Awards card** | The seasonClose state — Drowning privacy-aware awards. |
| 6 | **Settings sheet** | The Social / Operations / Members split — proves the room settings discipline. |

### iPad 13" — required for Universal iPad apps

Same six surfaces, captured at iPad Pro 13" (M2). The iPhone
column renders centered with the black iPad margin — that's
the screenshot, not a stretched two-pane.

### Optional

- An animated `.aae` or QuickTime capture of the mascot footer
  caption transitioning across `.tonightEvent` → `.inPlay` →
  `.settleRound`. (App Store Connect supports up to 30 seconds
  of preview video per locale.)

## Export compliance

Per the App Store Connect export compliance questionnaire:

- **App uses encryption?** Yes (HTTPS via Supabase; no custom
  crypto).
- **Uses exempt encryption only?** Yes (TLS via standard
  Apple APIs; exempt per Apple guidelines — iOS standard
  networking).
- **Restricted-use encryption?** No.
- **Available on the French store?** Yes (no region-specific
  restrictions in V0.8).

## Trade compliance

- App is available worldwide in V0.8; no regional restrictions.
- Not subject to U.S. EAR encryption registration.

## Content rights

- App contains user-generated content (host notes, event
  titles). Per App Store guideline 5.2.3, the host is the
  responsible party; the app surfaces a "report this content"
  affordance in M6.5 if needed (TBD).

## Review notes (TestFlight → App Store)

When uploading the first TestFlight build, include:

- A short demo Apple ID (signed in via TestFlight Family
  Sharing) with at least one room created.
- The 6-character join code for that demo room.
- A read-only demo of the briefing slot → claim seat flow.

## What's deferred to V0.9

- LLM-driven mascot voice (`mascot_api_key` opt-in, default off).
- Camera/Vision chip-scan pipeline.
- Member-side event edit surface.
- Pack how-to guide bodies.
- Drowning privacy UI (schema-bound in V0.8; UI surface in V0.9).
- iPad split-view (intentionally collapsed to iPhone column in V0.8).