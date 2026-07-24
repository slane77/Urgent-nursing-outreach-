-- ============================================================================
--  Day Webster — Candidate Pipeline · matching features + attribution (Phase 2)
--  File: candidate-pipeline/sql/21_candidate_matching.sql
--  Run AFTER 10–20. Idempotent / additive.
--
--  STATUS: DRAFT — NOT YET APPLIED. For review only.
--
--  Turns the golden record from a compliance filing cabinet into a sourcing &
--  matching engine. Adds the nursing "features" recruiters actually match on
--  (band, pay, travel radius, geo, structured availability, registration
--  detail, DBS, right-to-work), a multi-skill join, a referrals ledger, and the
--  lookup indexes the ingest paths need. All additive — no existing column or
--  row is changed.
-- ============================================================================

-- MATCHING + COMPLIANCE columns on the golden record -------------------------
alter table candidate.candidates
  add column if not exists band                 text,            -- e.g. 'Band 5'
  add column if not exists pay_expectation       numeric,         -- amount
  add column if not exists pay_period            text
    check (pay_period is null or pay_period in ('hour','day','week','annum')),
  add column if not exists max_travel_miles      int,             -- willing travel radius
  add column if not exists latitude              double precision,
  add column if not exists longitude             double precision,
  add column if not exists available_from        date,            -- earliest start
  add column if not exists notice_period         text,            -- e.g. '1 week'
  add column if not exists has_car               boolean,
  add column if not exists driving_licence       boolean,
  add column if not exists cv_path               text,            -- storage path to CV
  add column if not exists ni_number             text,            -- identity / payroll / dedup
  -- Registration detail (PIN is stored, NEVER AI-verified — §7).
  add column if not exists register_part         text,            -- 'RN Adult','RN MH','RM',…
  add column if not exists revalidation_date     date,            -- NMC revalidation due
  add column if not exists registration_status   text default 'unverified'
    check (registration_status in ('unverified','verified','failed')),
  add column if not exists registration_verified_at timestamptz,
  -- Right to work + DBS.
  add column if not exists visa_type             text,
  add column if not exists visa_expiry           date,
  add column if not exists rtw_share_code        text,            -- Home Office share code
  add column if not exists dbs_number            text,
  add column if not exists dbs_update_service    boolean,         -- on the DBS Update Service
  add column if not exists dbs_checked_on        date;

-- Lookup indexes the ingest/dedup paths rely on (email is stored lowercased
-- everywhere, so a plain btree is usable by `.eq("email", …)`). The email index
-- is UNIQUE so the CSV importer can upsert idempotently on it (onConflict=email);
-- multiple NULL emails are still allowed (phone-only rows). Existing data is
-- already unique on lower(email) from 10_candidate_schema, so this can't clash.
create unique index if not exists candidates_email_idx on candidate.candidates (email);
create index if not exists candidates_phone_idx on candidate.candidates (phone);
create index if not exists candidates_ni_idx    on candidate.candidates (ni_number)
  where ni_number is not null;

-- MULTI-SKILL: a candidate can hold several specialties (ITU + A&E, scrub +
-- recovery). primary_specialty_id stays on candidates; this is the full set.
create table if not exists candidate.candidate_specialties (
  candidate_id uuid not null references candidate.candidates(id) on delete cascade,
  specialty_id uuid not null references candidate.specialties(id) on delete cascade,
  added_at     timestamptz not null default now(),
  primary key (candidate_id, specialty_id)
);
create index if not exists candidate_specialties_spec_idx
  on candidate.candidate_specialties (specialty_id);

-- REFERRALS ledger: "refer a friend, earn £250" as data, so the cheapest
-- channel is visible to the control tower and rewards can be tracked.
create table if not exists candidate.referrals (
  id                    uuid primary key default gen_random_uuid(),
  created_at            timestamptz not null default now(),
  referrer_candidate_id uuid references candidate.candidates(id) on delete set null,
  referred_candidate_id uuid references candidate.candidates(id) on delete set null,
  referred_name         text,
  referred_email        text,
  referred_phone        text,
  referred_discipline_code text,
  campaign_id           uuid references candidate.sourcing_campaigns(id) on delete set null,
  reward_status         text not null default 'pending'
    check (reward_status in ('pending','placed','paid','void')),
  reward_amount         numeric
);
create index if not exists referrals_referrer_idx on candidate.referrals (referrer_candidate_id);

-- A few more sources so `heard_about` attribution has somewhere to land
-- (the intake handler get-or-creates anything not listed here).
insert into candidate.sources (code, name, channel_type, default_consent_basis) values
  ('nhs_jobs',      'NHS Jobs',           'jobboard', 'consent'),
  ('google_search', 'Google search',      'other',    'consent'),
  ('social',        'Social media',       'social',   'consent'),
  ('word_of_mouth', 'Word of mouth',      'other',    'consent'),
  ('staff_referral','Day Webster staff',  'other',    'consent'),
  ('event',         'Job fair / event',   'other',    'consent'),
  ('flyer',         'Flyer / poster / QR','other',    'consent')
on conflict (code) do nothing;

-- RLS: staff-only, same pattern as 16_sourcing -------------------------------
alter table candidate.candidate_specialties enable row level security;
alter table candidate.referrals             enable row level security;
do $$
declare t text;
begin
  foreach t in array array['candidate_specialties','referrals'] loop
    if not exists (select 1 from pg_policies where schemaname='candidate' and tablename=t and policyname='auth read '||t) then
      execute format('create policy "auth read %1$s"   on candidate.%1$s for select to authenticated using (candidate.is_authorized_user());', t);
      execute format('create policy "auth insert %1$s" on candidate.%1$s for insert to authenticated with check (candidate.is_authorized_user());', t);
      execute format('create policy "auth update %1$s" on candidate.%1$s for update to authenticated using (candidate.is_authorized_user()) with check (candidate.is_authorized_user());', t);
      execute format('create policy "auth delete %1$s" on candidate.%1$s for delete to authenticated using (candidate.is_authorized_user());', t);
    end if;
  end loop;
end $$;
