-- DialTone.Med waitlist/contact form schema
-- Run this in Supabase SQL Editor for the target project.
--
-- This script is intentionally dual-purpose:
-- 1) Bootstrap: creates `waitlist_submissions` when it does not exist.
-- 2) Migration: applies additive/backfill/idempotent updates for existing
--    environments so older table shapes converge on the current schema.
--
-- Keeping both behaviors in one file allows fresh and long-lived projects
-- to run the same SQL safely during setup or remediation.

begin;

create table if not exists public.waitlist_submissions (
  id bigint generated always as identity primary key,
  email text not null,
  name text not null,
  company_name text,
  restaurant_name text,
  campaign text not null default 'Med Launch',
  comment text,
  created_at timestamptz not null default now()
);

alter table public.waitlist_submissions
  add column if not exists company_name text;

alter table public.waitlist_submissions
  add column if not exists restaurant_name text;

alter table public.waitlist_submissions
  add column if not exists campaign text;

alter table public.waitlist_submissions
  add column if not exists comment text;

update public.waitlist_submissions
set company_name = restaurant_name
where company_name is null and restaurant_name is not null;

update public.waitlist_submissions
set restaurant_name = company_name
where restaurant_name is null and company_name is not null;

update public.waitlist_submissions
set restaurant_name = name
where restaurant_name is null;

update public.waitlist_submissions
set company_name = name
where company_name is null;

alter table public.waitlist_submissions
  alter column company_name set not null;

update public.waitlist_submissions
set campaign = 'Med Launch'
where campaign is null
  or lower(campaign) = 'launch'
  or lower(campaign) = 'med launch';

alter table public.waitlist_submissions
  alter column restaurant_name set not null;

alter table public.waitlist_submissions
  alter column campaign set default 'Med Launch';

alter table public.waitlist_submissions
  alter column campaign set not null;

create index if not exists idx_waitlist_submissions_created_at
  on public.waitlist_submissions (created_at desc);

create index if not exists idx_waitlist_submissions_email
  on public.waitlist_submissions (email);

alter table public.waitlist_submissions enable row level security;

grant usage on schema public to anon, authenticated;
grant insert on public.waitlist_submissions to anon, authenticated;
grant usage, select on sequence public.waitlist_submissions_id_seq to anon, authenticated;

drop policy if exists "waitlist_insert_anon" on public.waitlist_submissions;
create policy "waitlist_insert_anon"
  on public.waitlist_submissions
  for insert
  to anon
  with check (true);

drop policy if exists "waitlist_insert_authenticated" on public.waitlist_submissions;
create policy "waitlist_insert_authenticated"
  on public.waitlist_submissions
  for insert
  to authenticated
  with check (true);

drop policy if exists "waitlist_select_authenticated" on public.waitlist_submissions;
create policy "waitlist_select_authenticated"
  on public.waitlist_submissions
  for select
  to authenticated
  using (true);

commit;