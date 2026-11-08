# Games Room 1.2.4 finish train: lane S4 (s4/finish)

Read this whole file at the start of EVERY iteration. Your progress lives in `.maestro/STATE-S4.md`.

## Where you are
- Repo = this worktree (cwd). Branch `s4/finish` is already checked out, based on `main` @ febbae3 (shipped 1.2.3). Four other lanes work in parallel on sibling branches; TARS integrates them. Never switch branch, merge, rebase, push, or touch `main` or any other worktree.
- Reference (read-only): `docs/audit/2026-11-08/` holds 00-SYNTHESIS.md, 01-notifications.md, 02-workflows.md, 03-spacing.md, 04-interconnect.md (findings with file:line on febbae3) and `live-functions.sql` (LIVE Postgres function bodies pulled 2026-11-08). **When you rewrite an RPC, start from its live body in live-functions.sql, never from an older migration.**

## Product rules (never violate)
- One primary action per screen; secondary actions are plain grey caption text centred under it.
- Optimistic UI + Undo instead of confirmation alerts. Destructive actions (cancel a night, forfeit/keep a deposit, leave a room, kick) DO confirm with a `confirmationDialog`.
- No chips, pills or decorative cards. Quiet by default. Never a push to the whole table.
- Copy: Australian spelling, no em dashes, no emojis, short and dry. Use the exact strings this brief gives.

## HARD RULES
1. **One step per iteration**: read STATE, do the NEXT unticked step only, run its gate, commit with the exact message given, tick it in STATE and rewrite the STATE line, commit STATE, EXIT.
2. **Allowed files** are listed below. New files only at the exact paths given. Never `git add` a name matching `* [0-9]*.*` (iCloud ghost copies): delete those instead.
3. **Gate per step**: `bash .maestro/fastgate.sh` must end with `FASTGATE: PASS`. The LAST step uses `bash .maestro/fastgate.sh --compile`. Never run `.maestro/gate.sh`, never boot a simulator, never run xcodebuild test: other lanes share this machine and TARS runs the full gate.
4. xcodegen dirties `GamesRoom.xcodeproj/project.pbxproj`: run `git checkout -- GamesRoom.xcodeproj/project.pbxproj` before every commit.
5. Tests: never delete or weaken an existing test. New Foundation-only logic goes in its own file under `GamesRoom/Services/` and MUST be added to `SRC_FILES` in `build-and-run-tests.sh`; its tests go in a new root file `TestsS4.swift`, also added to `SRC_FILES` and registered in `main.swift` the same way existing test groups are (grep main.swift for how a test function is registered before writing yours).
6. **Migrations: write them, NEVER apply them.** No `supabase db push/query/link`, no deploys, no network calls to Supabase. Every new SECURITY DEFINER function: `set search_path = public`, ends with `revoke all on function ... from public, anon;` and `grant execute on function ... to authenticated;`. Host checks use `public.is_room_host(<room_id>, public.current_user_id())`, never `rooms.created_by`. Every membership-derived query filters `membership_status = 'active'`. Changing a RETURNS TABLE shape needs `drop function if exists` first (42P13 otherwise); drop the wrapper before `__inner` and recreate both.
7. Never touch Maestro/opencode config or any process you did not start. If tooling misbehaves, note it in STATE and carry on.
8. Big files: `grep -n` for the anchor, then read about 80 lines around it. Never read RoomDetailView.swift (about 4,700 lines) whole.

## STOP AND REPORT (do not guess)
Write the question under `BLOCKED:` in STATE, commit STATE, exit, when:
- a live function body contradicts this brief;
- a fix needs a file outside ALLOWED FILES;
- an existing test fails for a reason unrelated to your change.

## Goal
Visual finish: one button geometry, one secondary style, one card shape, shared left edges, tokenised spacing, greys and radii, per `docs/audit/2026-11-08/03-spacing.md` (finding numbers below refer to it).

## Scope rule (important: four lanes edit the same views in parallel)
STYLING ONLY. Change modifiers (padding, spacing, font, foregroundStyle, frame, background, overlay, cornerRadius, buttonStyle, alignment) and replace literals with tokens. Do NOT change logic, state, conditions, strings, view order or file structure, and do not rename or move views. Keep each diff as small as possible.

## ALLOWED FILES
`GamesRoom/Theme.swift`, `GamesRoom/Views/**/*.swift` (styling only, per the scope rule), `GamesRoom/Views/Components/**`, `.maestro/STATE-S4.md`, `.maestro/S4_REPORT.md`. Not: Services, Models, Supabase, widgets/watch.

