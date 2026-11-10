import re
import sys

import pglast

PATH = "/Users/nathanmaxwell/Projects/worktrees/s2b/notif-server/Supabase/migrations/111_question_box_timing.sql"

sql = open(PATH).read()

# 1. Whole-file parse (real PG grammar).
try:
    stmts = pglast.parse_sql(sql)
    print(f"file parse OK: {len(stmts)} statements")
except Exception as exc:  # noqa: BLE001
    print("FILE PARSE FAILED:")
    print(exc)
    sys.exit(1)

# 2. Every function body on its own. plpgsql bodies are strings to the
#    outer parser, so pull them out by hand and parse what is parseable.
heads = list(
    re.finditer(
        r"create or replace function\s+([\w.]+)\s*\(([^)]*)\)(.*?)(?:as\s+(\$body\$|\$\$))(.*?)(\$body\$|\$\$)\s*;",
        sql,
        re.S,
    )
)
if not heads:
    print("NO FUNCTIONS FOUND - the extractor is wrong")
    sys.exit(1)

names = []
for m in heads:
    name = m.group(1)
    sig = " ".join(m.group(2).split())
    kind = m.group(3)
    body = m.group(5)
    lang = "plpgsql" if "plpgsql" in kind else "sql" if "language sql" in kind else "?"
    names.append(name)
    if lang == "sql":
        try:
            pglast.parse_sql(body)
            print(f"sql-body parse OK: {name}({sig})")
        except Exception as exc:  # noqa: BLE001
            print(f"SQL BODY PARSE FAILED: {name}")
            print(exc)
            sys.exit(1)
    else:
        depth = 0
        for ch in body:
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if depth < 0:
                    print(f"PAREN UNDERFLOW in {name}")
                    sys.exit(1)
        if depth != 0:
            print(f"PAREN IMBALANCE in {name}: {depth}")
            sys.exit(1)
        # Every statement inside the plpgsql body must start with a keyword
        # we recognise: catches a stray comma or a missing semicolon.
        stripped = re.sub(r"--[^\n]*", "", body)
        for stmt in [s.strip() for s in stripped.split(";") if s.strip()]:
            head = stmt.split()[0].lower()
            if head not in {
                "select", "insert", "update", "delete", "if", "return",
                "return query", "for", "v_reader", "v_kind", "v_rot",
                "v_turn", "v_arrived", "v_has_turns", "v_reader_pos",
                "v_n", "v_i", "v_cand", "v_host", "v_alt", "v_ids",
                "v_room", "v_q", "v_e", "begin", "end", "exit", "else",
                "declare", "v_next_pos",
                "elsif", "endcase", "raise", "perform",
            }:
                print(f"UNEXPECTED STATEMENT START in {name}: {stmt[:60]!r}")
                sys.exit(1)
        print(f"plpgsql balance OK: {name}({sig}) [{lang}]")

expected = [
    "public.question_box_arrivals",
    "public.question_box_rotation",
    "public.question_box_host",
    "public.question_box_advance",
]
if sorted(names) != sorted(expected):
    print(f"UNEXPECTED FUNCTION SET: {names}")
    sys.exit(1)

# 3. Every dollar-quoted block has to be closed.
if sql.count("$$") % 2 != 0:
    print("UNBALANCED $$ COUNT")
    sys.exit(1)

# 4. The rules the brief states, checked by reading the file.
required = [
    # search_path + grants on every function
    "set search_path = public",
    "revoke all on function public.question_box_arrivals(uuid) from public, anon;",
    "grant execute on function public.question_box_arrivals(uuid) to authenticated, service_role;",
    "revoke all on function public.question_box_rotation(uuid) from public, anon, authenticated;",
    "grant execute on function public.question_box_rotation(uuid) to service_role;",
    "revoke all on function public.question_box_host(uuid) from public, anon, authenticated;",
    "grant execute on function public.question_box_host(uuid) to service_role;",
    "revoke all on function public.question_box_advance(uuid, timestamptz) from public, anon, authenticated;",
    "grant execute on function public.question_box_advance(uuid, timestamptz) to service_role;",
    # the four rules of the step
    "v_arrived < 3 and p_now < v_e.played_at + make_interval(mins => 30)",
    "p_now > v_e.played_at + make_interval(hours => v_e.auto_close_hours)",
    "coalesce(t.read_at, t.passed_at) > p_now - make_interval(mins => 60)",
    "and dt.is_active and dt.platform = 'ios'",
    # the arrival signals
    "t.kind = 'casino_withdrawal'",
    "sd.returned_at is not null",
    "and sd.status <> 'forfeited'",
    # active membership only
    "m.membership_status = 'active'",
]
for r in required:
    if r not in sql:
        print(f"MISSING REQUIRED FRAGMENT: {r}")
        sys.exit(1)
print("required fragments OK")

# 5. Nothing that would undo the step.
for bad in (
    "Australia/Brisbane",
    "question_cadence_minutes = 30",
    "drop function public.question_box_draw",
):
    if bad in sql:
        print(f"FORBIDDEN FRAGMENT: {bad}")
        sys.exit(1)

# 6. The reader cursor arithmetic, simulated the way the plpgsql runs it.
#    rotation = the arrived members, tokens = who can be reached.
#    pick returns (reader, next cursor). The cursor is the 0-based
#    position of the NEXT candidate, the way the events column is written.
def pick(rotation, index, has_token):
    n = len(rotation)
    for i in range(1, n + 1):
        cand = rotation[((index + i - 1) % n)]
        if has_token(cand):
            return cand, ((index + i) % n)
    return None, None


rot = ["a", "b", "c", "d"]
index = 0
seen = []
for _ in range(6):
    reader, index = pick(rot, index, lambda m: True)
    assert reader is not None
    seen.append(reader)
assert seen == ["a", "b", "c", "d", "a", "b"], seen
print(f"cursor without skips OK: {seen}")

# One member with no token: the reader is skipped and the cursor lands on
# the member after the chosen one, so the next turn starts there. "a" is
# never asked: they cannot be reached.
rot = ["a", "b", "c"]
index = 0
reader, index = pick(rot, index, lambda m: m != "a")
assert (reader, index) == ("b", 2), (reader, index)
reader, index = pick(rot, index, lambda m: m != "a")
assert (reader, index) == ("c", 0), (reader, index)
reader, index = pick(rot, index, lambda m: m != "a")
assert (reader, index) == ("b", 2), (reader, index)
print("cursor with skips OK")

# The skipped member still gets their turn back when the rotation wraps.
rot = ["a", "b", "c"]
index = 0
reader, index = pick(rot, index, lambda m: m != "a")
assert reader == "b"
reader, index = pick(rot, index, lambda m: m != "a")
assert reader == "c"
reader, index = pick(rot, index, lambda m: m != "a")
assert reader == "b"
print("cursor wraps past a skipped member OK")

# Nobody reachable: no turn, so the box stays quiet.
assert pick(rot, 0, lambda m: False) == (None, None)
print("no reachable reader OK")

# 7. The cursor survives a rotation that shrank (index bigger than n).
rot = ["a", "b"]
reader, index = pick(rot, 5, lambda m: True)
assert reader == "b", reader
print("cursor with a stale index OK")

print("ALL CHECKS OK")
