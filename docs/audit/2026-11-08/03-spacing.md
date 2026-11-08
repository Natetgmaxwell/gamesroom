# 03 — Spacing & alignment audit (Games Room 1.2.3, studio `main` @ febbae3)

Read-only. Source read via `git archive febbae3` from `macstudio-tailnet:~/Projects/games-room` (no ghost dups present in the archive). Line numbers are febbae3.

## Token inventory (GamesRoom/Theme.swift)

| Token | Value | Notes |
|---|---|---|
| `Layout.gutter` | 32 | "outer column gutter" — but is used as an HStack icon→text gap in 4 list rows (see F5) |
| `Layout.cardInset` | 16 | applied by `sectionCard(_:)` (Theme.swift:256) |
| `Layout.edgePadding` | 16 | applied by `contentColumn()` (Theme.swift:282) |
| `Layout.sectionSpacing` | 24 | pre-S6 rhythm; still drives the Rooms list (F7) |
| `Layout.roomSectionGap` | 32 | room page section gap |
| `Layout.roomHeaderGap` | 8 | header → first row |
| `Layout.roomRowInset` | 12 | list row vertical inset |
| `Layout.cardLineGap` | 4 | lines that belong together |
| `Layout.cardGroupGap` | 16 | groups inside a card |
| `gridCellMin` 320, `scoringChipMin` 120/160 | | |
| `sectionCard` chrome | radius **12**, stroke **0.5** | Theme.swift:259-263 |

**Missing tokens** (cause of most literals): no grey/opacity scale (13 distinct `primaryText.opacity(...)` values in use — 0.28, 0.3, 0.4, 0.40, 0.45, 0.5, 0.55, 0.6, 0.7, 0.75, 0.78, 0.8, 0.85), no corner-radius token (9 distinct radii: 2, 2.5, 4, 8, 10, 12, 14, 16, 24), no primary-button token (vertical padding 10 / 12 / 14 and radius 10 / 12 / Capsule all in use for the full-width accent button).

## Findings

Classes: **TV** token violation · **DP** double padding · **AM** alignment mismatch · **XS** inconsistent cross-screen value.

### Room page (RoomDetailView.swift)

**1. ArrivalCard double inset — the fb2cd19 bug, still live on one caller.** High · DP · S
- Where: `ArrivalCard.swift:133` + caller `RoomDetailView.swift:586`
- Now: ArrivalCard body ends `.padding(Theme.Layout.cardInset)`; caller then applies `.sectionCard(.standard)` (which pads `cardInset` again, Theme.swift:256).
- Why: host's arrival card text sits 32pt in from the card edge; every other card sits 16. Exactly the defect fixed on settled+awards.
- Fix: delete `ArrivalCard.swift:133`.
- Also in the same card: a second bordered `RoundedRectangle(cornerRadius: 12)` list inside the sectionCard (`ArrivalCard.swift:54-68`) = card-in-card; header is a title-size icon+text (`:44-50`), not `SectionTitle`; grey explanatory subtitle under it (`:51-53`); body spacing `cardInset` (`:43`) should be `cardGroupGap`; candidate rows `spacing: 8` (`:75,85`). Fix: drop inner box (rows + `Divider()` only), `SectionTitle("Arrivals")`, move the explainer to `accessibilityHint`, spacings → `cardGroupGap`/`cardLineGap`. Effort M.

**2. Event card (BriefingSlot) and live card (WitnessSlot) draw their own chrome that doesn't match `sectionCard`.** High · XS · S
- Where: `RoomDetailView.swift:2070-2074` and `:2683-2687`
- Now: `.padding(Theme.Layout.cardInset).background(RoundedRectangle(cornerRadius: 14).fill(...).overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.Palette.hairline, lineWidth: 1)))`
- Why: the top card on the room page is radius 14 / 1pt stroke; Ceremonial, Awards, Withdrawals, SystemBanner, the Rooms hero are radius 12 / 0.5pt (`Theme.swift:259-263`). Two card shapes on one page, and the most prominent card has the heavier outline.
- Fix: replace both blocks with `.sectionCard(isHero ? .hero : .standard)` (same fill logic already exists in `Theme.SectionCard.background`).