## Steps
- [ ] **1. Tokens + styles in Theme.swift.** Palette: `secondaryText = primaryText.opacity(0.55)`, `tertiaryText = primaryText.opacity(0.4)`, `labelText = primaryText.opacity(0.7)`, `bodyMuted = primaryText.opacity(0.8)`. Layout: `buttonVertical: CGFloat = 14`, `buttonRadius: CGFloat = 12`, `cardRadius: CGFloat = 12`, `smallRadius: CGFloat = 8`, `rowIconWidth: CGFloat = 28`, `fieldInset: CGFloat = 12`. `struct PrimaryButtonStyle: ButtonStyle`: full width, `Theme.Typography.body.weight(.semibold)`, `Palette.background` text on `Palette.accent`, vertical padding `buttonVertical`, radius `buttonRadius`, 0.85 opacity when pressed. `struct SecondaryTextAction: View` (title, action): caption font, `secondaryText`, centred, `frame(maxWidth: .infinity, minHeight: 44)`. sectionCard's radius reads `cardRadius`. Commit `S4.1: button, secondary-action, grey and radius tokens`.
- [ ] **2. Primary buttons.** Apply PrimaryButtonStyle at every site in #3 (Claim seat, I'm here, Re-accept, live CTA incl. its done state, Add an event becomes full width, Rooms Resume, empty-state CTA, reader Done) and the scan-sheet buttons (#21, #30). Commit `S4.2: one primary button`.
- [ ] **3. Secondary actions (#4).** Make `TrailingTextAction`'s body render like SecondaryTextAction (centred caption grey, no chevron) so its call sites stay unchanged; restyle "Make a call", the live-card extras (Withdraw more, Count your CAH cards, Score a round as secondary), reader Pass, member-note Skip, empty Rooms join secondary to SecondaryTextAction styling. Commit `S4.3: one secondary-action style`.
- [ ] **4. One card shape (#1, #2, #20).** BriefingSlot and WitnessSlot chrome (~:2070, ~:2683) -> `.sectionCard(isHero ? .hero : .standard)` or the existing equivalent; ArrivalCard: delete the extra `.padding(Theme.Layout.cardInset)` (~:133), drop the inner bordered box (rows separated by `Divider()`), header via `SectionTitle`, the grey subtitle becomes `.accessibilityHint`; QuestionBox host fallback -> sectionCard. Commit `S4.4: one card chrome; ArrivalCard single inset`.
- [ ] **5. Shared left edges (#5, #14, #23, #29).** Icon/rank columns `frame(width: Theme.Layout.rowIconWidth)` with `HStack(spacing: Theme.Layout.cardInset)` in standings, pack shelf, members, award rows, settings rows; Rooms list always reserves the live-dot column (clear when not live). Commit `S4.5: list text shares one leading edge`.
- [ ] **6. Rhythm (#6, #8-#13, #15-#18).** Replace the listed literals with roomSectionGap / roomHeaderGap / roomRowInset / cardLineGap / cardGroupGap exactly as each finding's Fix says; remove the `.padding(.top, 4)` bumps; SectionTitle for the five headers; Rooms page onto the room rhythm; empty Rooms single margin. Commit `S4.6: spacing on the two rhythms`.
- [ ] **7. Odd screens (#7, #19, #21, #22, #24, #30).** Live-card pills -> plain caption text; reader card margins `gutter`, question font `Theme.Typography.display` (add `displayLarge` Fraunces 34 if needed), spacing roomSectionGap; scan sheets margins edgePadding, stacks on tokens, `.multilineTextAlignment(.center)` on centred text, error colour `Palette.loss`, overlay from Palette; PackDetailView drop the duplicate name header; prefs sheets on tokens. Commit `S4.7: reader card, scan sheets, pack detail on the system`.
- [ ] **8. Greys and radii (#25, #26).** Map every `primaryText.opacity(x)` in Views: 0.5/0.55/0.6 -> secondaryText, 0.7 -> labelText, 0.75/0.78/0.8/0.85 -> bodyMuted, 0.28/0.3/0.4/0.45 -> tertiaryText. Radii 10/12/14 -> buttonRadius or cardRadius by context, 8 -> smallRadius; leave 2/2.5 bar radii and the exempt SeasonStatCardView. Commit `S4.8: greys and radii from tokens`.
- [ ] **9. Report.** `bash .maestro/fastgate.sh --compile`. Re-run the literal counts from 03-spacing.md's method and put before/after per file in `.maestro/S4_REPORT.md`. Commit `S4.9: report`.
