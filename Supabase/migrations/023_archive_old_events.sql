-- 023: V0.22-B — 8-hour auto-archive filter on get_past_events.
-- Apply via:
--   PGPASSWORD='...' psql -h aws-0-ap-southeast-1.pooler.supabase.com -p 6543 \
--     -U postgres.bnrgkdcluopicqdpmrtu -d postgres -v ON_ERROR_STOP=1 \
--     -f Supabase/migrations/023_archive_old_events.sql
--
-- Replaces public.get_past_events with a version that returns only
-- recent events (played_at > now() - interval '8 hours'). Stale
-- events stay in the DB for analytics but are hidden from the past
-- list. No schema change.

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
    and e.played_at > now() - interval '8 hours'
  order by e.played_at desc
  limit 20;
$$;

grant execute on function public.get_past_events(uuid) to authenticated;