**3. Primary button has four different geometries.** High · XS · S
- Where / now:
  - Claim seat `RoomDetailView.swift:1970-1972` — `.padding(.vertical, 12)`, radius 10
  - Check-in "I'm here" `:2045-2047` — `.padding(.vertical, 10)`, radius 10
  - Re-accept `:2115-2117` — vertical 12, radius 10
  - Live CTA `:2595,2607-2609` — vertical 14, radius 12; done-state `:2596-2598` is a `Capsule()`
  - Add an event `:1177-1180` — vertical 10 / horizontal 16, NOT full width, radius 10
  - Rooms "Resume" `RoomPage.swift:619-624` — vertical 12, radius 10, **text colour `primaryText` on accent** (every other primary uses `Palette.background`)
  - Empty-state CTA `RoomPage.swift:677-680` — vertical 14, `maxWidth: 320`
  - Reader card Done `QuestionBoxViews.swift:173-175` — vertical 14, radius 12
- Why: the one primary button changes height by 4-8pt and corner shape between card states (claimed → live is a visible jump), and Resume's text colour differs.
- Fix: add `Theme.Layout.buttonVertical = 14` (or 12, pick one), `Theme.Layout.buttonRadius = 12` and a `PrimaryButtonStyle` (full width, `Palette.background` text); apply at all 8 sites. Add-an-event becomes full width.

**4. Secondary actions: three competing styles, none consistently "plain grey centred under the primary".** High · AM/XS · M
- Where / now:
  - "Can't make it" `:1983-1992` — caption, 0.55, centred ✅ (the rule)
  - "Release my seat" `:2058` and "Re-decline" `:2119` — `TrailingTextAction` (`:2128-2148`): body font, 0.7, **trailing-aligned with chevron**
  - "Make a call" `:2806-2817`, `:2950-2961` — caption, 0.7, trailing with chevron
  - Live card "Withdraw more" / "Count your CAH cards" / "Score a round" `:2620-2680` — full-width **accent-outlined boxes** (`overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.Palette.accent))`)
  - Reader card "Pass" `QuestionBoxViews.swift:177-185` — equal-width outlined box beside Done
  - Empty Rooms "Ask a friend for a join code" `RoomPage.swift:685-692` — outlined box
  - Member note "Skip" `:3038-3043` — inline next to a small Send
- Why: the claimed card puts its secondary at the right edge in body/0.7, the unclaimed card centres it in caption/0.55 — same card, two styles, a one-tap state change moves the secondary across the card. Outlined secondaries on the live card compete with the primary (three boxes stacked).
- Fix: make `TrailingTextAction` the centred style (`Text(title).font(Theme.Typography.caption).foregroundStyle(primaryText.opacity(0.55)).frame(maxWidth: .infinity)`, no chevron) and use it at every site above; live-card extras become stacked centred grey text actions under the primary (host's "Score a round" stays primary only if it is the night's next action — see rubric "one next action").

**5. List rows on the room page don't share a leading text line.** High · AM · S
- Where / now:
  - Standings `Components/LeaderboardRow.swift:61,97` — rank `.frame(width: 24)` + `HStack(spacing: 12)` → name at x=36
  - Pack shelf `RoomDetailView.swift:3692-3696` — `HStack(spacing: Theme.Layout.gutter)` + icon `.frame(width: 32)` → name at x=64
  - Members `:4225-4231` — `HStack(spacing: Theme.Layout.gutter)` + 32pt avatar → x=64
  - Round history `:3558`, Notes `:2183`, Seasons rows (`Components/SeasonComparisonViews.swift:95-117`) — x=0
  - Screenshot evidence: `shots/04b-upcoming-scrolled-end_*.png` and `05-room-page-tonight-live_*.png` — Standings names start ~37pt right of the Seasons names directly below them.
