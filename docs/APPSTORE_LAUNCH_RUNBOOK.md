# Games Room — App Store launch runbook (V0.93)

Step-through document for shipping **1.2.4** to the App Store. Written against
`main` @ `9d90a8b6` on 2026-11-11. Every path and SHA below was read from that
commit, not remembered.

**Target.** Marketing version `1.2.4`, build `28`. App record `6801997519`.
Bundle `com.gamesroom.app` (+ `com.gamesroom.app.widgets`). Team `37S7KT7W83`.
Watch app does **not** ship (deferred in `t_c074491c` — Xcode 27 watchapp2
build-system regression).

## Day-of order (six phases)

1. Clear the blockers below. Nothing after step 2 is possible until they are.
2. Bump the version, fix the privacy manifest, archive on the Studio.
3. Verify the archive's signature, entitlements and manifest.
4. Upload to TestFlight, burn in 24–72h.
5. Attach metadata + screenshots in App Store Connect, submit.
6. Watch `Activity`, fix or release.

---

## Blockers — clear these first

None of these are done. Each one stops the launch at the phase named.

| # | Blocker | Owner | Stops |
|---|---|---|---|
| 1 | `GamesRoom/PrivacyInfo.xcprivacy` ships `NSPrivacyCollectedDataTypes` as an empty array, while the nutrition label declares four rows (section 13 of `docs/AppStoreConnectMetadata.md`). Apple compares manifest to label. | build | Phase 2 |
| 2 | `project.yml` says `MARKETING_VERSION: "1.2.3"` / `CURRENT_PROJECT_VERSION: "27"`. 1.2.4 does not exist yet in the repo. | build | Phase 2 |
| 3 | Apple ADPLA acceptance in App Store Connect → Business (due 2026-11-13). Unaccepted agreement blocks both upload and submit. | Nathan | Phase 4 |
| 4 | Copyright legal entity (currently "© 2026 Nathan Maxwell"). | Nathan | Phase 5 |
| 5 | `support@gamesroom.app` — mailbox must exist and be read; it is the address App Review uses. | Nathan | Phase 5 |
| 6 | Age rating sign-off: **4+ with Simulated Gambling = None** (recommended) vs 13+ global / R 18+ in Australia. | Nathan | Phase 5 |
| 7 | Fresh reviewer join code (`WSBXS4` from 2026-08-27 is spent). | Nathan | Phase 5 |
| 8 | TestFlight "What to Test" notes for 1.2.4. `docs/testflight-release-notes.md` is still the 0.1.0 / V0.8 draft. | build | Phase 4 |

Items 4–7 are the four paste blockers already listed in
`docs/AppStoreConnectMetadata.md` → `## NEEDS USER INPUT`.

---

## Pre-flight (must be done before TestFlight upload)

### [ ] PrivacyInfo.xcprivacy present, all 3 targets reference it

Source of truth: commit `10fdce04` (V0.89).

```bash
ls GamesRoom/PrivacyInfo.xcprivacy \
   GamesRoomWidgets/PrivacyInfo.xcprivacy \
   GamesRoomWatch/PrivacyInfo.xcprivacy
git show 10fdce04 --stat   # V0.89: all three + the old hand-written pbxproj
```

`project.pbxproj` from that commit is gone — the project is generated from
`project.yml` since `6ff470ef`, and xcodegen picks the manifests up by directory
glob. Presence on disk is the check; there is no wiring step to redo.

The Watch manifest stays in the tree even though the Watch app does not ship.

### [ ] PrivacyInfo declares the four collected data types

This is blocker 1. The file currently prints an empty array:

```bash
/usr/libexec/PlistBuddy -c "Print :NSPrivacyCollectedDataTypes" GamesRoom/PrivacyInfo.xcprivacy
# now:  Array { }
# needed: Contact Info → Name, User Content → Other User Content,
#         Identifiers → User ID, Usage Data → Product Interaction
```

All four: linked to the user, not used for tracking, purpose App Functionality.
Same table as `docs/AppStoreConnectMetadata.md` §13. Fix the manifest — do not
empty the label; the data is genuinely in Supabase.

