# Legal Posture — Games Room V0.8

## Summary

Games Room is a social coordination app for in-person games nights.
It does **not** facilitate real-money exchange. The virtual points
ledger is a scoring system, not a financial instrument. No payment
processing, no real-currency conversion, no withdrawal to external
accounts.

This document satisfies vision §4.4: *"No real-money exchange; no
legal/gambling assessment in v1."*

## Key positions

### No real-money exchange

- Members receive a virtual starting bonus (default: 200 pts) on room
  join. This is a scoring seed, not a purchase.
- The Casino pack's chip withdrawal/return cycle converts virtual
  points ↔ physical chips for in-person play. The physical chips have
  no real-currency denomination — they are game tokens.
- No payment gateway, no in-app purchase, no subscription billing is
  integrated. The app has no mechanism to move real money.

### No gambling classification

- No real stakes: virtual points have no monetary value and cannot be
  redeemed for goods, services, or currency.
- No operator profit: the host is a peer organiser, not a house. The
  ledger is zero-sum within a session (Casino pack) or score-based
  (single-winner packs).
- No randomness-as-product: games played at the table (poker, board
  games) use their own physical components. The app does not run any
  random-number-driven game.

### Data handling

- Supabase (PostgreSQL) backend with Row Level Security on every
  table. Members can only read data for rooms they belong to.
- Season awards with the "Drowning" type are privacy-scoped: only the
  recipient can see their own Drowning award (migration 039 RLS).
- Apple Sign In is the only authentication mechanism. No passwords
  are stored. No third-party analytics or advertising SDKs.

### Mascot LLM voice (V0.26 extension)

- When a room has a `mascot_api_key` set, mascot notification bodies
  are generated via an OpenAI-compatible endpoint (z.ai glm-4.6).
- The API key is stored per-room in the `rooms.mascot_api_key` column
  (plaintext in V0.8; encryption deferred to V0.10+ per migration 021
  documentation).
- LLM generation falls back to template interpolation on any failure
  (network error, timeout, invalid key, empty response).
- No member PII is sent to the LLM endpoint — only the mascot's name,
  room name, event title, venue, and host note.

## Deferred items (V0.9+)

- `mascot_api_key` encryption at rest
- Formal privacy policy document (App Store requirement)
- Terms of service
- Region-specific compliance review (if expanding beyond AU)

## Decision log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-07-12 | No real-money exchange in v1 | Eliminates gambling classification; simplifies legal surface |
| 2026-07-12 | Virtual points are scoring only | No monetary value; no redemption path |
| 2026-08-05 | LLM mascot voice uses per-room API key | Host controls cost; no shared platform key exposure |
