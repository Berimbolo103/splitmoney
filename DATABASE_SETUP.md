# SplitTrip Online Database Setup

This app now supports an optional online shared trip database using Supabase.

## 1. Create a Supabase project

1. Go to https://supabase.com/
2. Create a free project.
3. Open the project dashboard.

## 2. Create the tables

1. Go to **SQL Editor**.
2. Open `supabase_schema.sql` from this folder.
3. Copy the whole file into Supabase SQL Editor.
4. Click **Run**.

This creates:

- `trips`
- `members`
- `expenses`

It also enables simple anonymous read/write policies so the static HTML app can work without accounts.

## 3. Add your Supabase keys to the app

In `index.html`, find:

```js
const SUPABASE_URL = '';
const SUPABASE_ANON_KEY = '';
```

In Supabase, go to **Project Settings > API** and copy:

- **Project URL** into `SUPABASE_URL`
- **anon public key** into `SUPABASE_ANON_KEY`

Example:

```js
const SUPABASE_URL = 'https://your-project.supabase.co';
const SUPABASE_ANON_KEY = 'your-anon-public-key';
```

## 4. Use it

1. Open the app.
2. Create a group and add members.
3. Open the group.
4. Tap **Create Online Trip**.
5. Send the online code to friends.
6. Friends tap **Join Online** on the home screen and enter the code.

The active trip syncs every 10 seconds. New expenses, archived expenses, and deleted expenses are pushed online.

## Security note

This setup is intentionally simple. Anyone with the anon key and enough technical knowledge can query the database. For a small trip expense app, this may be acceptable. For sensitive data, the next step is adding real accounts and stricter row-level security.
