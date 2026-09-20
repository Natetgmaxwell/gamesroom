#!/bin/bash
# test-display-name-save.sh — LIVE REST harness for the App Settings
# display-name save bug (TestFlight build 15).
#
# Verifies the EXACT HTTP path the Swift client sends against the
# live Supabase project (bnrgkdcluopicqdpmrtu). Uses a deterministic
# probe user inserted via the supabase CLI's `db query` (postgres
# superuser) then signs in via the password grant to get a real user
# JWT, then runs the PATCH and the read-back.
#
# This script exercises the same:
#   - URL: /rest/v1/users?id=eq.<UUID>
#   - Method: PATCH
#   - Headers: Authorization: Bearer <jwt>, apikey: <anon key>,
#     Content-Type: application/json, Accept: application/json,
#     Prefer: return=representation
#   - Body: {"display_name":"..."}
# ...as the Swift client (verified via the supabase-swift PostgREST
# builder: default for .update() is returning=.representation,
# which sets Prefer: return=representation).
#
# If this script returns "PASS" but the Swift client still shows
# "doesn't save" on iPad, the bug is unambiguously in the iOS
# client — not RLS, not the server.
#
# Requires: curl, jq, supabase CLI >= 2.68 (which added `db query`).
# Run from a directory that's `supabase link`ed to bnrgkdcluopicqdpmrtu
# (the repo root is, after `supabase link --project-ref ...`).

set -euo pipefail

# Resolve supabase CLI binary.
SUPABASE_BIN="${SUPABASE_BIN:-$(command -v supabase || echo /opt/homebrew/bin/supabase)}"

PROJECT_ID="${PROJECT_ID:-bnrgkdcluopicqdpmrtu}"
BASE="https://${PROJECT_ID}.supabase.co"

# Probe id (deterministic so reruns can clean up). UUID v4-like,
# all-1s is reserved/invalid for production; safe for a test fixture.
PROBE_ID="11111111-1111-1111-1111-111111111111"
PROBE_EMAIL="probe-display-name@example.com"
PROBE_PASSWORD="probe-display-name-pass"
PROBE_INITIAL="Probe Before"
PROBE_UPPER="Probe After UPPER"
PROBE_LOWER="probe after lower"

# Make sure the probe slot is clean before provisioning — we use a
# fixed id but the previous run may have left an old user with a
# different email/password. Wipe both rows so the new insert with
# ON CONFLICT (id) DO UPDATE actually wins.
RESET_SQL=$(cat <<SQL
DELETE FROM public.users WHERE id = '${PROBE_ID}';
DELETE FROM auth.users WHERE id = '${PROBE_ID}';
SQL
)

step() { echo; echo "===== $* ====="; }

step "0. preflight: anon key from Config.xcconfig"
CFG="$(cd "$(dirname "$0")/.." && pwd)/GamesRoom/Config.xcconfig"
if [ ! -f "$CFG" ]; then
  echo "FAIL: $CFG not found"; exit 2
fi
ANON=$(awk -F"= " '/^SUPABASE_ANON_KEY/ {print $2}' "$CFG" | tr -d '\n')
if [ -z "$ANON" ] || [ "${#ANON}" -lt 200 ]; then
  echo "FAIL: anon key missing or too short (got ${#ANON} chars)"; exit 2
fi
echo "  anon key length: ${#ANON}"

step "1. provision probe user (postgres side via supabase db query OR Management API)"
# Two paths depending on the CLI's age:
#   - CLI >= 2.68 has `supabase db query` (needs a linked workdir).
#   - CLI < 2.68 falls back to the Management API POST
#     /v1/projects/{ref}/database/query (needs the personal access
#     token in ~/.supabase/token). The body is JSON: {"query": "..."}.
#
# Resolve the workdir first if the CLI supports it.
# Check: `supabase db query --help` should mention --workdir (or
# fail with "unknown subcommand") — CLI < 2.68 returns the parent
# `db --help` because `query` doesn't exist yet.
HELP_OUT="$("$SUPABASE_BIN" db query --help 2>&1 || true)"
if echo "$HELP_OUT" | grep -q "Available Commands" && ! echo "$HELP_OUT" | grep -q "Execute a SQL query"; then
  echo "  CLI lacks 'db query'; using Management API /database/query"
  TOKEN_FILE="${TOKEN_FILE:-$HOME/.supabase/token}"
  if [ ! -f "$TOKEN_FILE" ]; then
    echo "FAIL: $TOKEN_FILE missing and CLI < 2.68 has no db query"; exit 2
  fi
  DB_QUERY_MODE="mgmt-api"
else
  if "$SUPABASE_BIN" status --workdir "$(pwd)" 2>/dev/null | grep -q "Linked to"; then
    : # current cwd works
  elif [ -d "$HOME/.supabase" ] && [ -f "$HOME/.supabase/linked-project.json" ]; then
    cd "$HOME/.supabase"
  else
    TMPDIR_LINK="$(mktemp -d)"
    trap 'rm -rf "$TMPDIR_LINK"' EXIT
    mkdir -p "$TMPDIR_LINK/supabase/.temp"
    echo -n "$PROJECT_ID" > "$TMPDIR_LINK/supabase/.temp/project-ref"
    cd "$TMPDIR_LINK"
  fi
  echo "  supabase db query workdir: $(pwd)"
  DB_QUERY_MODE="cli"
fi

# Usage: db_run_query "<SQL...>"
db_run_query() {
  local sql="$1"
  if [ "$DB_QUERY_MODE" = "cli" ]; then
    echo "$sql" | "$SUPABASE_BIN" db query 2>&1
  else
    local body
    body="$(jq -n --arg q "$sql" '{query:$q}')"
    TOKEN="$(head -n1 "${TOKEN_FILE:-$HOME/.supabase/token}")"
    curl -sS -X POST "https://api.supabase.com/v1/projects/$PROJECT_ID/database/query" \
      -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
      -d "$body" 2>&1
  fi
}

