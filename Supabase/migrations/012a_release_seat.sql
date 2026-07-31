-- Loop C backfill: add the release_seat RPC.

create or replace function public.release_seat(p_event_id uuid)
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
  delete from public.event_seats
  where event_id = p_event_id and user_id = v_caller;
  return true;
end;
$$;

grant execute on function public.release_seat(uuid) to authenticated;
