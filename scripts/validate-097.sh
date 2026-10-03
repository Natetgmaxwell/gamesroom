#!/usr/bin/env bash
#
# validate-097.sh — applies migration 097 to a throwaway local Postgres
# (shadow DB) on top of a minimal pre-097 stub, runs the behavioural
# checks, then re-applies 097 to prove idempotency. Never touches live.
#
# Usage: scripts/validate-097.sh            (needs initdb/pg_ctl/psql on PATH)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export LC_ALL="${LC_ALL:-en_US.UTF-8}" LANG="${LANG:-en_US.UTF-8}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/gr097.XXXXXX")"
PORT="${PORT:-55497}"
SOCK="/tmp"  # unix socket paths are length-capped; $TMPDIR is too deep

cleanup() { pg_ctl -D "$WORK/data" -m immediate stop >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT

initdb -D "$WORK/data" -U postgres -A trust >/dev/null
pg_ctl -D "$WORK/data" -o "-p $PORT -k $SOCK -c listen_addresses=''" -l "$WORK/log.txt" -w start >/dev/null

PSQL=(psql -h "$SOCK" -p "$PORT" -U postgres -d postgres -v ON_ERROR_STOP=1 -q)
"${PSQL[@]}" -f "$ROOT/tests/sql/097_shadow_prereqs.sql"
"${PSQL[@]}" -f "$ROOT/Supabase/migrations/097_question_box.sql"
"${PSQL[@]}" -f "$ROOT/tests/sql/097_question_box_test.sql"
echo "re-applying 097 (idempotency)…"
"${PSQL[@]}" -f "$ROOT/Supabase/migrations/097_question_box.sql"
echo "097 re-apply OK"
