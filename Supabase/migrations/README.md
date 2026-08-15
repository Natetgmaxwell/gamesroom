# Games Room — Migration Conventions

The numbering convention for `Supabase/migrations/`. Read this before
writing the next migration.

## Rules

1. **Additive only.** New migrations add columns, tables, RPCs, policies.
   Never edit or rewrite an already-applied migration — the live database
   is the implementation; the files are the history. A fix ships as a new
   migration.

2. **No renumbering.** Numbers are chronological and permanent. Gaps are
   historical: 009, 010, 037, and 038 do not exist in the 001–051 range —
   the work they were reserved for landed in other migrations or was
   abandoned. Leave them alone.

3. **Next number.** Take the highest existing number and increment.
   Current high-water mark: **069** (069_hosted_scan_authority.sql) → next
   is **070**. A migration file name is `<NNN>_<kebab-slug>.sql`.

4. **Suffix pattern for same-version fixes.** When a migration needed a
   same-version correction, the fix landed as a suffixed sibling
   (`011a_packs_backfill.sql`, `012a_release_seat.sql`) or a version-tagged
   name (`022_v0.12_host_tools.sql`) rather than a renumber. Prefer a
   clean new number for new work; use a suffix only for a direct
   correction of the immediately-preceding migration.

5. **RPC traceability.** Every RPC the Swift layer calls is named in the
   Swift docstring together with its defining migration (e.g. "Server
   side: `get_season_history(p_room_id)` (migration 053)"). Keep that
   contract: when you add an RPC, update the Swift wrapper's docstring in
   the same change.

6. **Function conventions.** New RPCs follow the established shape:
   `security definer`, `set search_path = public`, auth via
   `public.current_user_id()` with `raise exception ... using errcode =
   '42501'` when null, `grant execute ... to authenticated`, and a
   `comment on function` explaining the contract. Header comment blocks
   describe the change and the decisions behind it (`ponytail:` markers
   for deliberate workarounds).

7. **Apply via the CLI.** Each migration's header carries its own apply
   command (`psql ... -v ON_ERROR_STOP=1 -f <file>`). New files get the
   same block.
