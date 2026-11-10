import re
import sys

import pglast

PATH = "/Users/nathanmaxwell/Projects/worktrees/s2b/notif-server/Supabase/migrations/112_events_rls_active.sql"

sql = open(PATH).read()

# 1. Whole-file parse (real PG grammar).
try:
    stmts = pglast.parse_sql(sql)
    print(f"file parse OK: {len(stmts)} statements")
except Exception as exc:  # noqa: BLE001
    print("FILE PARSE FAILED:")
    print(exc)
    sys.exit(1)

# 2. The policy set: every events policy is dropped and recreated, and
#    nothing else on the table is touched.
drops = re.findall(r'drop policy if exists "([^"]+)" on public\.events;', sql)
creates = re.findall(r'create policy "([^"]+)"\s*\n?\s*on public\.events for (\w+)', sql)

expected = {
    "members can read events": "select",
    "host can insert events": "insert",
    "host can update events": "update",
    "host can delete events": "delete",
}
if sorted(drops) != sorted(expected):
    print(f"UNEXPECTED DROP SET: {drops}")
    sys.exit(1)
if sorted(name for name, _ in creates) != sorted(expected):
    print(f"UNEXPECTED CREATE SET: {creates}")
    sys.exit(1)
for name, cmd in creates:
    if expected[name] != cmd:
        print(f"POLICY COMMAND MISMATCH: {name} is {cmd}, expected {expected[name]}")
        sys.exit(1)
print("policy set OK:", sorted(expected))

# 3. The read policy filters on active membership and keeps the
#    hidden-from check.
read_block = re.search(
    r'create policy "members can read events"(.*?);', sql, re.S
)
if not read_block:
    print("READ POLICY NOT FOUND")
    sys.exit(1)
read = read_block.group(1)
for frag in (
    "m.membership_status = 'active'",
    "not (public.current_user_id() = any(events.hidden_from_user_ids))",
    "m.user_id = public.current_user_id()",
):
    if frag not in read:
        print(f"MISSING FRAGMENT IN READ POLICY: {frag}")
        sys.exit(1)

# 4. The three write policies use the canonical host guard, and no
#    policy body still asks rooms.created_by.
for name in ("host can insert events", "host can update events", "host can delete events"):
    m = re.search(rf'create policy "{name}"(.*?);', sql, re.S)
    if not m:
        print(f"POLICY NOT FOUND: {name}")
        sys.exit(1)
    body = m.group(1)
    if "public.is_room_host(events.room_id, public.current_user_id())" not in body:
        print(f"MISSING is_room_host GUARD: {name}")
        sys.exit(1)

code = re.sub(r"--[^\n]*", "", sql)
if "created_by" in code:
    print("FORBIDDEN FRAGMENT: created_by still in the file")
    sys.exit(1)
if "is_room_host" not in code:
    print("is_room_host never used")
    sys.exit(1)

# 5. No table or column outside the events table.
for bad in (
    "alter table",
    "create table",
    "drop table",
    "create index",
    "grant execute",
    "revoke all on function",
):
    if bad in sql.lower():
        print(f"FORBIDDEN FRAGMENT: {bad}")
        sys.exit(1)

# 6. The transaction opens and closes.
if not re.search(r'^\s*begin;', sql, re.M):
    print("NO BEGIN")
    sys.exit(1)
if not re.search(r'^\s*commit;\s*$', sql, re.M):
    print("NO COMMIT")
    sys.exit(1)

print("ALL CHECKS OK")
