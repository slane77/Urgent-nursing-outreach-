-- ============================================================================
--  Urgent Nursing Outreach Manager — Schema
--  File: 01_schema.sql
--  Run this FIRST in Supabase → SQL Editor → New Query → Paste → Run.
--  Creates the three core tables, indexes, an updated_at trigger, and a
--  convenience view that joins the latest send date onto each contact.
--  Safe to run on a fresh Supabase project. Do NOT re-run blindly on a
--  populated database — it will fail on existing tables (which is intentional;
--  better to fail loudly than wipe data).
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 0. Extensions
-- ----------------------------------------------------------------------------
-- gen_random_uuid() is built into Postgres 13+ but pgcrypto is a safe belt-
-- and-braces include. Supabase has this available by default.
create extension if not exists pgcrypto;


-- ----------------------------------------------------------------------------
-- 1. Shared trigger function: auto-update the updated_at column on any UPDATE
-- ----------------------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;


-- ----------------------------------------------------------------------------
-- 2. CONTACTS table
--    Holds every GP surgery contact across all three statuses
--    (lead / live / unsubscribed). One row per email address.
-- ----------------------------------------------------------------------------
create table public.contacts (
  id            uuid primary key default gen_random_uuid(),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),

  status        text not null default 'lead'
                check (status in ('lead', 'live', 'unsubscribed')),

  -- Organisation / surgery details
  org           text not null,

  -- Contact person details
  title         text,
  first_name    text,
  last_name     text,
  job_title     text,
  email         text not null,
  phone         text,

  -- Address details
  add1          text,
  add2          text,
  town          text,
  postcode      text,
  region        text,
  country       text default 'England',

  -- Free-text notes (e.g. "BOUNCED 2026-05-18", role required, etc.)
  notes         text,

  -- Who created this row (links to Supabase auth.users). Nullable so a deleted
  -- user account doesn't cascade-delete their contributed contacts.
  created_by    uuid references auth.users(id) on delete set null
);

-- Case-insensitive uniqueness on email. "Jane.Smith@nhs.net" and
-- "jane.smith@nhs.net" are treated as the same person.
create unique index contacts_email_lower_idx
  on public.contacts (lower(email));

-- Indexes for the columns we filter on heavily
create index contacts_status_idx  on public.contacts (status);
create index contacts_region_idx  on public.contacts (region);
create index contacts_town_idx    on public.contacts (town);
create index contacts_country_idx on public.contacts (country);

-- Auto-update updated_at on every UPDATE
create trigger contacts_set_updated_at
  before update on public.contacts
  for each row
  execute function public.set_updated_at();


-- ----------------------------------------------------------------------------
-- 3. TEMPLATES table
--    Reusable email templates with merge tokens like {{FirstName}}, {{Town}}.
-- ----------------------------------------------------------------------------
create table public.templates (
  id            uuid primary key default gen_random_uuid(),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),

  name          text not null unique,
  subject       text not null,
  body          text not null,

  created_by    uuid references auth.users(id) on delete set null
);

create trigger templates_set_updated_at
  before update on public.templates
  for each row
  execute function public.set_updated_at();


-- ----------------------------------------------------------------------------
-- 4. EMAIL_SENDS table
--    One row per email actually sent. Gives you full history per contact,
--    bounce tracking, and batch analytics. Replaces the single "last_emailed"
--    field with a proper send log.
-- ----------------------------------------------------------------------------
create table public.email_sends (
  id            uuid primary key default gen_random_uuid(),
  sent_at       timestamptz not null default now(),

  contact_id    uuid not null
                references public.contacts(id) on delete cascade,
  template_id   uuid references public.templates(id) on delete set null,

  -- Group all sends from one mailshot together, e.g. "2026-05-18-practice-nurse"
  batch_id      text,

  -- Outcome tracking
  status        text not null default 'sent'
                check (status in ('sent', 'bounced', 'replied', 'opened')),
  notes         text,

  sent_by       uuid references auth.users(id) on delete set null
);

create index email_sends_contact_id_idx on public.email_sends (contact_id);
create index email_sends_sent_at_idx    on public.email_sends (sent_at desc);
create index email_sends_batch_id_idx   on public.email_sends (batch_id);
create index email_sends_status_idx     on public.email_sends (status);


-- ----------------------------------------------------------------------------
-- 5. VIEW: contacts_with_last_email
--    Joins the latest send date and total send count onto each contact row.
--    The frontend queries this instead of `contacts` directly when it needs
--    the "Last Emailed" column. Uses security_invoker so RLS still applies.
-- ----------------------------------------------------------------------------
create or replace view public.contacts_with_last_email
with (security_invoker = true)
as
select
  c.*,
  (
    select max(es.sent_at)
    from public.email_sends es
    where es.contact_id = c.id
      and es.status = 'sent'
  ) as last_emailed_at,
  (
    select count(*)
    from public.email_sends es
    where es.contact_id = c.id
      and es.status = 'sent'
  ) as total_emails_sent
from public.contacts c;


-- ----------------------------------------------------------------------------
-- 6. Sanity check — run this after the script completes to verify the tables
--    exist. Should return 3 rows: contacts, templates, email_sends.
-- ----------------------------------------------------------------------------
-- select table_name from information_schema.tables
--   where table_schema = 'public'
--   and table_name in ('contacts', 'templates', 'email_sends')
--   order by table_name;
