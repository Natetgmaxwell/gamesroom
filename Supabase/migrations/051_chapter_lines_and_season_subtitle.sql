-- 051: W2.6 — chapter-line cadence + season subtitle approval mechanism.
--
-- Closes the V0.9 slice: chapter lines at settle (lean, no
-- approval) and the season-subtitle host-approval beat (the
-- mechanism is buildable; the mascot voice that proposes the
-- subtitle stays gated on Q-TONE).
--
-- Adds:
--   1. write_chapter_line(p_event_id, p_title, p_call_forward) —
--      any room member may write the chapter line for a settled
--      event. Room scope derives from the event (F-IDENT-01).
--      Upserts on the chapter_lines unique(event_id) so a
--      re-write replaces the line.
--   2. get_event_chapter_line(p_event_id) — reads the chapter
--      line for one event (nil when none). Membership-guarded.
--   3. set_season_subtitle(p_room_id, p_subtitle) — host-only.
--      Sets the active season's subtitle (the host-approval beat:
--      the host approves/edits the proposed subtitle). Empty
--      string clears it.

-- =================================================================
-- 1. write_chapter_line
-- =================================================================
create or replace function public.write_chapter_line(
  p_event_id uuid,
  p_title text,
  p_call_forward text
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := public.current_user_id();
  v_room_id uuid;
  v_settled_at timestamptz;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  -- F-IDENT-01: room scope derives from the event.
  select room_id, settled_at into v_room_id, v_settled_at
  from public.events
  where id = p_event_id;

  if v_room_id is null then
    raise exception 'Event not found' using errcode = 'P0002';
  end if;

  if not exists (
    select 1 from public.room_memberships rm
    where rm.room_id = v_room_id and rm.user_id = v_caller
  ) then
    raise exception 'Only room members can write chapter lines' using errcode = '42501';
  end if;

  if v_settled_at is null then
    raise exception 'Chapter lines can only be written after the event settles' using errcode = '22023';
  end if;

  insert into public.chapter_lines (event_id, room_id, title, call_forward)
  values (p_event_id, v_room_id, nullif(trim(p_title), ''), nullif(trim(p_call_forward), ''))
  on conflict (event_id) do update
    set title = excluded.title,
        call_forward = excluded.call_forward,
        created_at = now();

  return true;
end;
$$;

grant execute on function public.write_chapter_line(uuid, text, text) to authenticated;

comment on function public.write_chapter_line(uuid, text, text) is
  'Any room member may write the chapter line for a settled event. Room scope derives from the event (F-IDENT-01). Upserts on unique(event_id).';

-- =================================================================
-- 2. get_event_chapter_line
-- =================================================================
create or replace function public.get_event_chapter_line(p_event_id uuid)
returns public.chapter_lines
language sql
stable
security definer
set search_path = public
as $$
  select cl.*
  from public.chapter_lines cl
  where cl.event_id = p_event_id
    and exists (
      select 1 from public.events e
      join public.room_memberships rm
        on rm.room_id = e.room_id
      where e.id = p_event_id
        and rm.user_id = public.current_user_id()
    )
  limit 1;
$$;

grant execute on function public.get_event_chapter_line(uuid) to authenticated;

comment on function public.get_event_chapter_line(uuid) is
  'Returns the chapter line for one event, or NULL when none. Room scope derives from the event (F-IDENT-01).';

-- =================================================================
-- 3. set_season_subtitle
-- =================================================================
create or replace function public.set_season_subtitle(
  p_room_id uuid,
  p_subtitle text
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := public.current_user_id();
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.rooms r
    where r.id = p_room_id and r.created_by = v_caller
  ) then
    raise exception 'Only the host can set the season subtitle' using errcode = '42501';
  end if;

  update public.seasons
    set subtitle = nullif(trim(p_subtitle), '')
    where room_id = p_room_id and status = 'active';

  return true;
end;
$$;

grant execute on function public.set_season_subtitle(uuid, text) to authenticated;

comment on function public.set_season_subtitle(uuid, text) is
  'Host-only. Sets the active season''s subtitle — the host-approval beat for the mascot''s proposed subtitle (Q-TONE gates the proposing voice, not this mechanism). Empty string clears it.';
