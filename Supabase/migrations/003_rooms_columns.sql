-- ponytail: defensive column add for missing fields used by the iOS Room model.
-- The original migration didn't include is_live / role / next_event_description because
-- they were placeholders in the iOS app. They're real fields the app needs, so add them now.

alter table public.rooms
  add column is_live boolean not null default false,
  add column role text not null default 'host' check (role in ('host', 'member')),
  add column next_event_description text;