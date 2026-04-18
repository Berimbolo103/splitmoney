-- SplitTrip Supabase schema with Auth + member-only access.
-- Run this whole file in Supabase SQL Editor.
--
-- Required app behavior:
-- - Users create/sign in to their own Supabase Auth accounts.
-- - A trip creator becomes the first trip member.
-- - Other signed-in users join with an invite code.
-- - Only trip members can read/write trip members and expenses.

create table if not exists public.trips (
  id text primary key,
  share_code text not null unique,
  name text not null,
  emoji text,
  base_currency text not null default 'CNY',
  fx_rates jsonb not null default '{}'::jsonb,
  created_by_device text,
  created_by_user uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  finalized_at timestamptz
);

create table if not exists public.trip_members (
  id uuid primary key default gen_random_uuid(),
  trip_id text not null references public.trips(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  display_name text not null,
  role text not null default 'member',
  created_at timestamptz not null default now(),
  unique (trip_id, user_id)
);

-- Display members used by the split calculations. This is intentionally
-- separate from auth membership because a split participant may not have
-- signed in yet.
create table if not exists public.members (
  id text primary key,
  trip_id text not null references public.trips(id) on delete cascade,
  name text not null,
  device_id text,
  created_by_user uuid references auth.users(id) on delete set null,
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
  created_by_user uuid references auth.users(id) on delete set null,
  inputted_by text,
  created_at timestamptz not null default now(),
  archived_at timestamptz
);

create table if not exists public.payments (
  id text primary key,
  trip_id text not null references public.trips(id) on delete cascade,
  from_name text not null,
  to_name text not null,
  cny_fen integer not null,
  paid_currency text not null default 'CNY',
  paid_amount integer not null,
  created_by_user uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  archived_at timestamptz
);

alter table public.trips add column if not exists created_by_user uuid references auth.users(id) on delete set null;
alter table public.members add column if not exists created_by_user uuid references auth.users(id) on delete set null;
alter table public.expenses add column if not exists created_by_user uuid references auth.users(id) on delete set null;
alter table public.expenses add column if not exists inputted_by text;

create index if not exists trips_share_code_idx on public.trips(share_code);
create index if not exists trip_members_trip_id_idx on public.trip_members(trip_id);
create index if not exists trip_members_user_id_idx on public.trip_members(user_id);
create index if not exists members_trip_id_idx on public.members(trip_id);
create index if not exists expenses_trip_id_idx on public.expenses(trip_id);
create index if not exists expenses_created_at_idx on public.expenses(created_at);
create index if not exists payments_trip_id_idx on public.payments(trip_id);
create index if not exists payments_created_at_idx on public.payments(created_at);

alter table public.trips enable row level security;
alter table public.trip_members enable row level security;
alter table public.members enable row level security;
alter table public.expenses enable row level security;
alter table public.payments enable row level security;

-- Remove the earlier simple anonymous policies if you already ran the old file.
drop policy if exists "splittrip anon read trips" on public.trips;
drop policy if exists "splittrip anon write trips" on public.trips;
drop policy if exists "splittrip anon read members" on public.members;
drop policy if exists "splittrip anon write members" on public.members;
drop policy if exists "splittrip anon read expenses" on public.expenses;
drop policy if exists "splittrip anon write expenses" on public.expenses;
drop policy if exists "splittrip anon read payments" on public.payments;
drop policy if exists "splittrip anon write payments" on public.payments;

-- Helper used by RLS policies.
create or replace function public.is_trip_member(p_trip_id text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.trip_members tm
    where tm.trip_id = p_trip_id
      and tm.user_id = auth.uid()
  );
$$;

grant execute on function public.is_trip_member(text) to authenticated;

-- Create a trip and the creator membership together. A direct insert into
-- trips cannot satisfy member-only RLS yet because the creator is not a member
-- until the membership row exists.
create or replace function public.create_trip_with_membership(
  p_id text,
  p_share_code text,
  p_name text,
  p_emoji text,
  p_base_currency text,
  p_fx_rates jsonb,
  p_display_name text,
  p_created_by_device text
)
returns table (
  id text,
  share_code text,
  name text,
  emoji text,
  base_currency text,
  fx_rates jsonb,
  created_at timestamptz,
  finalized_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_trip public.trips%rowtype;
begin
  if auth.uid() is null then
    raise exception 'Not signed in';
  end if;

  select *
  into v_trip
  from public.trips t
  where t.id = p_id;

  if found and not public.is_trip_member(v_trip.id) then
    raise exception 'You are not a member of this trip';
  end if;

  if not found then
    insert into public.trips (
      id,
      share_code,
      name,
      emoji,
      base_currency,
      fx_rates,
      created_by_device,
      created_by_user,
      updated_at
    )
    values (
      p_id,
      upper(trim(p_share_code)),
      p_name,
      p_emoji,
      coalesce(p_base_currency, 'CNY'),
      coalesce(p_fx_rates, '{}'::jsonb),
      p_created_by_device,
      auth.uid(),
      now()
    )
    returning * into v_trip;
  else
    update public.trips
    set
      name = p_name,
      emoji = p_emoji,
      base_currency = coalesce(p_base_currency, base_currency),
      fx_rates = coalesce(p_fx_rates, fx_rates),
      updated_at = now()
    where public.trips.id = v_trip.id
    returning * into v_trip;
  end if;

  insert into public.trip_members (trip_id, user_id, display_name, role)
  values (v_trip.id, auth.uid(), coalesce(nullif(trim(p_display_name), ''), 'Member'), 'member')
  on conflict (trip_id, user_id)
  do update set display_name = excluded.display_name;

  return query
  select
    v_trip.id,
    v_trip.share_code,
    v_trip.name,
    v_trip.emoji,
    v_trip.base_currency,
    v_trip.fx_rates,
    v_trip.created_at,
    v_trip.finalized_at;
end;
$$;

grant execute on function public.create_trip_with_membership(text, text, text, text, text, jsonb, text, text) to authenticated;

-- Trips: creators can insert; members can read/update/delete.
drop policy if exists "splittrip members read trips" on public.trips;
create policy "splittrip members read trips"
on public.trips for select
to authenticated
using (public.is_trip_member(id));

drop policy if exists "splittrip authenticated create trips" on public.trips;
create policy "splittrip authenticated create trips"
on public.trips for insert
to authenticated
with check (created_by_user = auth.uid());

drop policy if exists "splittrip members update trips" on public.trips;
create policy "splittrip members update trips"
on public.trips for update
to authenticated
using (public.is_trip_member(id))
with check (public.is_trip_member(id));

drop policy if exists "splittrip members delete trips" on public.trips;
create policy "splittrip members delete trips"
on public.trips for delete
to authenticated
using (public.is_trip_member(id));

-- Auth trip members: members can see the trip member list; users can create
-- their own membership row. Joining by share code uses the RPC below.
drop policy if exists "splittrip members read trip_members" on public.trip_members;
create policy "splittrip members read trip_members"
on public.trip_members for select
to authenticated
using (public.is_trip_member(trip_id));

drop policy if exists "splittrip users add own trip_membership" on public.trip_members;
create policy "splittrip users add own trip_membership"
on public.trip_members for insert
to authenticated
with check (user_id = auth.uid());

drop policy if exists "splittrip users update own trip_membership" on public.trip_members;
create policy "splittrip users update own trip_membership"
on public.trip_members for update
to authenticated
using (user_id = auth.uid())
with check (user_id = auth.uid());

drop policy if exists "splittrip users delete own trip_membership" on public.trip_members;
create policy "splittrip users delete own trip_membership"
on public.trip_members for delete
to authenticated
using (user_id = auth.uid());

-- Display split members.
drop policy if exists "splittrip members read members" on public.members;
create policy "splittrip members read members"
on public.members for select
to authenticated
using (public.is_trip_member(trip_id));

drop policy if exists "splittrip members insert members" on public.members;
create policy "splittrip members insert members"
on public.members for insert
to authenticated
with check (public.is_trip_member(trip_id));

drop policy if exists "splittrip members update members" on public.members;
create policy "splittrip members update members"
on public.members for update
to authenticated
using (public.is_trip_member(trip_id))
with check (public.is_trip_member(trip_id));

drop policy if exists "splittrip members delete members" on public.members;
create policy "splittrip members delete members"
on public.members for delete
to authenticated
using (public.is_trip_member(trip_id));

-- Expenses.
drop policy if exists "splittrip members read expenses" on public.expenses;
create policy "splittrip members read expenses"
on public.expenses for select
to authenticated
using (public.is_trip_member(trip_id));

drop policy if exists "splittrip members insert expenses" on public.expenses;
create policy "splittrip members insert expenses"
on public.expenses for insert
to authenticated
with check (public.is_trip_member(trip_id));

drop policy if exists "splittrip members update expenses" on public.expenses;
create policy "splittrip members update expenses"
on public.expenses for update
to authenticated
using (public.is_trip_member(trip_id))
with check (public.is_trip_member(trip_id));

drop policy if exists "splittrip members delete expenses" on public.expenses;
create policy "splittrip members delete expenses"
on public.expenses for delete
to authenticated
using (public.is_trip_member(trip_id));

-- Settlement payments.
drop policy if exists "splittrip members read payments" on public.payments;
create policy "splittrip members read payments"
on public.payments for select
to authenticated
using (public.is_trip_member(trip_id));

drop policy if exists "splittrip members insert payments" on public.payments;
create policy "splittrip members insert payments"
on public.payments for insert
to authenticated
with check (public.is_trip_member(trip_id));

drop policy if exists "splittrip members update payments" on public.payments;
create policy "splittrip members update payments"
on public.payments for update
to authenticated
using (public.is_trip_member(trip_id))
with check (public.is_trip_member(trip_id));

drop policy if exists "splittrip members delete payments" on public.payments;
create policy "splittrip members delete payments"
on public.payments for delete
to authenticated
using (public.is_trip_member(trip_id));

-- Join by invite code. This is needed because trip rows are member-only,
-- so non-members cannot directly select a trip by share_code.
create or replace function public.join_trip_by_code(
  p_share_code text,
  p_display_name text
)
returns table (
  id text,
  share_code text,
  name text,
  emoji text,
  base_currency text,
  fx_rates jsonb,
  created_at timestamptz,
  finalized_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_trip public.trips%rowtype;
begin
  select *
  into v_trip
  from public.trips t
  where t.share_code = upper(trim(p_share_code));

  if not found then
    raise exception 'No trip found for that code';
  end if;

  insert into public.trip_members (trip_id, user_id, display_name)
  values (v_trip.id, auth.uid(), coalesce(nullif(trim(p_display_name), ''), 'Member'))
  on conflict (trip_id, user_id)
  do update set display_name = excluded.display_name;

  return query
  select
    v_trip.id,
    v_trip.share_code,
    v_trip.name,
    v_trip.emoji,
    v_trip.base_currency,
    v_trip.fx_rates,
    v_trip.created_at,
    v_trip.finalized_at;
end;
$$;

grant execute on function public.join_trip_by_code(text, text) to authenticated;
