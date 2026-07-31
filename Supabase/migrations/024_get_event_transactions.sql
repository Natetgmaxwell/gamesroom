-- 024: V0.23 — get_event_transactions RPC.
-- Apply via:
--   PGPASSWORD='...' psql -h aws-0-ap-southeast-1.pooler.supabase.com -p 6543 \
--     -U postgres.bnrgkdcluopicqdpmrtu -d postgres -v ON_ERROR_STOP=1 \
--     -f Supabase/migrations/024_get_event_transactions.sql
--
-- Adds:
--   * public.get_event_transactions(p_event_id uuid)
--     Returns all transactions (withdrawals + settlements + future kinds)
--     for a given event, joined with the member's display_name.
--     Used by the host-only live transactions tab in RoomDetailView
--     and the past event transactions section in EventDetailView.

create or replace function public.get_event_transactions(
  p_event_id uuid
) returns table (
  id uuid,
  member_id uuid,
  member_display_name text,
  kind text,
  amount_points bigint,
  meta jsonb,
  created_at timestamptz
) language sql security definer stable
as $$
  select t.id, t.member_id, u.display_name,
         t.kind, t.amount_points, t.meta, t.created_at
  from public.transactions t
  join public.users u on u.id = t.member_id
  where t.session_id = p_event_id
  order by t.created_at asc;
$$;

grant execute on function public.get_event_transactions(uuid) to authenticated;
