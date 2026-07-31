-- v0.3 spec compliance: member-generated invite codes with host-set quota.
-- Apply via:
--   PGPASSWORD='...' psql -h aws-0-ap-southeast-1.pooler.supabase.com -p 6543 \
--     -U postgres.bnrgkdcluopicqdpmrtu -d postgres -v ON_ERROR_STOP=1 \
--     -f Supabase/migrations/007_member_invite_quota.sql

-- 1. Per-room member invite quota (host-controlled). Default 3 codes per season per member.
alter table public.rooms
  add column if not exists member_invite_quota int default 3 not null;

-- 2. Track which user generated each code, so we can count per-member usage.
alter table public.join_codes
  add column if not exists generated_by uuid references public.users(id) on delete set null;

-- 3. RLS: members can read codes they generated (in addition to host reading all room codes).
drop policy if exists "host can read own room codes" on public.join_codes;
create policy "host can read own room codes" on public.join_codes
  for select using (
    exists (
      select 1 from public.rooms
      where id = join_codes.room_id and created_by = public.current_user_id()
    )
  );
create policy "member can read own generated codes" on public.join_codes
  for select using (generated_by = public.current_user_id());

-- 4. generate_join_code: host unlimited, members quota-limited.
create or replace function public.generate_join_code(p_room_id uuid)
returns text
language plpgsql
security definer
as $$
declare
  v_caller uuid := public.current_user_id();
  v_role text;
  v_quota int;
  v_used int;
  v_code text;
  v_attempts int := 0;
  v_alphabet text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  -- look up the caller's role and the room's quota
  select m.role, r.member_invite_quota
    into v_role, v_quota
  from public.rooms r
  join public.room_memberships m on m.room_id = r.id
  where r.id = p_room_id
    and m.user_id = v_caller;

  if v_role is null then
    raise exception 'Not a member of this room' using errcode = '42501';
  end if;

  -- ponytail: host is unlimited; member is quota-limited per-room per-season.
  -- Quota resets implicitly when the season ends and room_memberships rows are pruned.
  if v_role = 'member' then
    select count(*) into v_used
    from public.join_codes
    where room_id = p_room_id
      and generated_by = v_caller
      and redeemed_at is null;
    if v_used >= v_quota then
      raise exception 'Member invite quota exhausted (% of % remaining)', (v_quota - v_used), v_quota
        using errcode = '42501';
    end if;
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
      insert into public.join_codes (code, room_id, generated_by) values (v_code, p_room_id, v_caller);
      return v_code;
    exception when unique_violation then
      continue;
    end;
  end loop;
end;
$$;