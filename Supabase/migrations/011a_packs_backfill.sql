-- v0.7 backfill part 2: create the packs table that v0.6 was supposed to create
-- but the migration was never applied. The v0.6 spec assumed this existed.
create table public.packs (
  slug text primary key,
  display_name text not null,
  description text,
  created_at timestamptz default now() not null
);

create index packs_created_at_idx on public.packs using btree (created_at);

-- RLS for packs: anyone authenticated can read.
alter table public.packs enable row level security;

create policy "anyone can read packs" on public.packs
  for select using (auth.role() = 'authenticated');
