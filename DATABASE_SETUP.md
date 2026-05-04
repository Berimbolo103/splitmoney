# SplitTrip Secure Online Database Setup

This app uses Supabase for online shared trips with user accounts and member-only access.

## 1. Supabase Auth

1. Open your Supabase project.
2. Go to **Authentication > Providers**.
3. Enable **Email**.
4. Go to the email provider settings and turn **Confirm email** off if you want users to create accounts and sign in immediately.

The app has a confirm-password field. Email verification is controlled by Supabase project settings, not by the HTML file.

Each person should create their own account in the app before creating or joining an online trip.

## 2. Create or update the database

1. Go to **SQL Editor**.
2. Open `supabase_schema.sql` from this folder.
3. Copy the whole file into Supabase SQL Editor.
4. Click **Run**.

This creates or updates:

- `trips`
- `trip_members`
- `members`
- `expenses`
- `payments`
- `create_trip_with_membership(...)` RPC function
- `join_trip_by_code(...)` RPC function
- member-only row-level security policies

If you previously ran the older anonymous schema, run this new file again. It removes the old anonymous policies.

## 3. Add your Supabase keys to the app

In `index.html`, find:

```js
const SUPABASE_URL = '';
const SUPABASE_ANON_KEY = '';
```

In Supabase, go to **Project Settings > API** and copy:

- **Project URL** into `SUPABASE_URL`
- **anon public key** into `SUPABASE_ANON_KEY`

The anon key is still public in frontend apps. The security now comes from Supabase Auth and RLS policies.

## 4. Use it

1. Open the app.
2. Create an account or sign in from the home screen.
3. Create a group and add split members.
4. Open the group.
5. Tap **Create Online Trip**.
6. Send the generated trip URL to friends. It looks like `...?trip=ABC123`.
7. Friends open that URL, sign in, and the app joins the trip from the link.

The active trip syncs every 10 seconds. Only signed-in users who are members of that trip can read or write that trip's online data. Expenses and paid settlement records both sync online.

## Current security model

- Trip rows are readable only by trip members.
- Split member rows are readable/writable only by trip members.
- Expense rows are readable/writable only by trip members.
- Payment rows are readable/writable only by trip members.
- Joining by code is handled by `join_trip_by_code(...)`, which creates the signed-in user's membership.
- Creating a new online trip is handled by `create_trip_with_membership(...)`, which creates the trip and creator membership together so RLS does not block the first insert.
- LocalStorage is still used as a cache and for convenience, not as the security boundary.
- The base app URL does not reveal trips. Trip URLs contain invite codes, but users still must sign in and become members before the trip data is visible.

## Remaining hardening options

- Restrict deleting expenses to the expense creator only.
- Add trip owner/admin roles.
- Add invite-code expiry or invite reset.
- Add audit history for edits/deletes.
