-- v0.3 pre-build: tighten generate_join_code with host check, add get_my_rooms RPC.
-- Apply via Supabase SQL Editor or:
--   PGPASSWORD='...' psql -h aws-0-ap-southeast-1.pooler.supabase.com -p 6543 \
--     -U postgres.bnrgkdcluopicqdpmrtu -d postgres -v ON_ERROR_STOP=1 \
--     -f Supabase/migrations/006_v03_prebuild.sql

-- 1. generate_join_code: add host authorization check at the top.
--    The function is SECURITY DEFINER (bypasses RLS), so authorization must
--    be explicit. The previous version trusted the caller; v0.3 enforces
--    "only the room's host can generate a code."
create or replace function public.generate_join_code(p_room_id uuid)
returns text
language plpgsql
security definer
as $$
declare
  v_caller uuid := public.current_user_id();
  v_is_host boolean;
  v_code text;
  v_attempts int := 0;
  v_alphabet text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  select exists (
    select 1 from public.rooms
    where id = p_room_id and created_by = v_caller
  ) into v_is_host;

  if not v_is_host then
    raise exception 'Only the host can generate a join code' using errcode = '42501';
  end if;

  loop
    v_attempts := v_attempts + 1;
    if v_attempts > 100 then
      raise exception 'Code generation failed after 100 attempts' using errcode = '50000';
    end if;
    v_code := '';
    for i in 1..6 loop
      v_code := v_code || substr(v_alphabet, 1 + floor(random() * length(v_alphabet))::int, 1);
    end loop;
    begin
      insert into public.join_codes (code, room_id) values (v_code, p_room_id);
      return v_code;
    exception when unique_violation then
      continue;
    end;
  end loop;
end;
$$;

-- 2. get_my_rooms: flat shape for the iOS client.
--    Returns rooms the current user is a member of, with their role per
--    room. SECURITY DEFINER (bypasses RLS) but filters by current_user_id()
--    so the result is still scoped to the caller.
create or replace function public.get_my_rooms()
returns table (
  id uuid,
  name text,
  mascot_name text,
  mascot_personality public.mascot_personality,
  created_by uuid,
  created_at timestamptz,
  updated_at timestamptz,
  is_live boolean,
  next_event_description text,
  user_role text
)
language sql
security definer
stable
as $$
  select
    r.id, r.name, r.mascot_name, r.mascot_personality,
    r.created_by, r.created_at, r.updated_at, r.is_live, r.next_event_description,
    m.role::text as user_role
  from public.rooms r
  join public.room_memberships m on m.room_id = r.id
  where m.user_id = public.current_user_id()
  order by r.updated_at desc;
$$;

grant execute on function public.get_my_rooms() to authenticated;

-- 3. RLS on join_codes: ensure only the host can read codes they generated.
--    The current schema has no policy on join_codes, meaning RLS is effectively
--    off for the table (no rows visible via PostgREST to anyone but the
--    service role). Add a read policy scoped to the host.
alter table public.join_codes enable row level security;

create policy "host can read own room codes" on public.join_codes
  for select using (
    exists (
      select 1 from public.rooms
      where id = join_codes.room_id and created_by = public.current_user_id()
    )
  );

-- Service role bypasses RLS for any admin operations (rotation, deletion).
-- The redeem_join_code() function updates join_codes directly; it's
-- SECURITY DEFINER, so the RLS check is bypassed for that path. No
-- additional policy needed.