### [ ] Version bumped for the submission

```bash
grep -n "MARKETING_VERSION\|CURRENT_PROJECT_VERSION" project.yml
# now: 1.2.3 / 27   →   needs: 1.2.4 / 28
/opt/homebrew/bin/xcodegen generate
```

Commit in the house style: `chore: bump to 1.2.4 (28) for App Store submission`.
Build number must be higher than anything already uploaded for 1.2.4 in App
Store Connect → TestFlight. `28` is the next in the local sequence; confirm it
against ASC before archiving.

Do not hand-edit `GamesRoom.xcodeproj` — it is generated from `project.yml`
(commit `6ff470ef`).

### [ ] Release archive builds clean and is signed

Run **on the Mac Studio from the GUI session**, not over plain SSH — the signing
keychain is locked for non-GUI sessions and `xcodebuild` dies with
`errSecInternalComponent` (measured in `t_e6a6f505`).

```bash
cd ~/Documents/VS\ Code/games-room
/opt/homebrew/bin/xcodegen generate
xcodebuild -project GamesRoom.xcodeproj -scheme GamesRoom \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/GamesRoom.xcarchive archive
```

Note: the repo has **no `.xcworkspace`** since the xcodegen migration. The
`-workspace GamesRoom.xcworkspace` form in the task card no longer resolves.

```bash
codesign -dvvv build/GamesRoom.xcarchive/Products/Applications/GamesRoom.app 2>&1 \
  | grep -E "Authority|TeamIdentifier"
# want: Authority=Apple Distribution: Nathan Maxwell (37S7KT7W83)
#       TeamIdentifier=37S7KT7W83

security cms -D -i build/GamesRoom.xcarchive/Products/Applications/GamesRoom.app/embedded.mobileprovision \
  | plutil -extract TeamIdentifier.0 raw -
# want: 37S7KT7W83
```

The Apple Distribution certificate exists as of 2026-08-27 (`t_e6a6f505`), made
through the Xcode GUI on the Studio. It has signed exactly one upload so far:
build `1.0 (5)`, which is historical and unrelated to this submission.

### [ ] Push entitlement is `production` in the archived build

`GamesRoom/GamesRoom.entitlements` in the repo says `aps-environment =
development`. Automatic signing normally swaps it for Release, but verify the
built product rather than trusting the source value:

```bash
codesign -d --entitlements :- build/GamesRoom.xcarchive/Products/Applications/GamesRoom.app 2>/dev/null \
  | plutil -extract aps-environment raw -
# want: production — anything else and TestFlight push silently fails
```

### [ ] Archive contents match what is being submitted

```bash
APP=build/GamesRoom.xcarchive/Products/Applications/GamesRoom.app
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" $APP/Info.plist   # 1.2.4
/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" $APP/Info.plist              # 28
ls $APP/PrivacyInfo.xcprivacy $APP/PlugIns/GamesRoomWidgets.appex                # both present
ls $APP/PlugIns/Watch 2>/dev/null || echo "no watch app (expected, t_c074491c)"
```

### [ ] docs/AppStoreConnectMetadata.md is complete

All 13 sections are filled for 1.2.4 (commit `9d90a8b6`). Lengths verified: name
10, subtitle 24, description 2,812, promo 143, keywords 94. Seven
`NEEDS USER INPUT` items remain; four block a paste and are blockers 4–7 above.

Locked values carried from Nathan's 2026-11-08 decision — do not re-derive them:
subtitle "For regular games nights", primary category Lifestyle, secondary
Social Networking, keywords
`poker,host,friends,score,keeper,tracker,board,card,rsvp,invite,club,season,ladder,weekly,mates`.

### [ ] Description contains the amendment sentence (exactly)

Required verbatim by the 2026-08-22 amendment:
"Chips are an in-app currency that lives in the room's ledger and never
converts to anything outside the app."

A plain `grep` returns **0** because the sentence is hard-wrapped across two
lines in the file. Join the lines before searching:

