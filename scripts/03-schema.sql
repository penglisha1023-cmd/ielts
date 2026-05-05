-- ============================================================
-- IELTS Listening App — Supabase Schema + RLS
-- Run this once in Supabase Dashboard → SQL Editor → New query
-- ============================================================

-- 1. profiles: 1-1 with auth.users; stores display_name etc.
create table if not exists public.profiles (
  id            uuid primary key references auth.users(id) on delete cascade,
  display_name  text not null,
  created_at    timestamptz not null default now()
);

-- 2. scores: one row per finished attempt (a student can re-attempt)
create table if not exists public.scores (
  id              bigserial primary key,
  user_id         uuid not null references auth.users(id) on delete cascade,
  test_id         int  not null,
  score           int  not null,            -- correct count
  total           int  not null,            -- total questions
  duration_secs   int  not null,
  details         jsonb,                    -- per-question correctness etc.
  finished_at     timestamptz not null default now()
);
create index if not exists scores_user_test_idx  on public.scores(user_id, test_id);
create index if not exists scores_finished_idx   on public.scores(finished_at desc);

-- 3. notes: highlights + notes per (user, test)
create table if not exists public.notes (
  id          bigserial primary key,
  user_id     uuid not null references auth.users(id) on delete cascade,
  test_id     int  not null,
  hid         text not null,                -- highlight id from front-end
  quote       text not null,                -- highlighted phrase
  note_text   text not null default '',
  updated_at  timestamptz not null default now(),
  unique (user_id, test_id, hid)
);
create index if not exists notes_user_test_idx on public.notes(user_id, test_id);

-- 4. progress: in-progress state for cross-device resume
create table if not exists public.progress (
  user_id      uuid not null references auth.users(id) on delete cascade,
  test_id      int  not null,
  answers      jsonb not null default '{}'::jsonb,
  timer_secs   int   not null default 0,
  updated_at   timestamptz not null default now(),
  primary key (user_id, test_id)
);

-- ============================================================
-- Row Level Security
-- ============================================================

alter table public.profiles enable row level security;
alter table public.scores   enable row level security;
alter table public.notes    enable row level security;
alter table public.progress enable row level security;

-- profiles: user can read/update own; insert via auth trigger
drop policy if exists "profiles read own"   on public.profiles;
drop policy if exists "profiles update own" on public.profiles;
drop policy if exists "profiles insert own" on public.profiles;
create policy "profiles read own"   on public.profiles for select using (auth.uid() = id);
create policy "profiles update own" on public.profiles for update using (auth.uid() = id);
create policy "profiles insert own" on public.profiles for insert with check (auth.uid() = id);

-- scores: insert/select own
drop policy if exists "scores rw own" on public.scores;
create policy "scores rw own" on public.scores
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- notes: rw own
drop policy if exists "notes rw own" on public.notes;
create policy "notes rw own" on public.notes
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- progress: rw own
drop policy if exists "progress rw own" on public.progress;
create policy "progress rw own" on public.progress
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- ============================================================
-- Auth trigger: auto-create profile row on signup
-- (display_name comes from raw_user_meta_data.display_name)
-- ============================================================

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, display_name)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'display_name', split_part(new.email, '@', 1))
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ============================================================
-- Storage bucket for audio files (public read)
-- Run after schema creation. If bucket already exists, ignore.
-- ============================================================

insert into storage.buckets (id, name, public)
values ('audio', 'audio', true)
on conflict (id) do nothing;

-- Allow anonymous SELECT (public read), since IELTS audio is shared content.
-- Writes are admin-only (use service_role key from local upload script).
drop policy if exists "audio public read" on storage.objects;
create policy "audio public read"
  on storage.objects for select
  using (bucket_id = 'audio');
