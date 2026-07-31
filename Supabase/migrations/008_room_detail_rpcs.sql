-- v0.4 pre-build: room detail RPCs.
-- Apply via:
--   PGPASSWORD='u095SPKkPpvsQwKo' psql -h aws-0-ap-southeast-1.pooler.supabase.com -p 6543 \
--     -U postgres.bnrgkdcluopicqdpmrtu -d postgres -v ON_ERROR_STOP=1 \
--     -f Supabase/migrations/008_room_detail_rpcs.sql

-- 1. get_room_members: list members of a room, host first, then alphabetical.
create or replace function public.get_room_members(p_room_id uuid)
returns table (user_id uuid, display_name text, role text)
language sql
security definer
stable
as $$
  select m.user_id, u.display_name, m.role::text
  from public.room_memberships m
  join public.users u on u.id = m.user_id
  where m.room_id = p_room_id
  order by case when m.role = 'host' then 0 else 1 end, u.display_name;
$$;

grant execute on function public.get_room_members(uuid) to authenticated;

-- 2. leave_room: member leaves a room. Host cannot leave (v0.5+ delete room).
create or replace function public.leave_room(p_room_id uuid)
returns boolean
language plpgsql
security definer
as $$
declare
  v_caller uuid := public.current_user_id();
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  if exists (select 1 from public.rooms where id = p_room_id and created_by = v_caller) then
    raise exception 'Hosts cannot leave their own room' using errcode = '42501';
  end if;

  delete from public.room_memberships
  where room_id = p_room_id and user_id = v_caller;

  return true;
end;
$$;

grant execute on function public.leave_room(uuid) to authenticated;
