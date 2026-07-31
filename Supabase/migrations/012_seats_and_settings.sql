-- v0.7: event seats + max_seats + pack-specific scoring.

-- 1. Add max_seats to rooms.
alter table public.rooms
  add column if not exists max_seats int default 6 not null;

-- 2. Update packs: add scoring_type + scoring config. Replace the v0.6
--    4-pack seed with the v0.7 2-pack seed.
delete from public.packs;
alter table public.packs
  add column if not exists scoring_type text not null default 'single_winner'
    check (scoring_type in ('single_winner', 'withdraw_return'));
alter table public.packs
  add column if not exists win_points int default 1;
alter table public.packs
  add column if not exists withdraw_default int default 10;

insert into public.packs (slug, display_name, description, scoring_type, win_points, withdraw_default) values
  ('monopoly-deal', 'Monopoly Deal', 'Card-based Monopoly. Winner takes the pot.', 'single_winner', 1, null),
  ('blackjack', 'Black Jack', 'Chip-based. Each player withdraws to start, returns winnings at end.', 'withdraw_return', null, 10);

-- 3. Add pack_slug to events (FK to packs.slug).
alter table public.events
  add column if not exists pack_slug text references public.packs(slug) on delete set null;

-- 4. Extend scores: withdrawn + returned (for withdraw_return packs).
alter table public.scores
  add column if not exists withdrawn int default 0 not null;
alter table public.scores
  add column if not exists returned int default 0 not null;

-- 5. event_seats: who has claimed a seat for an event.
create table public.event_seats (
  id uuid default gen_random_uuid() primary key,
  event_id uuid not null references public.events(id) on delete cascade,
  user_id uuid not null references public.users(id) on delete cascade,
  claimed_at timestamptz default now() not null,
  unique (event_id, user_id)
);

create index event_seats_event_id_idx on public.event_seats using btree (event_id);
create index event_seats_user_id_idx on public.event_seats using btree (user_id);

-- 6. Partial unique index: at most one upcoming event per room.
create unique index one_upcoming_event_per_room on public.events(room_id)
  where played_at > now();

-- 7. RLS for event_seats.
alter table public.event_seats enable row level security;

create policy "members can read event seats" on public.event_seats
  for select using (
    exists (select 1 from public.events e
            join public.room_memberships m on m.room_id = e.room_id
            where e.id = event_seats.event_id and m.user_id = public.current_user_id())
  );

create policy "members can claim their own seat" on public.event_seats
  for insert with check (
    user_id = public.current_user_id()
    and exists (select 1 from public.events e
                join public.room_memberships m on m.room_id = e.room_id
                where e.id = event_seats.event_id and m.user_id = public.current_user_id())
  );

create policy "members can release their own seat" on public.event_seats
  for delete using (user_id = public.current_user_id());

-- 8. RPC: claim_seat.
create or replace function public.claim_seat(p_event_id uuid)
returns boolean
language plpgsql
security definer
as $$
declare
  v_caller uuid := public.current_user_id();
  v_room_max int;
  v_seat_count int;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  select r.max_seats into v_room_max
  from public.events e
  join public.rooms r on r.id = e.room_id
  where e.id = p_event_id;

  if v_room_max is null then
    raise exception 'Event not found' using errcode = 'P0002';
  end if;

  select count(*) into v_seat_count
  from public.event_seats
  where event_id = p_event_id;

  if v_seat_count >= v_room_max then
    raise exception 'Room is full' using errcode = '42501';
  end if;

  insert into public.event_seats (event_id, user_id) values (p_event_id, v_caller)
  on conflict do nothing;
  return true;
end;
$$;

grant execute on function public.claim_seat(uuid) to authenticated;

-- 9. RPC: add_event.
create or replace function public.add_event(
  p_room_id uuid,
  p_name text,
  p_played_at timestamptz,
  p_pack_slug text
)
returns uuid
language plpgsql
security definer
as $$
declare
  v_caller uuid := public.current_user_id();
  v_event_id uuid;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  if not exists (select 1 from public.rooms where id = p_room_id and created_by = v_caller) then
    raise exception 'Only the host can create events' using errcode = '42501';
  end if;

  if p_played_at <= now() then
    raise exception 'Events must be in the future' using errcode = '22023';
  end if;

  if not exists (select 1 from public.packs where slug = p_pack_slug) then
    raise exception 'Unknown pack' using errcode = 'P0002';
  end if;

  insert into public.events (room_id, name, played_at, created_by, pack_slug)
  values (p_room_id, p_name, p_played_at, v_caller, p_pack_slug)
  returning id into v_event_id;

  return v_event_id;
exception
  when unique_violation then
    raise exception 'A room can only have one upcoming event at a time' using errcode = '23505';
end;
$$;

grant execute on function public.add_event(uuid, text, timestamptz, text) to authenticated;