- Why: scrolling the page, names jump between three left edges (0 / 36 / 64). `gutter` (32, the outer column margin) is being used as an icon gap — 32pt between a 32pt icon and its label is twice what any native list uses.
- Fix: icon→text gap = `Theme.Layout.cardInset` (16) in packRow/memberRow (puts text at 48); optionally add `Theme.Layout.rowLeadingColumn = 32` and give Standings' rank the same 32 width so names in Standings, Packs and Members all start at 48.

**6. AwardsCard rhythm: wrong token + ad-hoc `.padding(.top, 4)` bumps.** Med · TV · S
- Where: `RoomDetailView.swift:3191` `VStack(alignment: .leading, spacing: Theme.Layout.cardInset)`; `:3192` `spacing: 4`; `:3207`, `:3237`, `:3244` `.padding(.top, 4)`; `:3218` `.padding(.vertical, 4)`
- Why: groups sit 20 apart (16+4) instead of 16, the awards list 20/20; `cardInset` is an inset token used as a gap. fb2cd19 fixed this card's inset but not its rhythm.
- Fix: `spacing: Theme.Layout.cardGroupGap`, inner `spacing: Theme.Layout.cardLineGap`, delete all four `.padding(.top/.vertical, 4)`.

**7. Live card (WitnessSlot) carries pills/chips.** Med · TV · S
- Where: `RoomDetailView.swift:2532-2540`, `:2545-2553` — `.padding(.horizontal, 10).padding(.vertical, 6).background(Theme.Palette.accent.opacity(0.12)).clipShape(Capsule())` ("Counted…", "Working hand…"); `:2577` attestation rows `.padding(.vertical, 6)` (not `roomRowInset`); `:2568` `HStack(spacing: 8)`.
- Why: locked "no chips/pills"; the pill's 10pt inner padding also pushes its text 10pt right of the title's leading edge.
- Fix: plain `Text` in caption/accent with the icon, no background/padding; attestation rows `.padding(.vertical, Theme.Layout.roomRowInset)` with `Divider()` between, or `cardLineGap` spacing.

**8. Header styles: five non-`SectionTitle` headers on the room page.** Med · XS · S
- Where / now:
  - Empty standings `:1136-1139` — `Text(isHost ? "No nights on the books yet" : "Standings").font(Theme.Typography.title)` + grey subtitle `:1141-1143` + `spacing: 12`
  - HostWithdrawalsSection `:3431-3438` — icon + `Typography.title` "Chips to dispense"
  - ArrivalCard `ArrivalCard.swift:44-50` — icon + `Typography.title` "Arrivals"
  - Tonight's Star `:2946-2948` — caption/0.55 label (not semibold/0.7)
  - Rooms list "Continue" eyebrow `RoomPage.swift:586-588` — footnote/accent
- Why: "one header style for every section"; these read as three different hierarchy levels.
- Fix: `SectionTitle(text:)` + `.padding(.bottom, Theme.Layout.roomHeaderGap)` for withdrawals/arrivals/empty-standings; grey subtitles → `accessibilityHint`. Tonight's Star: `SectionTitle`. Empty standings `spacing: 12` → `cardGroupGap`.

**9. Claimed state: explainer text sits a group-gap away from the button it explains.** Med · TV · S
- Where: `RoomDetailView.swift:2035-2049` inside `VStack(spacing: Theme.Layout.cardGroupGap)` (`:1996`)
- Now: "Tap when you walk in…" caption and the "I'm here" button are siblings 16 apart.
- Fix: wrap caption+button in `VStack(alignment: .leading, spacing: Theme.Layout.cardLineGap)` (or `roomHeaderGap` 8).

**10. Member-note prompt & declined state: off-scale literals and a mini-button.** Med · TV · S
- Where: `MemberNotePromptSection` `:3012` `spacing: 8`, `:3025` `.padding(8)`, `:3026` radius 8, `:3027` `HStack(spacing: 12)`, Send `:3032-3035` `.padding(.horizontal, 12).padding(.vertical, 6)` radius 8; `V0StateReEntryPills` `:2106` `spacing: 8`.
- Fix: VStack `cardGroupGap`; field padding `cardInset/2`→ define `Theme.Layout.fieldInset = 12` and reuse in `ClaimedCardAskField` (`QuestionBoxViews.swift:104-106`, which uses 10/8 — another value); Send = `PrimaryButtonStyle`, Skip = centred grey text; declined VStack `cardGroupGap`.

