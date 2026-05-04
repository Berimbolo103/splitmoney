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
  kind text not null default 'travel' check (kind in ('travel','general','mahjong')),
  emoji text,
  cover_photo text,
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
  status text not null default 'pending' check (status in ('pending','approved','declined')),
  requested_at timestamptz not null default now(),
  responded_at timestamptz,
  responded_by uuid references auth.users(id) on delete set null,
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
  claimed_by_user uuid references auth.users(id) on delete set null,
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
alter table public.trips add column if not exists kind text not null default 'travel';
alter table public.trips add column if not exists cover_photo text;
alter table public.members add column if not exists claimed_by_user uuid references auth.users(id) on delete set null;
alter table public.trip_members add column if not exists status text not null default 'pending';
alter table public.trip_members add column if not exists requested_at timestamptz not null default now();
alter table public.trip_members add column if not exists responded_at timestamptz;
alter table public.trip_members add column if not exists responded_by uuid references auth.users(id) on delete set null;
alter table public.members add column if not exists created_by_user uuid references auth.users(id) on delete set null;
alter table public.expenses add column if not exists created_by_user uuid references auth.users(id) on delete set null;
alter table public.expenses add column if not exists inputted_by text;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'trip_members_status_check'
      and conrelid = 'public.trip_members'::regclass
  ) then
    alter table public.trip_members
      add constraint trip_members_status_check
      check (status in ('pending','approved','declined'));
  end if;
end;
$$;

-- Preserve access for trips created before approval states existed.
update public.trip_members
set status = 'approved',
    responded_at = coalesce(responded_at, now()),
    responded_by = coalesce(responded_by, user_id)
where status is null or status = 'pending';

update public.trip_members tm
set role = 'owner'
from public.trips t
where tm.trip_id = t.id
  and tm.user_id = t.created_by_user;

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

-- Public bucket for uploaded trip cover photos.
insert into storage.buckets (id, name, public)
values ('trip-covers', 'trip-covers', true)
on conflict (id) do update set public = excluded.public;

drop policy if exists "splittrip public read trip covers" on storage.objects;
create policy "splittrip public read trip covers"
on storage.objects for select
to public
using (bucket_id = 'trip-covers');

drop policy if exists "splittrip authenticated upload trip covers" on storage.objects;
create policy "splittrip authenticated upload trip covers"
on storage.objects for insert
to authenticated
with check (bucket_id = 'trip-covers');

drop policy if exists "splittrip authenticated update trip covers" on storage.objects;
create policy "splittrip authenticated update trip covers"
on storage.objects for update
to authenticated
using (bucket_id = 'trip-covers')
with check (bucket_id = 'trip-covers');

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
      and tm.status = 'approved'
  );
$$;

grant execute on function public.is_trip_member(text) to authenticated;

drop function if exists public.is_trip_owner(text) cascade;
create or replace function public.is_trip_manager(p_trip_id text)
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
      and tm.status = 'approved'
      and tm.role in ('owner','manager')
  );
$$;

create or replace function public.is_trip_owner(p_trip_id text)
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
      and tm.status = 'approved'
      and tm.role = 'owner'
  ) or exists (
    select 1
    from public.trips t
    where t.id = p_trip_id
      and t.created_by_user = auth.uid()
  );
$$;

grant execute on function public.is_trip_manager(text) to authenticated;
grant execute on function public.is_trip_owner(text) to authenticated;

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

  insert into public.trip_members (trip_id, user_id, display_name, role, status, responded_at, responded_by)
  values (v_trip.id, auth.uid(), coalesce(nullif(trim(p_display_name), ''), 'Member'), 'owner', 'approved', now(), auth.uid())
  on conflict (trip_id, user_id)
  do update set
    display_name = excluded.display_name,
    role = 'owner',
    status = 'approved',
    responded_at = now(),
    responded_by = auth.uid();

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
using (public.is_trip_manager(id))
with check (public.is_trip_manager(id));

drop policy if exists "splittrip members delete trips" on public.trips;
create policy "splittrip members delete trips"
on public.trips for delete
to authenticated
using (public.is_trip_owner(id));

-- Auth trip members: members can see the trip member list; users can create
-- their own membership row. Joining by share code uses the RPC below.
drop policy if exists "splittrip members read trip_members" on public.trip_members;
create policy "splittrip members read trip_members"
on public.trip_members for select
to authenticated
using (public.is_trip_member(trip_id));

drop policy if exists "splittrip users add own trip_membership" on public.trip_members;
drop policy if exists "splittrip no direct trip_membership insert" on public.trip_members;
create policy "splittrip no direct trip_membership insert"
on public.trip_members for insert
to authenticated
with check (false);

drop policy if exists "splittrip users update own trip_membership" on public.trip_members;
drop policy if exists "splittrip users update own pending display name" on public.trip_members;
drop policy if exists "splittrip no direct trip_membership update" on public.trip_members;
create policy "splittrip no direct trip_membership update"
on public.trip_members for update
to authenticated
using (false)
with check (false);

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
with check (public.is_trip_manager(trip_id));

drop policy if exists "splittrip members update members" on public.members;
create policy "splittrip members update members"
on public.members for update
to authenticated
using (public.is_trip_manager(trip_id) or claimed_by_user = auth.uid())
with check (public.is_trip_manager(trip_id) or claimed_by_user = auth.uid());