-- 10. RPC: record_score.
create or replace function public.record_score(
  p_event_id uuid,
  p_user_id uuid,
  p_score int,
  p_withdrawn int default 0,
  p_returned int default 0
)
returns boolean
language plpgsql
security definer
as $$
declare
  v_caller uuid := public.current_user_id();
  v_room_id uuid;
  v_pack_slug text;
  v_scoring_type text;
  v_effective_score int;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  select e.room_id, e.pack_slug into v_room_id, v_pack_slug
  from public.events e
  where e.id = p_event_id;

  if v_room_id is null then
    raise exception 'Event not found' using errcode = 'P0002';
  end if;

  if not exists (select 1 from public.rooms where id = v_room_id and created_by = v_caller) then
    raise exception 'Only the host can record scores' using errcode = '42501';
  end if;

  select p.scoring_type into v_scoring_type
  from public.packs p
  where p.slug = v_pack_slug;

  if v_scoring_type = 'withdraw_return' then
    v_effective_score := p_returned - p_withdrawn;
  else
    v_effective_score := p_score;
    p_withdrawn := 0;
    p_returned := 0;
  end if;

  insert into public.scores (event_id, user_id, room_id, score, withdrawn, returned)
  values (p_event_id, p_user_id, v_room_id, v_effective_score, p_withdrawn, p_returned)
  on conflict (event_id, user_id) do update
    set score = excluded.score,
        withdrawn = excluded.withdrawn,
        returned = excluded.returned;

  return true;
end;
$$;

grant execute on function public.record_score(uuid, uuid, int, int, int) to authenticated;

-- 11. RPC: get_active_event.
create or replace function public.get_active_event(p_room_id uuid)
returns table (event_id uuid, name text, played_at timestamptz, seat_count int, max_seats int, pack_slug text, scoring_type text)
language sql
security definer
stable
as $$
  select e.id, e.name, e.played_at,
         (select count(*)::int from public.event_seats es where es.event_id = e.id),
         r.max_seats,
         e.pack_slug,
         p.scoring_type
  from public.events e
  join public.rooms r on r.id = e.room_id
  left join public.packs p on p.slug = e.pack_slug
  where e.room_id = p_room_id
    and e.played_at > now()
  order by e.played_at asc
  limit 1;
$$;

grant execute on function public.get_active_event(uuid) to authenticated;

-- 12. RPC: get_past_events.
create or replace function public.get_past_events(p_room_id uuid)
returns table (event_id uuid, name text, played_at timestamptz, pack_slug text, scoring_type text, winner_user_id uuid, winner_display_name text, winner_score int)
language sql
security definer
stable
as $$
  select e.id, e.name, e.played_at, e.pack_slug, p.scoring_type,
         (select s.user_id from public.scores s where s.event_id = e.id order by s.score desc limit 1) as winner_user_id,
         (select u.display_name from public.scores s join public.users u on u.id = s.user_id where s.event_id = e.id order by s.score desc limit 1) as winner_display_name,
         (select s.score from public.scores s where s.event_id = e.id order by s.score desc limit 1) as winner_score
  from public.events e
  left join public.packs p on p.slug = e.pack_slug
  where e.room_id = p_room_id
    and e.played_at <= now()
  order by e.played_at desc
  limit 20;
$$;

grant execute on function public.get_past_events(uuid) to authenticated;

-- 13. RPC: get_event_seats.
create or replace function public.get_event_seats(p_event_id uuid)
returns table (user_id uuid, display_name text, claimed_at timestamptz)
language sql
security definer
stable
as $$
  select es.user_id, u.display_name, es.claimed_at
  from public.event_seats es
  join public.users u on u.id = es.user_id
  where es.event_id = p_event_id
  order by es.claimed_at;
$$;

grant execute on function public.get_event_seats(uuid) to authenticated;

-- 14. RPC: get_event_scores.
create or replace function public.get_event_scores(p_event_id uuid)
returns table (user_id uuid, display_name text, score int, withdrawn int, returned int)
language sql
security definer
stable
as $$
  select s.user_id, u.display_name, s.score, s.withdrawn, s.returned
  from public.scores s
  join public.users u on u.id = s.user_id
  where s.event_id = p_event_id
  order by s.score desc;
$$;

grant execute on function public.get_event_scores(uuid) to authenticated;

-- 15. Update update_room.
create or replace function public.update_room(
  p_room_id uuid,
  p_name text,
  p_mascot_name text,
  p_mascot_personality public.mascot_personality,
  p_member_invite_quota int,
  p_max_seats int
)
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

  if not exists (select 1 from public.rooms where id = p_room_id and created_by = v_caller) then
    raise exception 'Only the host can edit the room' using errcode = '42501';
  end if;

  update public.rooms
  set name = p_name,
      mascot_name = p_mascot_name,
      mascot_personality = p_mascot_personality,
      member_invite_quota = p_member_invite_quota,
      max_seats = p_max_seats,
      updated_at = now()
  where id = p_room_id;

  return true;
end;
$$;

grant execute on function public.update_room(uuid, text, text, public.mascot_personality, int, int) to authenticated;

-- 16. RPC: update_user_display_name.
create or replace function public.update_user_display_name(p_display_name text)
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

  if p_display_name is null or trim(p_display_name) = '' then
    raise exception 'Display name cannot be empty' using errcode = '22023';
  end if;

  update public.users set display_name = trim(p_display_name) where id = v_caller;
  return true;
end;
$$;

grant execute on function public.update_user_display_name(text) to authenticated;