**11. SystemBanner rows have no row inset.** Low · TV · S
- Where: `RoomDetailView.swift:3365` `VStack(spacing: 8)` with `Divider()`s; `:3367` `HStack(spacing: 10)`; `:3371` `spacing: 2`.
- Why: hairlines sit 4pt from text on each side; every other list uses `roomRowInset` (12).
- Fix: `spacing: 0`, rows `.padding(.vertical, Theme.Layout.roomRowInset)`, `HStack(spacing: Theme.Layout.cardInset)`, inner `cardLineGap`.

**12. Inner line gaps of 2 / 3 / 6 everywhere instead of `cardLineGap` (4).** Low · TV · S
- Where (sample): seat cells `:2319,:2353` `VStack(spacing: 3)`; AwardRow `:3320` `spacing: 2`, `:3321` `HStack(spacing: 6)`, `:3341` `.padding(.vertical, 8)`; Round history `:3558` `spacing: 6`; HostWithdrawals row `:3452` `spacing: 2`; pack/member rows `:3697,:4237` `spacing: 2`; LeaderboardRow `:63` `spacing: 2`, `:64` `spacing: 6`, `:102` `spacing: 10`; TonightStar `:2945` `spacing: 4`, `:2965` `spacing: 6`.
- Fix: two-line rows → `cardLineGap`; icon↔label HStacks → `cardLineGap`; AwardRow vertical → `roomRowInset`.

**13. Leaderboard expanded sparkline double-pads.** Low · DP · S
- Where: `Components/LeaderboardRow.swift:49-50` `.frame(height: 32).padding(.vertical, Theme.Layout.cardInset)` inside a row already padded `roomRowInset` (`:55`).
- Why: expanding a row adds 32+32=64pt of air around a 32pt trace.
- Fix: `.padding(.top, Theme.Layout.cardLineGap)`, no bottom.

### Rooms list (RoomPage.swift)

**14. Rooms list rows: name shifts right when the room is live.** High · AM · S
- Where: `RoomPage.swift:469-481` — `HStack(spacing: Theme.Layout.gutter) { if active { Circle().frame(width: 8, height: 8) } VStack {...} }`
- Why: a live room's name starts at 56 (8 + 32 gap), others at 16 — names in one list on two left edges, and the dot floats 32pt away from its label.
- Fix: always reserve the dot column: `Circle().fill(active ? accent : .clear).frame(width: 8, height: 8)` and `HStack(spacing: Theme.Layout.cardLineGap * 2)` (8) — or drop the dot to a trailing position.

**15. Rooms page still on the pre-S6 24pt rhythm, header 24 above its list.** Med · XS · S
- Where: `RoomPage.swift:458` `VStack(alignment: .leading, spacing: Theme.Layout.sectionSpacing)`; `:526` `.padding(.vertical, Theme.Layout.sectionSpacing)`; rows `:503` `.padding(.vertical, Theme.Layout.cardInset)`.
- Why: "Your rooms" sits 24 above its list (room page: 8); hero→header 24 (room page: 32); rows inset 16 (room page: 12). First screen of the app reads on a different grid from the room page.
- Fix: outer VStack `spacing: Theme.Layout.roomSectionGap`, wrap header+list in `VStack(spacing: Theme.Layout.roomHeaderGap)`, rows `roomRowInset`. Replace `sectionHeader` (`:637-648`) with `SectionTitle` (identical style today, but duplicated code).

**16. "Continue" hero: every line 16 apart.** Med · TV · S
- Where: `RoomPage.swift:585` `VStack(alignment: .leading, spacing: Theme.Layout.cardInset)`; `:604` `HStack(spacing: 8)`
- Why: eyebrow, title and status line belong together but are spaced as groups.
- Fix: inner `VStack(spacing: Theme.Layout.cardLineGap)` for eyebrow/title/status, outer `cardGroupGap` before Resume.

