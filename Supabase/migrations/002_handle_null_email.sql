-- Defensive: make handle_new_user tolerate null email + null metadata
-- Ponytail: hypothesis B from v0.2 debug session. The Apple provider with "Hide My Email"
-- can return a token with email=null and raw_user_meta_data=null, which would cause
-- the original coalesce() to return NULL and fail the display_name NOT NULL constraint.
-- Adding a 'Player' fallback ensures display_name is never NULL.
create or replace function public.handle_new_user()
returns trigger as $$
begin
  insert into public.users (id, display_name)
  values (
    new.id,
    coalesce(
      new.raw_user_meta_data->>'display_name',
      split_part(coalesce(new.email, ''), '@', 1),
      'Player'
    )
  );
  return new;
end;
$$ language plpgsql security definer;