```bash
tr '\n' ' ' < docs/AppStoreConnectMetadata.md | tr -s ' ' \
  | grep -o "Chips are an in-app currency that lives in the room's ledger and never converts to anything outside the app"
# verified 2026-11-11: prints the sentence once
```

Same check on the pasted text in App Store Connect, after step 5.

### [ ] Privacy nutrition label: Financial Info = "Data not collected"

In App Store Connect → App Privacy, the **Financial Info** row must read
**Data not collected** — chips are an in-app currency that lives in the room's
ledger and never converts to anything outside the app; no money, card, or cash
crosses the app boundary. If Financial Info shows any "collected" or "linked to
user" answer, the metadata task (`t_28ace795`) was answered wrong: stop, fix the
label, do not submit.

Full table: `docs/AppStoreConnectMetadata.md` §13. Nine other categories are
also "Data not collected"; four are Collected + Linked, App Functionality only,
no tracking.

### [ ] App Store Connect record exists

App record `6801997519` is live. Manual user step — nothing in Hermes can create
it. Confirm the record's bundle id is `com.gamesroom.app` before uploading.

### [ ] Metadata section 12: age rating answered as 4+ / Simulated Gambling = None

Apple retired 12+/17+ on 2025-07-24; tiers are 4/9/13/16/18 and the new
questionnaire has been mandatory since 2026-01-31. In Apple's **Australia**
table, "Infrequent simulated gambling" maps to **R 18+**, so answering it to be
safe gates the launch market at 18+. The app runs no game of chance — the table
plays with physical chips and the app records the ledger afterwards — so 4+ with
Simulated Gambling = None is both honest and cheaper. Sign-off is blocker 6.

### [ ] URLs return 200

```bash
for u in https://gamesroom.nateterrence.net \
         https://gamesroom.nateterrence.net/support \
         https://gamesroom.nateterrence.net/privacy; do
  printf "%s -> %s\n" "$u" "$(curl -s -o /dev/null -w '%{http_code}' -m 15 "$u")"
done
# all three: 200 (verified 2026-11-11)
```

### [ ] Screenshots exist at required pixel dimensions

Upload set — caption-stripped, because App Store Connect rejects baked-in
overlays. Six shots per size, 24 PNGs:

| Path | Size | Required |
|---|---|---|
| `screenshots/upload/iphone-6.9/` | 1290×2796 | iPhone 6.9" |
| `screenshots/upload/iphone-6.5/` | 1242×2688 | iPhone 6.5" |
| `screenshots/upload/iphone-5.5/` | 1242×2208 | iPhone 5.5" |
| `screenshots/upload/ipad-13/` | 2064×2752 | iPad 13" |

```bash
for d in screenshots/upload/*/; do
  echo "$d"
  for f in "$d"*.png; do sips -g pixelWidth -g pixelHeight "$f" | tail -2; done
done
```

Dimensions above were measured with `sips` on `main` @ `9d90a8b6`. Regeneration
steps, capture launch args and the v3/v4 change list are in
`screenshots/manifest.md` (commit `e13ccf60`). iPad is captured in column mode
(`-screenshots-ipad-column`) — App Store Connect rejects stretched two-pane iPad
screenshots. The v2 set is archived at `screenshots/upload-v2-v097/` for audit.

### [ ] TestFlight "What to Test" notes for 1.2.4

Blockers 8. The file on main describes 0.1.0 (build 1) and V0.8. Write the
1.2.4 notes before uploading, or the first internal build arrives with no
instructions.

---

## TestFlight burn-in (24–72h)

### [ ] Build uploaded to TestFlight

Xcode Organizer on the Mac Studio GUI session: Window → Organizer →
Archives → select the 1.2.4 archive → Distribute App → App Store Connect →
Upload. Or `xcodebuild -exportArchive` then Transporter.

Not via `altool` from the shell: the ASC API path is blocked until the ADPLA is
accepted (blocker 3) and the keychain is unlocked for non-GUI sessions.

### [ ] Processing finishes and the build is attached to 1.2.4

App Store Connect → TestFlight. Wait for "Ready to Submit". Apple emails on
completion; processing is typically 10–60 min.

### [ ] Internal testers get a build with push enabled and calendar-write prompted

