# Games Room — TestFlight release notes

> **Build.** 0.1.0 (build 1). First TestFlight upload. Targets
> iOS 26+, iPhone + iPad Universal. Bundle id `com.gamesroom.app`.
>
> **Status.** Drafted in M6.5. The build + upload itself is
> blocked on a Mac+Xcode host (no iOS SDK on the current
> shell). Once the build is uploaded to App Store Connect, paste
> these notes into the TestFlight "What to Test" field.

## What to test

This is the V0.8 ship. The full feature surface is in
`docs/v0.8-vision-checklist.md` — this list is the **host's
walkthrough** so beta testers can verify the build behaves the
way the design intended.

### Onboarding (host)

1. **Create a room.** Pick a name, a mascot name, a personality
   (Stoic / Cheerful / Snarky / Scholarly / Salty), a political
   ideology (Trickster / Courtier / Sage / Saboteur / Populist),
   and a join starting bonus. Confirm the room shows up on the
   Rooms tab.
2. **Read the 6-character join code.** Tap the room → settings
   gear → copy the code. Send it to a test member.

### Onboarding (member)

3. **Join via code.** Tap "+ Join a room" on the Rooms tab, paste
   the code, accept the notification permission prompt.
4. **Verify the mascot footer caption.** The one-line italic
   caption at the bottom of the room page should answer "what
   just happened?" in your host's voice. Truncates with ellipsis
   if it's longer than the column width.

### The 10-state machine

For each of these states, verify: (a) the dominant action is
the single CTA, (b) the mascot footer caption is present.

5. **Briefing** — claim a seat. Two members minimum.
6. **Claimed** — RSVP "can't make it" if you can't play.
7. **Declined** — the row shows your decline.
8. **`.tonightEvent`** — play just started; the Withdraw CTA
   appears for the casino pack.
9. **`.inPlay`** — after one withdrawal, the chip tray shows up.
10. **`.settleRound`** — after host finalises, an attestation row
    is visible.
11. **`.justSettled`** — the Ceremonial card renders with a
    chapter title + delta (display-serif voice).
12. **`.readStandings`** — quiet state with the full board.
13. **`.seasonClose`** — set the current season to `.ended` in
    the InMemoryRoomStore seed (or wait for the next season to
    end). The awards card appears.

### Pack toggle

14. **Disable a pack** in the Operations sub-sheet. A
    `room_system_events` row fires and the `SystemBanner`
    surfaces above the standings.

### Score correction

15. **Correct a member's score** in the host scoring sheet.
    Their leaderboard row shows a 60-second amber dot
    (F-MVP-11).

### Seat deposits

16. **Set a seat deposit** in the Operations sub-sheet (e.g.
    50 pts). Claim a seat and verify the deposit is held;
    forfeit on decline.

## Known limitations (V0.8)

- The 4 packs ship pre-installed; the pack store shell lists them
  with installed state, but paid packs are not purchasable yet.
- Live Activity is a score surface only — suppressed during play
  per the vision non-goal.
- LLM mascot voice is opt-in via `mascot_api_key`; default is
  the 25-voice template interpolation.

## Known V0.8 bugs / sharp edges

- The `+ Add an event` CTA (B1.3) renders the host-only
  `chair.fill` toolbar item; if a beta tester reports a missing
  CTA, confirm they're signed in as the host (not a member).
- Migration numbering is not strictly monotonic (`037`, `038`,
  `042`, `043` are out-of-band). This is documented in
  `docs/deployment.md` — operators should not "fix" the gap.
- Widget / Watch / camera-scan surfaces are code-complete and
  wired end-to-end (App Group snapshot channel, per-target
  entitlements, Live Activity driver) but still require a manual
  device pass on an Xcode host (this machine has no Xcode.app —
  see `docs/roadmap-v0.9.md`).

## How to file a bug

- Tap the mascot footer caption in the affected room; the
  deep-dive bubble surfaces a "Send feedback" affordance
  (TBD in M6.5; defaults to opening Mail with the room id +
  screen name pre-filled).
- File the bug with the room id, the V0State case you were in,
  and a screenshot of the screen + the system banner (if any).

## What ships next (V0.9)

- Paid packs in the pack store (StoreKit).
- Season-subtitle mascot voice (the host-approval mechanism is
  in; the proposing voice is gated on the Q-TONE brand decision).
- Hybrid (on-device + cloud) vision fallback.
- Community-created packs (catalog v1, contribution v2).