**17. Empty Rooms state: double horizontal margin.** Med · DP · S
- Where: `RoomPage.swift:698-699` `.padding(.horizontal, Theme.Layout.edgePadding).contentColumn()` (contentColumn already pads `edgePadding`, Theme.swift:282); subhead `:665` adds `.padding(.horizontal, Theme.Layout.gutter)` → text inset 64; buttons `maxWidth: 320` (`:677,:689`); `.padding(.top, 8)` `:683`.
- Fix: delete `:698`; drop `:665`; buttons full width of the column; delete `:683` (stack spacing already `cardInset`; use `cardGroupGap`).

**18. iPad sidebar "App Settings" row: gutter as icon gap, 12 literal.** Low · TV · S
- Where: `RoomPage.swift:337` `HStack(spacing: Theme.Layout.gutter)`, `:353` `.padding(.vertical, 12)`.
- Fix: `spacing: Theme.Layout.cardInset`, `.padding(.vertical, Theme.Layout.roomRowInset)`.

### Sheets, scan flows, Question Box

**19. Question reader card (full-screen) is fully off-system.** Med · TV/XS · S
- Where: `QuestionBoxViews.swift:141` `spacing: 24`; `:151` `.font(.system(size: 34, weight: .semibold, design: .serif))`; `:167` `HStack(spacing: 12)`; `:189` `.padding(28)`; Pass outlined box `:183-184`.
- Why: 28pt margin exists nowhere else (room 16, scan sheets 32); New York serif at 34 is not the app's display face (`Typography.display` = Fraunces 28) — two serifs in one app.
- Fix: `.padding(Theme.Layout.gutter)` (32, matches scan sheets) or `edgePadding`; question `Theme.Typography.display` (add `displayLarge = Font.custom("Fraunces", size: 34)` if 28 is too small at table distance); spacing `roomSectionGap`; Pass → centred grey text under Done.

**20. Host question fallback: hand-rolled card with 1pt stroke.** Low · XS · S
- Where: `QuestionBoxViews.swift:230-236` `.padding(Theme.Layout.cardInset).background(RoundedRectangle(cornerRadius: 12).fill(surface).overlay(RoundedRectangle(cornerRadius: 12).stroke(hairline)))` (default lineWidth 1); `:212-213` spacing 6.
- Fix: `.sectionCard(.standard)`; spacings `cardLineGap`.

**21. Scan sheets (Chips, CAH) use their own margins and steps.** Med · XS · M
- Where: `ChipScanSheet.swift:119` `spacing: 16`, `:129` `12`, `:146` `8`, `:143/178/231/237/249` `.padding(.horizontal, Theme.Layout.gutter)`, `:179` `.padding(.bottom, 24)`, `:203` `.padding(24)`, `:232-233` `.padding(.top, 24)`/`.padding(.bottom, 12)`, buttons `:171-173,:272-274` `.padding(.vertical, 16)` radius **8**; `CAHCardScanSheet.swift:92,102,119,144-146,151,175,196-197,226-228,239-240,245-246` same pattern.
- Why: 32pt horizontal margin vs 16 on the room page and the Form inset on settings sheets; buttons 16-tall radius 8 = a fifth button geometry; dark overlay `Color.black.opacity(0.45)` (`ChipScanSheet.swift:138`, `CAHCardScanSheet.swift:111`) outside Theme.
- Fix: `.padding(.horizontal, Theme.Layout.edgePadding)` (or keep `gutter` and document "full-screen flows use gutter"), stacks `cardGroupGap`/`cardLineGap`, top/bottom `roomSectionGap`, buttons → `PrimaryButtonStyle`, overlay → `Theme.Palette.background.opacity(…)` token.

**22. PackDetailView: name shown twice, title-size headings stacked.** Low · TV · S
- Where: `PackDetailView.swift:42` `.navigationTitle(pack.displayName)` + header `:61-63` `Text(pack.displayName).font(Theme.Typography.title.weight(.semibold))`; headline `:75-76` also `Typography.title`; `:58` `.font(.system(size: 36))` icon; `:27` `spacing: Theme.Layout.cardInset`; `:94` `.padding(.top, 4)`; `:55` `HStack(spacing: 12)`.
- Fix: drop the header name (nav title carries it) or set nav title inline-empty; outer `cardGroupGap`, delete `:94`; icon `Theme.Typography.title` scaled via `.imageScale(.large)`.