Real-device check, not simulator. On a TestFlight build:

- Notification permission prompt appears and a reminder actually arrives.
- Calendar write prompt appears the first time an event is added.
- Sign in with Apple completes against the production Supabase project.
- A room joins by code end-to-end (mint a non-reviewer code for this).

### [ ] External testers / beta review submitted and approved

Only needed if external testing is part of the plan. Beta review is typically
under 24h.

### [ ] No crash > 1%, no privacy violation, no missing entitlement reported

App Store Connect → TestFlight → Crashes. Also watch for the
`Missing Push Notification Entitlement` email — that is the
`aps-environment` check above having failed in the shipped binary.

---

## Production submission

### [ ] In App Store Connect: select the TestFlight build, attach metadata, screenshots, pricing

On the 1.2.4 version page:

1. Build → select the burn-in build.
2. Paste each field from `docs/AppStoreConnectMetadata.md` in its section order.
3. Drag `screenshots/upload/iphone-6.9/` (and the other three sizes if ASC asks
   per-device) into the screenshot wells.
4. Pricing: Free. Availability: per §12 — all territories after the first 1.2.4
   review passes.
5. App Privacy: the §13 table, Financial Info = Data not collected.
6. Review notes: fresh join code (blocker 7), Sign-In Information, and the
   line that no game of chance is run.

### [ ] Submit for review

Standard turnaround 24–48h. Expedited review is available if a rejection is the
gating risk; it is a request, not a guarantee.

### [ ] Release: manual

Set the release to **Manually release this version** so the listing can be
checked live before it goes public. Once approved, release from the same page.

---

## Day-of monitoring

### [ ] Watch Activity within 2 hours of "In Review"

App Store Connect → Activity → App `6801997519`. A rejection shows here first,
with the Resolution Center message. Do not wait for the email.

### [ ] If rejected: hotfix path

1. Read the Resolution Center message. Name the exact guideline before editing
   anything.
2. Branch off current `main` — a **new** branch, not `feat/v089-privacy-manifest`
   and not the V0.92 or V0.93 branches. Those are landed and rebasing them
   creates ghost files.
3. Fix, then bump `CURRENT_PROJECT_VERSION` in `project.yml` (28 → 29), run
   `xcodegen generate`, commit, FF-merge to `main`, push.
4. Re-archive, re-upload, re-submit. Same build number twice is rejected.

```bash
git checkout main && git pull --ff-only
git checkout -b fix/1.2.4-review-rejection
# ... fix ...
/opt/homebrew/bin/xcodegen generate
```

---

## Artifact ledger

| Artifact | Path | Commit |
|---|---|---|
| Privacy manifests (3 targets) | `GamesRoom/PrivacyInfo.xcprivacy`, `GamesRoomWidgets/`, `GamesRoomWatch/` | `10fdce04` |
| Release archive evidence (V0.90) | `macstudio-tailnet:~/Documents/VS Code/games-room/.worktrees/t_bc26b0d9_studio/build/GamesRoom.xcarchive` | `10fdce04` + studio build |
| Apple Distribution cert + first upload (V0.91, 2026-08-27) | build `1.0 (5)` in App Store Connect | GUI session, Studio |
| ASC metadata (V0.92) | `docs/AppStoreConnectMetadata.md` | `9d90a8b6` |
| Screenshots, upload set | `screenshots/upload/{iphone-6.9,iphone-6.5,iphone-5.5,ipad-13}/` | `e13ccf60` |
| Screenshot manifest / regeneration | `screenshots/manifest.md`, `scripts/make-screenshots.py` | `e13ccf60` |
| Project generator (no workspace) | `project.yml` | `6ff470ef` |
| Version source | `project.yml` → `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION` | `a73a4285` (1.2.3 / 27) |
| Legal pages | `/support`, `/privacy`, marketing root on `gamesroom.nateterrence.net` | live, 200 |

## Out of scope

Clicking **Submit for Review** and accepting the ADPLA are Nathan's, not
Hermes'. The Watch app is deferred (`t_c074491c`); iPad and video previews were
deferred in the screenshot task.