drop policy if exists "splittrip members delete members" on public.members;
create policy "splittrip members delete members"
on public.members for delete
to authenticated
using (public.is_trip_manager(trip_id));

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

-- Join by invite code. Users who know the code become approved members.
drop function if exists public.join_trip_by_code(text, text);
create or replace function public.join_trip_by_code(
  p_share_code text,
  p_display_name text
)
returns table (
  id text,
  share_code text,
  name text,
  emoji text,
  cover_photo text,
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

  if exists (select 1 from public.members m where m.trip_id = v_trip.id)
     and not exists (
       select 1 from public.members m
       where m.trip_id = v_trip.id
         and lower(m.name) = lower(coalesce(nullif(trim(p_display_name), ''), 'Member'))
         and (m.claimed_by_user is null or m.claimed_by_user = auth.uid())
     ) then
    raise exception 'Pick one of the member names added by the owner';
  end if;

  insert into public.trip_members (trip_id, user_id, display_name, role, status, requested_at, responded_at, responded_by)
  values (v_trip.id, auth.uid(), coalesce(nullif(trim(p_display_name), ''), 'Member'), 'member', 'approved', now(), now(), auth.uid())
  on conflict (trip_id, user_id)
  do update set
    display_name = excluded.display_name,
    status = 'approved',
    responded_at = now(),
    responded_by = auth.uid();

  insert into public.members (id, trip_id, name, created_by_user)
  values (
    v_trip.id || ':' || lower(regexp_replace(coalesce(nullif(trim(p_display_name), ''), 'Member'), '\s+', '-', 'g')),
    v_trip.id,
    coalesce(nullif(trim(p_display_name), ''), 'Member'),
    auth.uid()
  )
  on conflict (trip_id, name) do nothing;

  update public.members
  set claimed_by_user = auth.uid()
  where trip_id = v_trip.id
    and lower(name) = lower(coalesce(nullif(trim(p_display_name), ''), 'Member'))
    and (claimed_by_user is null or claimed_by_user = auth.uid());

  return query
  select
    v_trip.id,
    v_trip.share_code,
    v_trip.name,
    v_trip.emoji,
    v_trip.cover_photo,
    v_trip.base_currency,
    v_trip.fx_rates,
    v_trip.created_at,
    v_trip.finalized_at;
end;
$$;

grant execute on function public.join_trip_by_code(text, text) to authenticated;
drop function if exists public.respond_trip_join_request(text, uuid, text);

drop function if exists public.preview_trip_join_options(text);
create or replace function public.preview_trip_join_options(p_share_code text)
returns table (name text)
language sql
security definer
set search_path = public
as $$
  select m.name
  from public.members m
  join public.trips t on t.id = m.trip_id
  where t.share_code = upper(trim(p_share_code))
    and (m.claimed_by_user is null or m.claimed_by_user = auth.uid())
  order by m.created_at asc, m.name asc;
$$;

grant execute on function public.preview_trip_join_options(text) to authenticated;

drop function if exists public.set_trip_member_role(text, uuid, text);
create or replace function public.set_trip_member_role(
  p_trip_id text,
  p_user_id uuid,
  p_role text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_trip_owner(p_trip_id) then
    raise exception 'Only the owner can change manager permissions';
  end if;
  if p_role not in ('manager','member') then
    raise exception 'Invalid role';
  end if;
  update public.trip_members
  set role = p_role
  where trip_id = p_trip_id
    and user_id = p_user_id
    and role <> 'owner';
end;
$$;

grant execute on function public.set_trip_member_role(text, uuid, text) to authenticated;

drop function if exists public.rename_my_trip_member(text, text);
create or replace function public.rename_my_trip_member(
  p_old_name text,
  p_new_name text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.trip_members
  set display_name = trim(p_new_name)
  where user_id = auth.uid()
    and lower(display_name) = lower(trim(p_old_name));

  update public.members
  set name = trim(p_new_name)
  where claimed_by_user = auth.uid()
    and lower(name) = lower(trim(p_old_name));

  update public.expenses
  set
    paid_by = case when lower(paid_by) = lower(trim(p_old_name)) then trim(p_new_name) else paid_by end,
    split_among = (
      select jsonb_agg(case when lower(value #>> '{}') = lower(trim(p_old_name)) then to_jsonb(trim(p_new_name)) else value end)
      from jsonb_array_elements(split_among)
    ),
    inputted_by = case when lower(coalesce(inputted_by, '')) = lower(trim(p_old_name)) then trim(p_new_name) else inputted_by end
  where trip_id in (select trip_id from public.members where claimed_by_user = auth.uid())
    and (
      lower(paid_by) = lower(trim(p_old_name))
      or lower(coalesce(inputted_by, '')) = lower(trim(p_old_name))
      or split_among ? trim(p_old_name)
    );

  update public.payments
  set
    from_name = case when lower(from_name) = lower(trim(p_old_name)) then trim(p_new_name) else from_name end,
    to_name = case when lower(to_name) = lower(trim(p_old_name)) then trim(p_new_name) else to_name end
  where trip_id in (select trip_id from public.members where claimed_by_user = auth.uid())
    and (lower(from_name) = lower(trim(p_old_name)) or lower(to_name) = lower(trim(p_old_name)));
end;
$$;

grant execute on function public.rename_my_trip_member(text, text) to authenticated;