**23. Form-row icon column widths differ between settings screens.** Low · XS · S
- Where: `RoomSettingsSheet.swift:353,:612` `.frame(width: 28)`; `PackStoreView.swift:74` `.frame(width: 32)`; `RoomSettingsSheet.swift:1372` `.frame(width: 32, height: 32, alignment: .trailing)`; `Components/DrowningBadge.swift:102,110` `.padding(.leading, 28) // align under the row text`; row padding `.padding(.vertical, 4)` (`RoomSettingsSheet.swift:368,623`, `PackStoreView.swift:91`).
- Fix: one `Theme.Layout.rowIconWidth = 28` used everywhere (DrowningBadge's 28 then derives from it instead of a magic number).

**24. RoomNotificationPrefs / MemberCalendarSettingsSheet: in-Form custom stacks on 6/10/20.** Low · TV · S
- Where: `RoomNotificationPrefs.swift:41` `spacing: 10`, `:48` `HStack(spacing: 20)`, `:164` `spacing: 6`, `:38` `.padding(.top, 2)`; `MemberCalendarSettingsSheet.swift:245` `spacing: 6`, `:244` `.padding(.top, 2)`, `:171` `Color.red.opacity(0.85)` (should be `Theme.Palette.loss`).
- Fix: `cardLineGap` / `cardGroupGap`; `Palette.loss`.

**25. Grey has no tokens: 13 opacity levels of `primaryText`.** Med · TV · M
- Where: app-wide — counts: 0.55 ×102, 0.7 ×22, 0.4 ×13 (+1 written `0.40` at `RoomPage.swift:645`), 0.8 ×7, 0.6 ×6, 0.3 ×4, 0.45 ×2, 0.85/0.78/0.75/0.5/0.28 ×1 each.
- Why: "type scale, weight and grey only" needs a grey scale; e.g. Round history losing delta 0.6 (`RoomDetailView.swift:3578`) vs Standings loss 0.55; seat initials 0.75 vs 0.7 (`:2322,:2326`).
- Fix: `Theme.Palette.secondaryText = primaryText.opacity(0.55)`, `tertiaryText = 0.4`, `labelText = 0.7` (SectionTitle, secondary actions), `bodyMuted = 0.8`; map 0.5/0.6 → 0.55, 0.75/0.78/0.85 → 0.8, 0.28/0.3/0.45 → 0.4.

**26. Corner radii: 9 values, no token.** Low · XS · S
- Counts: 12 ×23, 10 ×13, 8 ×13, 14 ×4, 2/2.5 ×2 each (bars), 4, 16, 24 (share card) ×1.
- Fix: `Theme.Layout.cardRadius = 12`, `controlRadius = 10` (buttons/fields — or 12 to match cards), `smallRadius = 8`; 14 disappears with F2.

### Widgets / Watch / share card (lower priority)

**27. Widget & Watch use system greys and literal spacing.** Low · XS · S
- Where: `GamesRoomWidgets/GamesRoomWidgets.swift:75` `spacing: 6`, `:126` `spacing: 4`, `:83,:87` `.foregroundStyle(.secondary)`, `:92` `.tertiary`; `GamesRoomWatch/GamesRoomWatchApp.swift:52` `spacing: 6`, `:62` `.secondary`, `:65` `.padding()`.
- Note: `.secondary` is right for widgets (vibrancy/tint modes), so only the spacing → `cardLineGap` is a real fix. Verified: the widget target sources only `GamesRoomWidgets/` (project.yml:147-148) and no widget/watch file references `Theme.`, so tokens would need adding Theme.swift to those targets first.

**28. SeasonStatCardView (share image) — exempt by design.** Info
- `SeasonStatCardView.swift:24-27` own palette, 9 × `.font(.system(size:…, design: .rounded))`, `.padding(24)`/`(16)`/`.padding(.bottom, 20)`. It is a rendered export with its own brand palette; leave, but if it should match the app, it needs a separate pass.

### Clean
`AddEventSheet`, `EditEventSheet`, `CreateRoomSheet`, `JoinRoomSheet`, `AppSettingsView`, `SettingsPage`, `WithdrawChipsSheet`, `ScanCameraView` have 0 literal spacing/padding/radius values (native `Form` layout); only stray opacity greys (1-3 each).

### Found from screenshots (then confirmed in code)

**29. Award rows: recipient names don't line up.** Med · AM · S
- Where: `RoomDetailView.swift:3313-3318` — `HStack(spacing: 12) { Image(systemName: symbol).font(Theme.Typography.body) ... }` with no fixed icon width.
- Evidence: `shots/14-awards-ceremonial-card_*.png` — "Felty" (flame icon) starts ~4pt left of "Borat" (cluster icon).
- Fix: give the icon `.frame(width: Theme.Layout.rowIconWidth)` (28, new token from F23) and set the row `HStack(spacing: Theme.Layout.cardInset)`; inset the row divider by the same 28+16 so it starts under the text.

**30. Chip-scan sheet: wrapped caption is left-aligned inside a centred stack, and the button text is white.** Med · AM/XS · S
- Where: `ChipScanSheet.swift:146-149` — `VStack(spacing: 8) { Text("Settling your Casino hand, …")` (no `.multilineTextAlignment(.center)`); `:167-173` `.foregroundStyle(.white)` / `.weight(.medium)` / `.padding(.vertical, 16)` / radius 8; `:159` `.red.opacity(0.85)`. Same block in `CAHCardScanSheet.swift:119-146`.
- Evidence: `shots/11-casino-chip-scan-sheet_*.png` — the orange two-line caption hangs from a left edge ~7pt inside the button's edge while the two lines below are centred.
- Fix: `.multilineTextAlignment(.center)` on all three texts; button → `PrimaryButtonStyle` (`Palette.background` text, semibold); error → `Theme.Palette.loss`.

**31. Reader card buttons side-by-side; 28pt margins.** (confirms F19) — `shots/10-question-box-reader-card_*.png`: question in system New York serif, not Fraunces; Done/Pass are equal-weight halves; content inset 28pt, which matches nothing else.

## Screenshot sweep (fresh, febbae3)

- Ran in a detached worktree `/tmp/gr-audit-0811` on the studio (ghost dups deleted, gitignored `Config.xcconfig` copied in, xcodegen). **Xcode.app (27.2) could not run simulators** ("CoreSimulator is out of date … 1171.7.0 older than 1174.21.0"), so the sweep ran on **`/Applications/Xcode-beta.app` = Xcode 27.0 (27A5252f)**, the same toolchain `.maestro/gate.sh` uses, on **iPhone 17 Pro**. `** TEST SUCCEEDED **`, ~3 min.
- 22 PNGs in `shots/` (named from manifest.json; raw .txt attachments kept). Worktree removed afterwards; studio main still clean @ febbae3.
- Vision-checked: 01, 04, 04b, 05, 06, 10, 11, 14. Not individually inspected: 02, 03, 07-09, 12, 13, 15-18.
- Visually confirmed: F3 (button heights/radii differ: Claim seat vs Withdraw to play vs Scan chips), F4 (trailing "Make a call ›" in 06 vs centred "Can't make it" in 04; outlined "Pass" and "Ask a friend…"), F5 (Standings vs Seasons leading edges), F17 (empty Rooms buttons ~41pt in from the edge vs title 16pt), F19, F29, F30.
- Not visible in the sweep (state not seeded): ArrivalCard double inset (F1), HostWithdrawals, live-card pills (F7), Rooms list with an active-room dot (F14) — those rest on code reading only.

## Ranked top 5

1. **F4 — one secondary-action style** (centred grey caption). Most visible inconsistency; it flips position within a single card on one tap. M.
2. **F3 — `PrimaryButtonStyle` token** (one height, radius, text colour). 8+ call sites, fixes Resume's white-on-brass and the white "Scan chips". S.
3. **F5 + F14 + F29 — one leading text line for every list** (icon column 28, gap 16, reserve the dot column). Fixes the left-edge zig-zag down the room page and Rooms list. S.
4. **F2 + F1 — one card chrome**: event/live cards onto `sectionCard`, delete ArrivalCard's extra inset and inner box. S.
5. **F25 + F26 — grey + radius tokens**, then F6/F15/F16 rhythm fixes ride on them. M.

## Literal-value count per file (febbae3)

`spacing: <n>` · `.padding(<n>)`/`.padding(.edge, <n>)` · `.system(size:)` · `cornerRadius: <n>` · `opacity(<n>)` (all colours) · `.frame(w/h: <n>)`. Not every literal is a defect (icon frames, sparkline heights, `spacing: 0`), but every one is off-token.

| File | spacing | padding | sysFont | radius | opacity | frame |
|---|---|---|---|---|---|---|
| RoomDetailView.swift | 41 | 34 | 0 | 16 | 60 | 6 |
| Components/SeasonComparisonViews.swift | 15 | 6 | 0 | 3 | 15 | 9 |
| ChipScanSheet.swift | 12 | 9 | 1 | 5 | 10 | 1 |
| QuestionBoxViews.swift | 10 | 5 | 1 | 5 | 8 | 0 |
| CAHCardScanSheet.swift | 8 | 8 | 0 | 5 | 7 | 0 |
| RoomSettingsSheet.swift | 7 | 3 | 1 | 0 | 20 | 3 |
| RoomPage.swift | 7 | 5 | 0 | 5 | 13 | 5 |
| RoomNotificationPrefs.swift | 7 | 1 | 0 | 0 | 6 | 0 |
| HostScoringDashboard.swift | 7 | 3 | 0 | 6 | 10 | 6 |
| Components/LeaderboardRow.swift | 6 | 0 | 0 | 0 | 4 | 4 |
| Components/SeatGridView.swift | 5 | 0 | 0 | 2 | 8 | 0 |
| Components/DrowningBadge.swift | 5 | 3 | 0 | 0 | 6 | 0 |
| PackDetailView.swift | 4 | 1 | 1 | 0 | 4 | 0 |
| Components/SessionRoundTimeline.swift | 4 | 4 | 0 | 1 | 6 | 2 |
| ArrivalCard.swift | 4 | 6 | 0 | 5 | 1 | 0 |
| SeasonStatCardView.swift (exempt share image) | 3 | 8 | 9 | 2 | 5 | 1 |
| HostScoreEntrySheet.swift | 3 | 3 | 0 | 2 | 3 | 1 |
| GamesRoomWidgets.swift | 2 | 0 | 0 | 0 | 1 | 0 |
| MemberCalendarSettingsSheet.swift | 2 | 1 | 0 | 0 | 6 | 0 |
| MascotFaceView.swift | 2 | 0 | 0 | 0 | 7 | 1 |
| Components/MascotConfigSection.swift | 2 | 1 | 0 | 0 | 1 | 0 |
| GamesRoomWatchApp.swift | 1 | 0 | 0 | 0 | 0 | 0 |
| PackStoreView.swift | 1 | 1 | 0 | 0 | 2 | 1 |
| Components/TrajectorySparkline.swift | 1 | 0 | 0 | 0 | 0 | 6 |
| Components/MascotBubble.swift | 1 | 0 | 0 | 0 | 1 | 0 |
| Components/ConfettiBurst.swift | 0 | 0 | 0 | 1 | 0 | 1 |
| CreateRoomSheet / WithdrawChipsSheet / JoinRoomSheet / EditEventSheet / AddEventSheet | 0 | 0 | 0 | 0 | 3/2/1/1/1 | 0 |
| AppSettingsView / SettingsPage / ScanCameraView / Haptics | 0 | 0 | 0 | 0 | 0 | 0 |
| **Total (grep over all files)** | **160** | **102** | **13** | **58** | **212** | **47** |

Method: `grep -cE` per pattern over `git archive febbae3` (counts lines; `.padding()` with no argument and `Spacer(minLength:)` not counted). Commented lines are included in the raw counts.
