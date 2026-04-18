-- SplitTrip Supabase schema
-- Run this in Supabase SQL Editor after creating a free Supabase project.
--
-- Simple sharing model:
-- - A trip is joined by share_code.
-- - The browser stores a local device id/name.
-- - Anyone with the share code can read/write that trip.
--
-- This is intentionally simple for a trip expense app. Do not use it for
-- sensitive financial records without adding real authentication and tighter RLS.

create table if not exists public.trips (
  id text primary key,
  share_code text not null unique,
  name text not null,
  emoji text,
  base_currency text not null default 'CNY',
  fx_rates jsonb not null default '{}'::jsonb,
  created_by_device text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  finalized_at timestamptz
);

create table if not exists public.members (
  id text primary key,
  trip_id text not null references public.trips(id) on delete cascade,
  name text not null,
  device_id text,
  created_at timestamptz not null default now(),
  unique (trip_id, name)
);

create table if not exists public.expenses (
  id text primary key,
  trip_id text not null references public.trips(id) on delete cascade,
  category text,
  category_icon text,
  description text,
  original_amount integer not null,
  currency text not null,
  cny_fen integer not null,
  paid_by text not null,
  split_among jsonb not null default '[]'::jsonb,
  expense_date date,
  created_by_device text,
  created_at timestamptz not null default now(),
  archived_at timestamptz
);

create index if not exists trips_share_code_idx on public.trips(share_code);
create index if not exists members_trip_id_idx on public.members(trip_id);
create index if not exists expenses_trip_id_idx on public.expenses(trip_id);
create index if not exists expenses_created_at_idx on public.expenses(created_at);

alter table public.trips enable row level security;
alter table public.members enable row level security;
alter table public.expenses enable row level security;

-- Simple anonymous policies for a share-code app.
-- These allow the public anon key to read/write app data. The share code is
-- the practical gate in the UI, not a strict database security boundary.
drop policy if exists "splittrip anon read trips" on public.trips;
create policy "splittrip anon read trips"
on public.trips for select
to anon
using (true);

drop policy if exists "splittrip anon write trips" on public.trips;
create policy "splittrip anon write trips"
on public.trips for all
to anon
using (true)
with check (true);

drop policy if exists "splittrip anon read members" on public.members;
create policy "splittrip anon read members"
on public.members for select
to anon
using (true);

drop policy if exists "splittrip anon write members" on public.members;
create policy "splittrip anon write members"
on public.members for all
to anon
using (true)
with check (true);

drop policy if exists "splittrip anon read expenses" on public.expenses;
create policy "splittrip anon read expenses"
on public.expenses for select
to anon
using (true);

drop policy if exists "splittrip anon write expenses" on public.expenses;
create policy "splittrip anon write expenses"
on public.expenses for all
to anon
using (true)
with check (true);