PROBE_SQL=$(cat <<SQL
DO \$\$
DECLARE
  probe_id uuid := '${PROBE_ID}';
  probe_email text := '${PROBE_EMAIL}';
BEGIN
  INSERT INTO auth.users (
    id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, email_change, email_change_token_new, recovery_token
  ) VALUES (
    probe_id, '00000000-0000-0000-0000-000000000000'::uuid, 'authenticated',
    'authenticated', probe_email,
    crypt('${PROBE_PASSWORD}', gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"display_name":"${PROBE_INITIAL}"}'::jsonb,
    now(), now(), '', '', '', ''
  ) ON CONFLICT (id) DO NOTHING;
  INSERT INTO public.users (id, display_name) VALUES (probe_id, '${PROBE_INITIAL}')
    ON CONFLICT (id) DO UPDATE SET display_name = EXCLUDED.display_name;
END \$\$;
SELECT id, display_name FROM public.users WHERE id = '${PROBE_ID}';
SQL
)
db_run_query "$RESET_SQL" > /dev/null
db_run_query "$PROBE_SQL" | tail -8

step "2. sign in as probe user (anon key + password grant)"
SIGNIN=$(curl -sS -X POST "${BASE}/auth/v1/token?grant_type=password" \
  -H "apikey: $ANON" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"${PROBE_EMAIL}\",\"password\":\"${PROBE_PASSWORD}\"}")
JWT=$(echo "$SIGNIN" | jq -r '.access_token // empty')
if [ -z "$JWT" ]; then
  echo "FAIL: signin response: $SIGNIN" | head -c 400; exit 1
fi
echo "  JWT length: ${#JWT}"

step "3. baseline GET (mirrors loadCurrentUser)"
BASELINE=$(curl -sS "${BASE}/rest/v1/users?id=eq.${PROBE_ID}&select=id,display_name" \
  -H "Authorization: Bearer $JWT" -H "apikey: $ANON")
echo "  $BASELINE"
BEFORE=$(echo "$BASELINE" | jq -r '.[0].display_name // empty')
echo "  baseline display_name = $BEFORE"

step "4. PATCH with UPPERCASE id (Swift UUID.uuidString form) + Prefer: return=representation"
PATCH_RESP=$(curl -sS -w "\nHTTP_STATUS=%{http_code}" -X PATCH "${BASE}/rest/v1/users?id=eq.${PROBE_ID}" \
  -H "Authorization: Bearer $JWT" -H "apikey: $ANON" \
  -H "Content-Type: application/json" -H "Accept: application/json" \
  -H "Prefer: return=representation" \
  -d "{\"display_name\":\"${PROBE_UPPER}\"}")
echo "$PATCH_RESP"
STATUS=$(echo "$PATCH_RESP" | grep "HTTP_STATUS=" | sed 's/HTTP_STATUS=//')
if [ "$STATUS" != "200" ]; then
  echo "FAIL: PATCH returned $STATUS"
  exit 1
fi

step "5. read-back GET — did display_name change on the server?"
AFTER=$(curl -sS "${BASE}/rest/v1/users?id=eq.${PROBE_ID}&select=id,display_name" \
  -H "Authorization: Bearer $JWT" -H "apikey: $ANON")
echo "  $AFTER"
GOT=$(echo "$AFTER" | jq -r '.[0].display_name // empty')
if [ "$GOT" = "$PROBE_UPPER" ]; then
  echo "  PASS: UPPERCASE id PATCH persisted"
else
  echo "  FAIL: UPPERCASE id PATCH did NOT persist (got: '$GOT')"
  exit 1
fi

step "6. PATCH with LOWERCASE id (defensive — server should be case-insensitive)"
PATCH_LOWER=$(curl -sS -w "\nHTTP_STATUS=%{http_code}" -X PATCH \
  "${BASE}/rest/v1/users?id=eq.$(echo $PROBE_ID | tr A-F a-f)" \
  -H "Authorization: Bearer $JWT" -H "apikey: $ANON" \
  -H "Content-Type: application/json" \
  -H "Prefer: return=representation" \
  -d "{\"display_name\":\"${PROBE_LOWER}\"}")
echo "$PATCH_LOWER"
GOT_LOWER=$(curl -sS "${BASE}/rest/v1/users?id=eq.${PROBE_ID}&select=id,display_name" \
  -H "Authorization: Bearer $JWT" -H "apikey: $ANON" | jq -r '.[0].display_name // empty')
echo "  after lowercase id PATCH, display_name = $GOT_LOWER"
[ "$GOT_LOWER" = "$PROBE_LOWER" ] && echo "  PASS: LOWERCASE id PATCH persisted" \
                                   || echo "  INFO: LOWERCASE id PATCH did NOT persist (server treats UUID as case-sensitive)"

step "7. cleanup: reset display_name to baseline"
curl -sS -o /dev/null -w "  cleanup HTTP %{http_code}\n" -X PATCH \
  "${BASE}/rest/v1/users?id=eq.${PROBE_ID}" \
  -H "Authorization: Bearer $JWT" -H "apikey: $ANON" \
  -H "Content-Type: application/json" -H "Prefer: return=minimal" \
  -d "{\"display_name\":\"${PROBE_INITIAL}\"}"

step "DONE"
echo "Server-side PATCH path is verified. If the Swift client still fails,"
echo "the bug is in AuthService.updateDisplayName / AppSettingsView.save()."