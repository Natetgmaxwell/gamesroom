#!/usr/bin/env python3
"""make_095_guards.py — generate migration 095 part 2: regenerate every
host-gated RPC from the LIVE pg_proc definition with the created_by guard
widened to include the role-based check (OR-shape, purely additive).

Guard rewrite (covers aliased, bare-table, and join-resolved shapes):
    <alias.>created_by = v_caller
  -> (<alias.>created_by = v_caller OR public.is_room_host(<alias>.id, v_caller))

Functions with `created_by` references that are NOT host guards (joins that
resolve the room for other purposes) are detected and skipped for manual
review: a skip is safe (behaviour unchanged), a bad rewrite is not.
"""
import json
import re
import subprocess
import sys
from pathlib import Path

REPO = Path.home() / "Documents/VS Code/games-room"
SUPA = REPO / "supabase"

TARGETS = [
    "update_room_packs", "add_pack_to_room", "remove_pack_from_room",
    "set_room_pack_config", "update_room", "update_room_settings",
    "delete_room", "create_event", "add_event", "add_event_with_packs",
    "delete_event", "update_event_played_at", "record_score",
    "record_round_score", "delete_round_score", "set_tonight_star_pick",
    "close_season", "set_season_subtitle", "update_host_journal",
    "mark_member_notes_consumed", "list_arrival_candidates",
    "get_season_awards", "forfeit_seat_deposit", "waive_seat_deposit",
    "claim_seat_waived", "upsert_casino_config", "withdraw_casino_chips",
    "mark_withdrawal_dispensed", "open_casino_attestation_window",
    "finalize_casino_session", "approve_tier_two_join",
]

GUARD_RE = re.compile(r"\b((?:[a-z]\.)?)created_by\s*=\s*v_caller\b")


def live_query(sql: str):
    env = {
        "PATH": "/Users/nathanmaxwell/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
        "HOME": str(Path.home()),
        "SUPABASE_ACCESS_TOKEN": (Path.home() / ".supabase/token").read_text().strip(),
        "SUPABASE_DB_PASSWORD": (Path.home() / ".supabase/db-password").read_text().strip(),
    }
    r = subprocess.run(
        ["supabase", "db", "query", "--linked", "--output-format", "json", sql],
        cwd=SUPA, capture_output=True, text=True, env=env, timeout=180,
    )
    if r.returncode != 0:
        raise RuntimeError(f"query rc={r.returncode}: {r.stderr[:400]}")
    rows = json.loads(r.stdout)
    if rows and isinstance(rows[0], dict) and rows[0].get("_tag") == "Error":
        raise RuntimeError(rows)
    return rows


def main() -> int:
    names = ",".join(f"'{n}'" for n in TARGETS)
    rows = live_query(f"""
    select
      p.proname,
      pg_get_function_arguments(p.oid) as args,
      pg_get_function_result(p.oid) as ret,
      p.provolatile as volatility,
      (select l.lanname from pg_language l where l.oid = p.prolang) as lang,
      p.proconfig as config,
      obj_description(p.oid, 'pg_proc') as comment,
      p.prosrc as body
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname in ({names})
    order by p.proname
    """)
    found = {r["proname"] for r in rows}
    missing = set(TARGETS) - found
    if missing:
        print(f"WARN: not found live (skipped): {sorted(missing)}")

    out_blocks = []
    rewritten, skipped = 0, []
    for r in rows:
        body = r["body"]
        if "created_by" not in body:
            skipped.append((r["proname"], r["args"], "no created_by in body"))
            continue

        new_body, n = GUARD_RE.subn(
            lambda m: f"({m.group(1)}created_by = v_caller OR public.is_room_host({m.group(1)}id, v_caller))"
            if m.group(1) else
            f"(created_by = v_caller OR public.is_room_host(id, v_caller))",
            body,
        )
        # bare (unaliased) guards: `created_by = v_caller` with no table alias.
        # `id` bare would be ambiguous unless FROM is only rooms. Flag for manual.
        bare_left = re.search(r"(?<![\w.])\(created_by = v_caller OR public\.is_room_host\(id,", new_body)
        manual_notes = []
        if bare_left:
            manual_notes.append(f"{n} bare (unaliased) guard(s) need manual room-id expr")

        config = r["config"] or []
        config_sql = "\n".join(f"\nset {c}" for c in config)
        vol_sql = {"v": "volatile", "s": "stable", "i": "immutable"}[r["volatility"]]
        lang = r.get("lang") or "plpgsql"
        if lang not in ("sql", "plpgsql"):
            lang = "plpgsql"

        block = f"""
-- =================================================================
-- {r['proname']}({r['args']})
-- =================================================================
create or replace function public.{r['proname']}({r['args']})
returns {r['ret']}
language {lang}
{vol_sql}
security definer{config_sql}
as $body${new_body}$body$;
"""
        if manual_notes:
            block = "-- MANUAL REVIEW REQUIRED: " + "; ".join(manual_notes) + "\n" + block
        out_blocks.append(block)
        rewritten += 1

    preamble = (REPO / "Supabase/migrations/095_preamble.sql").read_text()
    out_path = REPO / "Supabase/migrations/095_role_based_host_guards.sql"
    existing = out_path.read_text()
    marker = "-- ==== END PART 1 (helper) ==== do not regenerate above this line"
    if marker in existing:
        existing = existing.split(marker)[0]
    with open(out_path, "w") as f:
        f.write(existing.rstrip() + "\n\n" + marker + "\n" + "\n".join(out_blocks))

    print(f"regenerated: {rewritten} functions")
    for name, args, why in skipped:
        print(f"  SKIPPED {name}({args}): {why}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
