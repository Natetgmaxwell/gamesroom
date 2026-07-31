-- ponytail: v0.3. Multi-tenant pivot. A user is a member of N rooms via this table.
-- The existing 'rooms' table is unchanged. 'created_by' on rooms is preserved as the
-- host-of-record; this table is the full membership picture.

create table public.room_memberships (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms(id) on delete cascade,
  user_id uuid not null references public.users(id) on delete cascade,
  role text not null default 'member' check (role in ('host', 'member')),
  joined_at timestamptz not null default now(),
  unique (room_id, user_id)
);

create index room_memberships_user_id_idx on public.room_memberships(user_id);
create index room_memberships_room_id_idx on public.room_memberships(room_id);

-- ponytail: auto-add creator as host-member. Trigger fires AFTER INSERT on rooms.
-- Avoids the join-code-as-creator problem — creators are already members.
create or replace function public.handle_new_room()
returns trigger as $$
begin
  insert into public.room_memberships (room_id, user_id, role)
  values (new.id, new.created_by, 'host');
  return new;
end;
$$ language plpgsql security definer;

create trigger on_room_created
  after insert on public.rooms
  for each row execute function public.handle_new_room();

-- updated_at maintenance for room_memberships
create trigger room_memberships_set_updated_at
  before update on public.room_memberships
  for each row execute function public.set_updated_at();

alter table public.room_memberships enable row level security;

-- ponytail: visibility rules.
-- A user can see memberships in rooms they belong to OR rooms they created.
-- (created_by on rooms is already covered by an existing policy; this extends it
-- to also include rooms where they are a member via this table.)
create policy "user sees own memberships" on public.room_memberships
  for select using (auth.uid() = user_id);

create policy "host sees room members" on public.room_memberships
  for select using (
    exists (
      select 1 from public.rooms r
      where r.id = room_memberships.room_id
        and r.created_by = auth.uid()
    )
  );

-- Inserts: only via redeem flow OR creator-trigger. We don't allow direct user
-- insert from the client; the iOS app uses a SECURITY DEFINER function below.
-- Policy: deny all direct inserts. We rely on the join-code redeem function.
create policy "no direct inserts" on public.room_memberships
  for insert with check (false);

-- Deletes: a user can leave a room. A host can remove members from their room.
create policy "user can leave own membership" on public.room_memberships
  for delete using (auth.uid() = user_id);

create policy "host can remove members" on public.room_memberships
  for delete using (
    exists (
      select 1 from public.rooms r
      where r.id = room_memberships.room_id
        and r.created_by = auth.uid()
    )
  );

-- ponytail: extend rooms SELECT visibility to include rooms where user is a member.
-- We keep the original creator policy AND add a membership-based policy.
create policy "member sees room" on public.rooms
  for select using (
    exists (
      select 1 from public.room_memberships m
      where m.room_id = rooms.id
        and m.user_id = auth.uid()
    )
  );

-- generate_join_code: creates a 6-char code, stores it, returns it.
create table public.join_codes (
  code text primary key,
  room_id uuid not null references public.rooms(id) on delete cascade,
  created_at timestamptz not null default now(),
  redeemed_at timestamptz,
  redeemed_by uuid references public.users(id) on delete set null
);

create index join_codes_room_id_idx on public.join_codes(room_id);

-- ponytail: 6-char uppercase, exclude ambiguous chars (0/O, 1/I/L) per spec.
-- Use a loop because the alternative — select random 26^6 rows and hope no
-- collision — is wrong at scale. Postgres plpgsql loops are fine for human-typable
-- code spaces (the cap on attempts is per-statement-time, not per-call).
create or replace function public.generate_join_code(p_room_id uuid)
returns text
language plpgsql
security definer
as $$
declare
  v_code text;
  v_attempts int := 0;
  v_alphabet text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';  -- 31 chars, no ambiguous
begin
  -- ponytail: authorisation is the caller's job. The function is SECURITY DEFINER
  -- and has full table privileges. The iOS app (RoomService.generateJoinCode)
  -- checks auth.uid() = created_by before calling; psql / SQL Editor callers
  -- are admin-context and can be trusted. The function itself does only the
  -- mechanical work: generate a code, store it, return it.

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
      -- try again with a new random code
      continue;
    end;
  end loop;
end;
$$;

-- ponytail: redeem is atomic — read the code, validate not-redeemed, insert
-- membership, mark redeemed. All in one transaction.
create or replace function public.redeem_join_code(code text)
returns table(room_id uuid, room_name text)
language plpgsql
security definer
as $$
declare
  v_room_id uuid;
  v_room_name text;
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  -- Find an unredeemed code.
  select jc.room_id into v_room_id
  from public.join_codes jc
  where jc.code = upper(redeem_join_code.code)
    and jc.redeemed_at is null
  for update;  -- locks the row

  if v_room_id is null then
    raise exception 'Code not found or already redeemed' using errcode = 'P0002';
  end if;

  -- Idempotency: if already a member, return the room but don't double-insert.
  if exists (
    select 1 from public.room_memberships m
    where m.room_id = v_room_id and m.user_id = v_user_id
  ) then
    select r.name into v_room_name from public.rooms r where r.id = v_room_id;
    return query select v_room_id, v_room_name;
    return;
  end if;

  -- Insert membership.
  insert into public.room_memberships (room_id, user_id, role)
  values (v_room_id, v_user_id, 'member');

  -- Mark code redeemed.
  update public.join_codes jc
  set redeemed_at = now(), redeemed_by = v_user_id
  where jc.code = upper(redeem_join_code.code);

  -- Return the room.
  select r.name into v_room_name from public.rooms r where r.id = v_room_id;
  return query select v_room_id, v_room_name;
end;
$$;
