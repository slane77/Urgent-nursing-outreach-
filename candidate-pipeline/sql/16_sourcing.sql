-- ============================================================================
--  Day Webster — Candidate Pipeline · Sourcing & attribution (Phase 2)
--  File: candidate-pipeline/sql/16_sourcing.sql
--  Run AFTER 10–15. Idempotent / additive.
--
--  STATUS: DRAFT — NOT YET APPLIED. For review only.
--
--  The backbone of the acquisition engine + control tower:
--    - vacancies          : roles we're filling (also feed Google for Jobs)
--    - adverts            : a vacancy's posting on a given channel (+ cost/ref)
--    - sourcing_campaigns : a spend/effort bucket (advert push, CV search,
--                           referral drive, re-engagement, paid ads)
--    - candidates.vacancy_id / campaign_id : attribution, so the control tower
--      can show candidates + cost-per-candidate by CHANNEL and by DISCIPLINE.
--  UK-only for now; international is a later specialist track.
-- ============================================================================

-- New sourcing channels as sources (channel-agnostic engine; one row each).
insert into candidate.sources (code, name, channel_type, default_consent_basis) values
  ('indeed',       'Indeed',                 'jobboard', 'consent'),
  ('reed',         'Reed',                   'jobboard', 'consent'),
  ('cvlibrary',    'CV-Library / Totaljobs', 'jobboard', 'consent'),
  ('google_jobs',  'Google for Jobs',        'jobboard', 'consent'),
  ('careers_site', 'Careers site / landing', 'inbound',  'consent'),
  ('paid_social',  'Paid social ads',        'social',   'consent'),
  ('reengagement', 'Re-engagement',          'other',    'consent'),
  ('cv_search',    'CV-database search',     'jobboard', 'legitimate_interest')
on conflict (code) do nothing;

-- VACANCIES -----------------------------------------------------------------
create table if not exists candidate.vacancies (
  id            uuid primary key default gen_random_uuid(),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  slug          text not null unique,                 -- public URL + Google for Jobs
  title         text not null,
  discipline_id uuid references candidate.disciplines(id) on delete set null,
  specialty_id  uuid references candidate.specialties(id) on delete set null,
  town          text,
  region        text,
  pay           text,                                 -- e.g. "Band 5" / "£18–22/hr"
  employment_type text,                               -- FULL_TIME / PART_TIME / CONTRACTOR
  description   text,                                 -- advert body (markdown)
  status        text not null default 'open' check (status in ('open','filled','closed')),
  date_posted   date default current_date,
  valid_through date,
  created_by    uuid references auth.users(id) on delete set null
);
create index if not exists vacancies_status_idx on candidate.vacancies (status);
create trigger vacancies_set_updated_at before update on candidate.vacancies
  for each row execute function candidate.set_updated_at();

-- ADVERTS (a vacancy posted to a channel) -----------------------------------
create table if not exists candidate.adverts (
  id            uuid primary key default gen_random_uuid(),
  vacancy_id    uuid not null references candidate.vacancies(id) on delete cascade,
  channel       text not null,                        -- sources.code (indeed/reed/…)
  body          text,                                 -- channel-tailored copy
  structured    jsonb,                                -- JobPosting JSON-LD (Google for Jobs)
  external_ref  text,                                 -- id returned by the board
  cost          numeric default 0,
  status        text not null default 'draft' check (status in ('draft','posted','closed','error')),
  posted_at     timestamptz,
  created_at    timestamptz not null default now()
);
create index if not exists adverts_vacancy_idx on candidate.adverts (vacancy_id);

-- SOURCING CAMPAIGNS (spend/effort buckets) ---------------------------------
create table if not exists candidate.sourcing_campaigns (
  id            uuid primary key default gen_random_uuid(),
  created_at    timestamptz not null default now(),
  name          text not null,
  kind          text not null check (kind in ('advert','cv_search','referral','reengagement','paid_ads','other')),
  channel       text,                                 -- sources.code
  discipline_id uuid references candidate.disciplines(id) on delete set null,
  budget        numeric default 0,
  spend         numeric default 0,
  status        text not null default 'active' check (status in ('active','paused','done')),
  notes         text
);

-- ATTRIBUTION on candidates -------------------------------------------------
alter table candidate.candidates add column if not exists vacancy_id  uuid references candidate.vacancies(id) on delete set null;
alter table candidate.candidates add column if not exists campaign_id uuid references candidate.sourcing_campaigns(id) on delete set null;

-- RLS: staff-only (public job pages are served via a service-role function) --
alter table candidate.vacancies          enable row level security;
alter table candidate.adverts            enable row level security;
alter table candidate.sourcing_campaigns enable row level security;
do $$
declare t text;
begin
  foreach t in array array['vacancies','adverts','sourcing_campaigns'] loop
    if not exists (select 1 from pg_policies where schemaname='candidate' and tablename=t and policyname='auth read '||t) then
      execute format('create policy "auth read %1$s"   on candidate.%1$s for select to authenticated using (candidate.is_authorized_user());', t);
      execute format('create policy "auth insert %1$s" on candidate.%1$s for insert to authenticated with check (candidate.is_authorized_user());', t);
      execute format('create policy "auth update %1$s" on candidate.%1$s for update to authenticated using (candidate.is_authorized_user()) with check (candidate.is_authorized_user());', t);
      execute format('create policy "auth delete %1$s" on candidate.%1$s for delete to authenticated using (candidate.is_authorized_user());', t);
    end if;
  end loop;
end $$;

-- CONTROL-TOWER helper view: candidates by source & discipline --------------
create or replace view candidate.intake_by_channel
with (security_invoker = true) as
select
  coalesce(s.name, 'Unattributed') as channel,
  coalesce(d.name, 'Unassigned')   as discipline,
  count(*)                         as candidates,
  count(*) filter (where c.status = 'qualified') as qualified,
  count(*) filter (where c.status in ('ready','placed')) as ready_or_placed
from candidate.candidates c
left join candidate.sources s     on s.id = c.source_id
left join candidate.disciplines d on d.id = c.discipline_id
group by 1, 2
order by candidates desc;
