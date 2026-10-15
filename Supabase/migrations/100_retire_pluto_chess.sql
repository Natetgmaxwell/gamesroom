-- 100: retire the Pluto Chess pack (Nathan, 2026-10-14: "you can remove
-- pluto chess as a game").
--
-- Soft retirement, not a delete. `packs.slug` is referenced by
-- events (on delete set null), event_packs and room_packs (on delete
-- cascade), so deleting the row would rewrite history. Instead:
--   1. packs.retired_at marks a pack as gone from the catalog.
--   2. The catalog reads (list_available_packs, get_room_packs) skip
--      retired packs, so rooms stop showing them.
--   3. A guard trigger refuses NEW references to a retired pack on
--      every write path (create_event, update_room_packs,
--      add_pack_to_room, set_room_pack_config, legacy add_event*),
--      which also covers older app builds that still list the pack.
-- Existing rows are untouched. Live check before writing: zero
-- pluto_chess rows in events / event_packs / room_packs /
-- room_pack_configs.
--
-- Idempotent. Rollback: update public.packs set retired_at = null
-- where slug = 'pluto_chess';
begin;

alter table public.packs
  add column if not exists retired_at timestamptz;

update public.packs
   set retired_at = now()
 where slug = 'pluto_chess'
   and retired_at is null;

create or replace function public.list_available_packs()
returns table(slug text, display_name text, description text, scoring_type text, win_points integer, withdraw_default integer)
language sql
stable security definer
set search_path = public
as $$
  select p.slug, p.display_name, p.description, p.scoring_type, p.win_points, p.withdraw_default
  from public.packs p
  where p.retired_at is null
  order by p.display_name;
$$;

create or replace function public.get_room_packs(p_room_id uuid)
returns table(pack_slug text)
language sql
stable security definer
set search_path = public
as $$
  select rp.pack_slug
  from public.room_packs rp
  join public.packs p on p.slug = rp.pack_slug
  where rp.room_id = p_room_id
    and p.retired_at is null
  order by rp.added_at;
$$;

create or replace function public.reject_retired_pack_slug()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.pack_slug is null then
    return new;
  end if;
  if tg_op = 'UPDATE' and new.pack_slug is not distinct from old.pack_slug then
    return new;
  end if;
  if exists (
    select 1 from public.packs p
    where p.slug = new.pack_slug and p.retired_at is not null
  ) then
    raise exception 'Pack retired: %', new.pack_slug using errcode = 'P0002';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_reject_retired_pack on public.events;
create trigger trg_reject_retired_pack
  before insert or update of pack_slug on public.events
  for each row execute function public.reject_retired_pack_slug();

drop trigger if exists trg_reject_retired_pack on public.event_packs;
create trigger trg_reject_retired_pack
  before insert or update of pack_slug on public.event_packs
  for each row execute function public.reject_retired_pack_slug();

drop trigger if exists trg_reject_retired_pack on public.room_packs;
create trigger trg_reject_retired_pack
  before insert or update of pack_slug on public.room_packs
  for each row execute function public.reject_retired_pack_slug();

drop trigger if exists trg_reject_retired_pack on public.room_pack_configs;
create trigger trg_reject_retired_pack
  before insert or update of pack_slug on public.room_pack_configs
  for each row execute function public.reject_retired_pack_slug();

commit;
