# Games Room — V0.9 Roadmap

> Generated 2026-08-10 from the implementation plan
> (`/tmp/games-room-plan.md`, bridging `docs/vision.md` to the audited
> codebase at `main` @ `017fc1a`). This is the V0.9 slice list; the
> live feature-status source remains `docs/v0.8-vision-checklist.md`.

## V0.9 slices (Phase 2 of the implementation plan)

| ID | Slice | Feature | Status |
|----|-------|---------|--------|
| W2.1 | App-side camera integration | F-CAS-02 (on-device Core ML chip scan) | code-complete; manual device test required on Xcode host |
| W2.2 | Pack store shell | F-MVP-07 (4 packs, installed state, how-to bodies) | — |
| W2.3 | Glance + Live Activity + Watch | F-MVP-12 (widget extension + Watch targets) | — |
| W2.4 | Member-side event edit | vision §6.1 Q9 | — |
| W2.5 | Awards card UI | season awards (Phoenix/Veteran/Whale/Drowning), Drowning privacy rewrite | — |
| W2.6 | Chapter-line cadence + season subtitle | mascot voice; subtitle requires host-approval beat | — |
| W2.7 | Joined-late catch-up | vision §6.1 Q8 | — |
| W2.8 | iPad split-view | room list + detail | — |

## Dependencies

- W2.1 → `Tools/CasinoVisionProbe` (done, locked 2026-08-10).
- W2.3 isolated after the other Phase 2 slices (pbxproj churn);
  W3.2 (CI hardening) follows W2.3.
- W2.4–W2.8 are independent; any order.

## Verification

- Per slice: `./build-and-run-tests.sh` (Foundation tests + parse-check)
  and `python3 scripts/verify-xcode-project.py` after any pbxproj change.
- W2.1 / W2.3 require a manual pass on a Mac with Xcode 27 (camera on
  device; widget / Live Activity / Watch rendering). This host has no
  Xcode.app — those gates are documented as manual.
- Release readiness (M6): `ui-polish-engineering-loop` pass (W3.1),
  CI hardening (W3.2), TestFlight upload on an Xcode host (W3.3).
