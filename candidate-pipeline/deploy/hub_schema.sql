-- ============================================================================
-- Day Webster Compliance Portal — full schema for a CLEAN Supabase project
-- (Day Webster Hub). Paste this whole file into the SQL Editor and Run.
-- Built from candidate-pipeline/sql/ migrations 10-52 (verified, in order).
-- After running: Settings -> API -> Exposed schemas -> add 'candidate'.
-- ============================================================================

-- ==== sql/10_candidate_schema.sql ====
-- ============================================================================
--  Day Webster — Candidate Pipeline  ·  Schema
--  File: candidate-pipeline/sql/10_candidate_schema.sql
--
--  STATUS: DRAFT — NOT YET APPLIED TO ANY DATABASE. For review only.
--
--  ISOLATION CONTRACT (read first):
--    This is a brand-new, self-contained system that lives in its OWN Postgres
--    schema `candidate`. It does NOT read, write, alter or depend on the
--    existing `public` tables (contacts, email_sends, email_events, templates,
--    sender_addresses, …). Those are the CLIENT/EMPLOYER OUTREACH system and
--    are out of scope and untouched. The two systems share a database server
--    and an auth provider — nothing else.
--
--  WHAT THIS IS:
--    The candidate bench / golden record — the front end of the recruiter
--    machine (prospect -> engage -> qualify -> begin compliance), and the
--    canonical record the compliance engine reconciles against (see the
--    Compliance Automation Feasibility Assessment, esp. §8a cross-pack
--    reconciliation and §8f references). Designed to be the eventual system of
--    record, with an integration boundary to sync into Eclipse later.
--
--  DESIGN NOTES:
--    - Multi-discipline from day one: discipline -> specialty taxonomy.
--    - The compliance checklist is CONFIG-DRIVEN (the §2 "one engine, config
--      table" thesis): requirements are rows, not code. The rows themselves
--      get imported from the compliance project later — the structure is ready
--      now, the content is pluggable.
--    - Employment timeline + name variants exist specifically to support the
--      ≥3-year reference coverage gap-analysis and maiden/married/reordered
--      name reconciliation called out in the assessment.
--    - Every candidate-facing channel (email/SMS/WhatsApp/web) lands in one
--      message log — the agent's memory and the inbound-email landing zone.
-- ============================================================================

create extension if not exists pgcrypto;

create schema if not exists candidate;

-- Shared updated_at trigger (scoped to this schema; does not touch public's)
create or replace function candidate.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;


-- ----------------------------------------------------------------------------
-- 1. DISCIPLINES — top-level business areas (day-one set from the brief)
-- ----------------------------------------------------------------------------
create table candidate.disciplines (
  id          uuid primary key default gen_random_uuid(),
  code        text not null unique,          -- machine key, e.g. 'nursing'
  name        text not null,                 -- display, e.g. 'Nursing'
  regulator   text,                          -- NMC / GMC / HCPC / Ofsted / CQC / none
  brand       text,                          -- e.g. 'John Williams' for insurance
  sort_order  int  not null default 100,
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);


-- ----------------------------------------------------------------------------
-- 2. SPECIALTIES — child of discipline (Theatres, Midwifery, Underwriter, …)
-- ----------------------------------------------------------------------------
create table candidate.specialties (
  id                   uuid primary key default gen_random_uuid(),
  discipline_id        uuid not null references candidate.disciplines(id) on delete cascade,
  code                 text not null,
  name                 text not null,
  -- Registered Managers (children's homes / care homes) are senior regulated
  -- appointments that warrant their own track within a discipline.
  is_registered_manager boolean not null default false,
  regulator_override   text,                 -- e.g. ODP within Nursing -> HCPC
  sort_order           int  not null default 100,
  active               boolean not null default true,
  created_at           timestamptz not null default now(),
  unique (discipline_id, code)
);


-- ----------------------------------------------------------------------------
-- 3. SOURCES — provenance of where a candidate came from (consent basis lives
--    here so it is decided per channel, not per row). Sourcing channels are a
--    later decision; this table is channel-agnostic and ready for any of them.
-- ----------------------------------------------------------------------------
create table candidate.sources (
  id            uuid primary key default gen_random_uuid(),
  code          text not null unique,        -- 'inbound_web', 'referral', 'jobboard_api', …
  name          text not null,
  channel_type  text not null default 'inbound'
                check (channel_type in ('inbound','referral','jobboard','social','event','import','other')),
  -- Lawful basis for processing/marketing under UK GDPR / PECR. Individuals
  -- (unlike the B2B outreach) generally need consent — baked in from day one.
  default_consent_basis text not null default 'consent'
                check (default_consent_basis in ('consent','legitimate_interest','contract')),
  active        boolean not null default true,
  created_at    timestamptz not null default now()
);


-- ----------------------------------------------------------------------------
-- 4. CANDIDATES — the golden record
-- ----------------------------------------------------------------------------
create table candidate.candidates (
  id            uuid primary key default gen_random_uuid(),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),

  -- Pipeline stage (autonomous up to 'qualified'+compliance request;
  -- human-gated from acceptance/registration onward).
  status        text not null default 'sourced'
                check (status in (
                  'sourced',      -- agent found them / they arrived, not yet contacted
                  'contacted',    -- agent has reached out
                  'engaged',      -- two-way conversation underway
                  'qualified',    -- meets light qualification (discipline/spec/RTW/availability)
                  'compliance',   -- compliance intake started
                  'ready',        -- fully compliant, work-ready  (HUMAN-gated to enter)
                  'placed',
                  'rejected',
                  'dormant'
                )),

  discipline_id        uuid references candidate.disciplines(id) on delete set null,
  primary_specialty_id uuid references candidate.specialties(id) on delete set null,

  -- Identity (held to the minimum needed; see §11 data-protection note)
  title         text,
  first_name    text,
  last_name     text,
  known_as      text,
  -- maiden/married/reordered variants for §8a/§8e/§8f reconciliation
  name_variants jsonb not null default '[]'::jsonb,
  dob           date,

  email         text,
  phone         text,
  town          text,
  postcode      text,
  region        text,
  country       text default 'England',

  -- Light qualification fields (the autonomous agent fills these)
  right_to_work_status text                 -- 'uk_citizen','settled','visa','unconfirmed', …
                check (right_to_work_status is null or right_to_work_status in
                  ('uk_citizen','settled','pre_settled','visa','unconfirmed','no')),
  registration_body    text,                 -- NMC / GMC / HCPC / none
  registration_number  text,                 -- PIN / GMC no. — STORED, never AI-verified
  availability         text,                 -- free text for now: 'immediate', dates, etc.
  shift_prefs          jsonb,                -- {days, nights, locations, max_travel, …}

  source_id     uuid references candidate.sources(id) on delete set null,
  source_detail jsonb,                       -- raw provenance (ref id, campaign, referrer)

  owner_user    uuid references auth.users(id) on delete set null,  -- responsible recruiter
  notes         text,

  -- Eclipse / external system integration boundary (future sync, not built yet)
  external_ids  jsonb not null default '{}'::jsonb,   -- {"eclipse_id": "..."}
  sync_status   text not null default 'local'
                check (sync_status in ('local','pending','synced','error')),

  created_by    uuid references auth.users(id) on delete set null
);

-- One row per email/phone where present (case-insensitive on email)
create unique index candidates_email_lower_idx
  on candidate.candidates (lower(email)) where email is not null;
create index candidates_status_idx     on candidate.candidates (status);
create index candidates_discipline_idx on candidate.candidates (discipline_id);
create index candidates_specialty_idx  on candidate.candidates (primary_specialty_id);

create trigger candidates_set_updated_at
  before update on candidate.candidates
  for each row execute function candidate.set_updated_at();


-- ----------------------------------------------------------------------------
-- 5. EMPLOYMENT TIMELINE — for ≥3-year reference coverage + CV reconciliation
--    (assessment §8f gap-analysis; §8a cross-pack reconciliation).
-- ----------------------------------------------------------------------------
create table candidate.employment (
  id            uuid primary key default gen_random_uuid(),
  candidate_id  uuid not null references candidate.candidates(id) on delete cascade,
  employer      text,
  job_title     text,
  start_date    date,
  end_date      date,                         -- null = current / "still working"
  source        text not null default 'self'  -- where this came from
                check (source in ('cv','reference','self','interview','other')),
  notes         text,
  created_at    timestamptz not null default now()
);
create index employment_candidate_idx on candidate.employment (candidate_id);


-- ----------------------------------------------------------------------------
-- 6. MESSAGES — unified engagement log across all channels (agent memory +
--    inbound-email landing zone; the §8f/§9-(11) inbound-email spine starts here)
-- ----------------------------------------------------------------------------
create table candidate.messages (
  id            uuid primary key default gen_random_uuid(),
  candidate_id  uuid references candidate.candidates(id) on delete cascade,
  direction     text not null check (direction in ('inbound','outbound')),
  channel       text not null default 'email'
                check (channel in ('email','sms','whatsapp','web','phone','note')),
  subject       text,
  body          text,
  -- who/what produced an outbound message
  author        text not null default 'agent'
                check (author in ('agent','human','candidate','system')),
  llm_generated boolean not null default false,
  approved_by   uuid references auth.users(id) on delete set null, -- human sign-off if any
  external_ref  text,                         -- provider id (Brevo/SMS/etc.)
  status        text,                         -- queued/sent/delivered/failed/received
  created_at    timestamptz not null default now()
);
create index messages_candidate_idx on candidate.messages (candidate_id);
create index messages_created_idx   on candidate.messages (created_at desc);


-- ----------------------------------------------------------------------------
-- 7. CONSENT — UK GDPR / PECR record (individuals need consent for marketing,
--    unlike the existing B2B surgery outreach). One row per granted/withdrawn.
-- ----------------------------------------------------------------------------
create table candidate.consent (
  id            uuid primary key default gen_random_uuid(),
  candidate_id  uuid not null references candidate.candidates(id) on delete cascade,
  purpose       text not null,                -- 'recruitment','marketing','data_storage'
  basis         text not null default 'consent'
                check (basis in ('consent','legitimate_interest','contract')),
  granted       boolean not null,
  evidence      text,                         -- how captured (form, reply, call note)
  occurred_at   timestamptz not null default now(),
  created_by    uuid references auth.users(id) on delete set null
);
create index consent_candidate_idx on candidate.consent (candidate_id);


-- ----------------------------------------------------------------------------
-- 8. COMPLIANCE REQUIREMENTS — THE CONFIG TABLE (the pluggable slot).
--    Structure now; rows imported from the compliance project later. Mirrors
--    the assessment's tiers/expiry/coverage/human-judgement model so references
--    (§8f), proof-of-address (§8d), qualifications (§8e), etc. slot straight in.
-- ----------------------------------------------------------------------------
create table candidate.compliance_requirements (
  id            uuid primary key default gen_random_uuid(),
  -- null discipline/specialty = applies to all
  discipline_id uuid references candidate.disciplines(id) on delete cascade,
  specialty_id  uuid references candidate.specialties(id) on delete cascade,
  code          text not null,                -- 'dbs','references_3yr','proof_of_address', …
  name          text not null,
  -- assessment automation tier
  tier          text check (tier in ('A','B','C','D','E','H')),
  required      boolean not null default true,
  -- deterministic expiry rule, e.g. {"type":"issue_plus","years":1}
  expiry_rule   jsonb,
  -- coverage rule, e.g. {"type":"continuous_history","years":3,"reconcile":"cv"}
  coverage_rule jsonb,
  needs_human   boolean not null default false,  -- Tier-H: must not auto-decide
  notes         text,
  sort_order    int not null default 100,
  active        boolean not null default true,
  unique (discipline_id, specialty_id, code)
);


-- ----------------------------------------------------------------------------
-- 9. CANDIDATE COMPLIANCE ITEMS — per-candidate instance of a requirement.
--    Captures channel + source confidence (portal vs handwritten scan, §8f),
--    expiry, the human-review flag, and the extracted fields.
-- ----------------------------------------------------------------------------
create table candidate.compliance_items (
  id             uuid primary key default gen_random_uuid(),
  candidate_id   uuid not null references candidate.candidates(id) on delete cascade,
  requirement_id uuid references candidate.compliance_requirements(id) on delete set null,
  status         text not null default 'not_started'
                 check (status in (
                   'not_started','requested','received','verifying',
                   'verified','unsuitable','expired')),
  -- delivery channel & how machine-readable it was (§8f gradient)
  channel        text,                        -- portal/email_body/pdf_attachment/typed_form/handwritten
  source_confidence text,                     -- high/medium/low (drives human routing)
  received_at    timestamptz,
  expires_at     timestamptz,
  extracted      jsonb,                       -- structured fields pulled from the artefact
  artefact_path  text,                        -- Supabase Storage path to the document
  needs_human    boolean not null default false,  -- routed to review queue
  human_notes    text,
  decided_by     uuid references auth.users(id) on delete set null,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index compliance_items_candidate_idx on candidate.compliance_items (candidate_id);
create index compliance_items_status_idx    on candidate.compliance_items (status);
create index compliance_items_review_idx    on candidate.compliance_items (needs_human) where needs_human;
create index compliance_items_expiry_idx    on candidate.compliance_items (expires_at);

create trigger compliance_items_set_updated_at
  before update on candidate.compliance_items
  for each row execute function candidate.set_updated_at();


-- ----------------------------------------------------------------------------
-- 10. REVIEW QUEUE — the human-in-loop surface (Tier-H / §7). A view so it is
--     always live: anything flagged for eyes, newest first.
-- ----------------------------------------------------------------------------
create or replace view candidate.review_queue
with (security_invoker = true) as
select
  ci.id                as item_id,
  ci.candidate_id,
  c.first_name, c.last_name,
  d.name               as discipline,
  cr.name              as requirement,
  ci.status,
  ci.channel,
  ci.source_confidence,
  ci.human_notes,
  ci.updated_at
from candidate.compliance_items ci
join candidate.candidates c            on c.id = ci.candidate_id
left join candidate.disciplines d      on d.id = c.discipline_id
left join candidate.compliance_requirements cr on cr.id = ci.requirement_id
where ci.needs_human
order by ci.updated_at desc;

-- ==== sql/11_candidate_policies.sql ====
-- ============================================================================
--  Day Webster — Candidate Pipeline  ·  Row Level Security
--  File: candidate-pipeline/sql/11_candidate_policies.sql
--  Run AFTER 10_candidate_schema.sql.
--
--  STATUS: DRAFT — NOT YET APPLIED. For review only.
--
--  Self-contained: defines its own authorisation helper in the `candidate`
--  schema so it does not couple to the public outreach system's policies.
--  Same allowed domains for now; change here independently if candidate-side
--  access should ever differ from outreach-side access.
-- ============================================================================

create or replace function candidate.is_authorized_user()
returns boolean
language sql stable security definer
set search_path = public
as $$
  select coalesce(
    lower(auth.jwt() ->> 'email') like '%@daywebster.com'
      or lower(auth.jwt() ->> 'email') like '%@daywebstergroup.com'
      or lower(auth.jwt() ->> 'email') like '%@homecare-providers.com'
      or lower(auth.jwt() ->> 'email') like '%@homecareproviders.co.uk',
    false
  );
$$;
grant execute on function candidate.is_authorized_user() to authenticated;

-- Schema usage
grant usage on schema candidate to authenticated;

-- Enable RLS on every table
alter table candidate.disciplines             enable row level security;
alter table candidate.specialties             enable row level security;
alter table candidate.sources                 enable row level security;
alter table candidate.candidates              enable row level security;
alter table candidate.employment              enable row level security;
alter table candidate.messages                enable row level security;
alter table candidate.consent                 enable row level security;
alter table candidate.compliance_requirements enable row level security;
alter table candidate.compliance_items        enable row level security;

-- One uniform policy set: authorised staff get full CRUD; everyone else nothing.
-- (Granularity per-role can come later; this matches the existing app's model.)
do $$
declare t text;
begin
  foreach t in array array[
    'disciplines','specialties','sources','candidates','employment',
    'messages','consent','compliance_requirements','compliance_items'
  ]
  loop
    execute format(
      'create policy "auth read %1$s"   on candidate.%1$s for select to authenticated using (candidate.is_authorized_user());', t);
    execute format(
      'create policy "auth insert %1$s" on candidate.%1$s for insert to authenticated with check (candidate.is_authorized_user());', t);
    execute format(
      'create policy "auth update %1$s" on candidate.%1$s for update to authenticated using (candidate.is_authorized_user()) with check (candidate.is_authorized_user());', t);
    execute format(
      'create policy "auth delete %1$s" on candidate.%1$s for delete to authenticated using (candidate.is_authorized_user());', t);
  end loop;
end $$;

-- NOTE (Supabase): to query schema `candidate` from supabase-js, either expose
-- it under Dashboard → Settings → API → "Exposed schemas", or create the client
-- with { db: { schema: 'candidate' } }. The existing app keeps using `public`
-- and is unaffected.

-- ==== sql/12_candidate_seed.sql ====
-- ============================================================================
--  Day Webster — Candidate Pipeline  ·  Seed: disciplines & specialties
--  File: candidate-pipeline/sql/12_candidate_seed.sql
--  Run AFTER 10 + 11. Idempotent (on conflict do nothing).
--
--  STATUS: DRAFT — NOT YET APPLIED. For review only.
--
--  Day-one business areas from the brief:
--    Nursing (Theatres, Midwifery, Primary Care), Doctors (all), Complex Care,
--    AHP (all specialities), Insurance (John Williams), Children's Services
--    (carers + registered managers), Care Homes (incl. registered managers).
--  Specialty lists are starting points — extend as rows, never as code.
-- ============================================================================

insert into candidate.disciplines (code, name, regulator, brand, sort_order) values
  ('nursing',    'Nursing',           'NMC',    null,             10),
  ('doctors',    'Doctors',           'GMC',    null,             20),
  ('complex_care','Complex Care',     'CQC',    null,             30),
  ('ahp',        'AHP',               'HCPC',   null,             40),
  ('insurance',  'Insurance',         null,     'John Williams',  50),
  ('childrens',  'Children''s Services','Ofsted',null,            60),
  ('care_homes', 'Care Homes',        'CQC',    null,             70)
on conflict (code) do nothing;

-- Helper inserts per discipline ---------------------------------------------
-- Nursing
insert into candidate.specialties (discipline_id, code, name, regulator_override, sort_order)
select d.id, v.code, v.name, v.reg, v.so
from candidate.disciplines d,
  (values
    ('general',     'General Nursing', null,   10),
    ('theatres',    'Theatres',        null,   20),  -- ODP sub-roles -> HCPC, see below
    ('theatres_odp','Theatres (ODP)',  'HCPC', 25),
    ('midwifery',   'Midwifery',       null,   30),
    ('primary_care','Primary Care',    null,   40)
  ) as v(code,name,reg,so)
where d.code = 'nursing'
on conflict (discipline_id, code) do nothing;

-- Doctors (all aspects — common grades; extend freely)
insert into candidate.specialties (discipline_id, code, name, sort_order)
select d.id, v.code, v.name, v.so
from candidate.disciplines d,
  (values
    ('general',    'General / Locum',      10),
    ('gp',         'GP',                   20),
    ('specialty',  'Specialty Doctor',     30),
    ('consultant', 'Consultant',           40)
  ) as v(code,name,so)
where d.code = 'doctors'
on conflict (discipline_id, code) do nothing;

-- Complex Care
insert into candidate.specialties (discipline_id, code, name, sort_order)
select d.id, 'general', 'Complex Care', 10
from candidate.disciplines d where d.code = 'complex_care'
on conflict (discipline_id, code) do nothing;

-- AHP (all specialities — common HCPC professions; extend freely)
insert into candidate.specialties (discipline_id, code, name, sort_order)
select d.id, v.code, v.name, v.so
from candidate.disciplines d,
  (values
    ('physio',      'Physiotherapy',                10),
    ('ot',          'Occupational Therapy',         20),
    ('slt',         'Speech & Language Therapy',    30),
    ('dietetics',   'Dietetics',                    40),
    ('radiography', 'Radiography',                  50),
    ('paramedic',   'Paramedic',                    60),
    ('odp',         'Operating Department Practitioner', 70),
    ('podiatry',    'Podiatry',                     80)
  ) as v(code,name,so)
where d.code = 'ahp'
on conflict (discipline_id, code) do nothing;

-- Insurance (John Williams brand)
insert into candidate.specialties (discipline_id, code, name, sort_order)
select d.id, v.code, v.name, v.so
from candidate.disciplines d,
  (values
    ('underwriter', 'Underwriter',  10),
    ('broker',      'Broker',       20),
    ('claims',      'Claims',       30)
  ) as v(code,name,so)
where d.code = 'insurance'
on conflict (discipline_id, code) do nothing;

-- Children's Services (carers + registered managers)
insert into candidate.specialties (discipline_id, code, name, is_registered_manager, sort_order)
select d.id, v.code, v.name, v.rm, v.so
from candidate.disciplines d,
  (values
    ('carer',           'Children''s Home Carer',          false, 10),
    ('senior',          'Senior Residential Worker',       false, 20),
    ('registered_mgr',  'Registered Manager (Children''s)', true, 30)
  ) as v(code,name,rm,so)
where d.code = 'childrens'
on conflict (discipline_id, code) do nothing;

-- Care Homes (incl. registered managers)
insert into candidate.specialties (discipline_id, code, name, is_registered_manager, sort_order)
select d.id, v.code, v.name, v.rm, v.so
from candidate.disciplines d,
  (values
    ('care_assistant',  'Care Assistant',              false, 10),
    ('senior_carer',    'Senior Carer',                false, 20),
    ('nurse',           'Nurse (Care Home)',           false, 30),
    ('registered_mgr',  'Registered Manager (Care Home)', true, 40)
  ) as v(code,name,rm,so)
where d.code = 'care_homes'
on conflict (discipline_id, code) do nothing;

-- A starter inbound source so the agent has somewhere to file day-one arrivals
insert into candidate.sources (code, name, channel_type, default_consent_basis) values
  ('inbound_web', 'Inbound web enquiry', 'inbound',  'consent'),
  ('referral',    'Referral',            'referral', 'consent'),
  ('import',      'Spreadsheet import',  'import',   'legitimate_interest')
on conflict (code) do nothing;

-- ==== sql/13_compliance_requirements.sql ====
-- ============================================================================
--  Day Webster — Candidate Pipeline · Seed: compliance requirements (config)
--  File: candidate-pipeline/sql/13_compliance_requirements.sql
--  Run AFTER 10–12. Idempotent.
--
--  STATUS: DRAFT — NOT YET APPLIED. For review only.
--
--  This is the "pluggable slot" filled in — a first per-discipline requirement
--  set derived from the Compliance Automation Feasibility Assessment. Each row
--  carries the assessment's automation tier (A–H), a deterministic expiry rule,
--  a coverage rule where relevant, and a needs_human flag for the judgement
--  calls that must never be auto-decided (§7 / the gradient principle).
--
--  These are STARTING POINTS — refine against the live compliance project.
--  New requirement = a new row, never a code change (the §2 thesis).
--
--  expiry_rule shapes used:
--    {"type":"upload_plus","years":N}        - N years from upload
--    {"type":"issue_plus","years":N}         - N years from the document's issue
--    {"type":"issue_plus","years":1,"recency_months":3} - PoA: <=3mo at reg, then +1yr
--    {"type":"issue_plus_days","days":1461}  - DBS webcheck: cert issue + 4yr + 1day
--    {"type":"from_certificate"}             - read the expiry off the cert
--    null                                    - does not expire (record/recon only)
--  coverage_rule: {"type":"continuous_history","years":3,"reconcile":"cv"}
-- ============================================================================

-- ── Null-safe idempotency key (D5) ──────────────────────────────────────────
-- The table's `unique (discipline_id, specialty_id, code)` constraint never
-- constrains the global/discipline-scoped rows here, because a NULL discipline
-- or specialty is DISTINCT from every other NULL in a b-tree unique index — so
-- `on conflict (discipline_id, specialty_id, code)` silently never fires and a
-- re-run duplicates every catalogue row. Add a null-collapsing expression index
-- and use it as the conflict target so re-applying this file is a true no-op.
-- Sentinel UUID stands in for "no discipline/specialty" so NULLs compare equal.
create unique index if not exists compliance_requirements_key_uniq
  on candidate.compliance_requirements (
    coalesce(discipline_id, '00000000-0000-0000-0000-000000000000'::uuid),
    coalesce(specialty_id,  '00000000-0000-0000-0000-000000000000'::uuid),
    code);

-- ── GLOBAL (apply to every discipline; discipline_id = null) ────────────────
insert into candidate.compliance_requirements
  (discipline_id, code, name, tier, required, expiry_rule, coverage_rule, needs_human, sort_order) values
  (null, 'cv',                 'Up-to-date CV',                'A', true,  '{"type":"upload_plus","years":1}'::jsonb, null, false, 10),
  (null, 'right_to_work',      'Right to work',                'C', true,  null, null, true,  20),
  (null, 'proof_of_address',   'Proof of address',             'B', true,  '{"type":"issue_plus","years":1,"recency_months":3}'::jsonb, null, false, 30),
  (null, 'references_3yr',     'References (continuous 3-year history)', 'D', true, null, '{"type":"continuous_history","years":3,"reconcile":"cv"}'::jsonb, true, 40),
  (null, 'overseas_police_check', 'Overseas police check (if overseas history)', 'H', false, null, null, true, 45)
on conflict (coalesce(discipline_id, '00000000-0000-0000-0000-000000000000'::uuid),
             coalesce(specialty_id,  '00000000-0000-0000-0000-000000000000'::uuid),
             code) do nothing;

-- ── Helper to add a discipline-scoped requirement ───────────────────────────
-- (written out explicitly per row for clarity / easy editing)

-- NURSING (NMC) ------------------------------------------------------------
insert into candidate.compliance_requirements (discipline_id, code, name, tier, required, expiry_rule, coverage_rule, needs_human, sort_order)
values
 ((select id from candidate.disciplines where code='nursing'), 'nmc_registration',   'NMC registration (revalidation)', 'C', true,  null, null, true,  50),
 ((select id from candidate.disciplines where code='nursing'), 'qualification_cert', 'Qualification certificate',       'D', true,  null, null, true,  60),
 ((select id from candidate.disciplines where code='nursing'), 'dbs_enhanced',       'Enhanced DBS',                    'B', true,  '{"type":"issue_plus_days","days":1461}'::jsonb, null, false, 70),
 ((select id from candidate.disciplines where code='nursing'), 'occupational_health','Occupational health clearance',   'A', true,  '{"type":"from_certificate"}'::jsonb, null, false, 80),
 ((select id from candidate.disciplines where code='nursing'), 'immunisations',      'Immunisations',                   'A', true,  '{"type":"from_certificate"}'::jsonb, null, false, 90),
 ((select id from candidate.disciplines where code='nursing'), 'mandatory_training', 'Mandatory training',              'A', true,  '{"type":"from_certificate"}'::jsonb, null, false, 100)
on conflict (coalesce(discipline_id, '00000000-0000-0000-0000-000000000000'::uuid),
             coalesce(specialty_id,  '00000000-0000-0000-0000-000000000000'::uuid),
             code) do nothing;

-- DOCTORS (GMC) ------------------------------------------------------------
insert into candidate.compliance_requirements (discipline_id, code, name, tier, required, expiry_rule, coverage_rule, needs_human, sort_order)
values
 ((select id from candidate.disciplines where code='doctors'), 'gmc_registration',   'GMC registration (revalidation)', 'C', true,  null, null, true,  50),
 ((select id from candidate.disciplines where code='doctors'), 'qualification_cert', 'Qualification certificate',       'D', true,  null, null, true,  60),
 ((select id from candidate.disciplines where code='doctors'), 'indemnity',          'Medical indemnity insurance',     'D', true,  '{"type":"issue_plus","years":1}'::jsonb, null, true,  65),
 ((select id from candidate.disciplines where code='doctors'), 'dbs_enhanced',       'Enhanced DBS',                    'B', true,  '{"type":"issue_plus_days","days":1461}'::jsonb, null, false, 70),
 ((select id from candidate.disciplines where code='doctors'), 'occupational_health','Occupational health clearance',   'A', true,  '{"type":"from_certificate"}'::jsonb, null, false, 80),
 ((select id from candidate.disciplines where code='doctors'), 'immunisations',      'Immunisations',                   'A', true,  '{"type":"from_certificate"}'::jsonb, null, false, 90),
 ((select id from candidate.disciplines where code='doctors'), 'mandatory_training', 'Mandatory training',              'A', true,  '{"type":"from_certificate"}'::jsonb, null, false, 100)
on conflict (coalesce(discipline_id, '00000000-0000-0000-0000-000000000000'::uuid),
             coalesce(specialty_id,  '00000000-0000-0000-0000-000000000000'::uuid),
             code) do nothing;

-- AHP (HCPC) ---------------------------------------------------------------
insert into candidate.compliance_requirements (discipline_id, code, name, tier, required, expiry_rule, coverage_rule, needs_human, sort_order)
values
 ((select id from candidate.disciplines where code='ahp'), 'hcpc_registration',  'HCPC registration',         'C', true,  null, null, true,  50),
 ((select id from candidate.disciplines where code='ahp'), 'qualification_cert', 'Qualification certificate', 'D', true,  null, null, true,  60),
 ((select id from candidate.disciplines where code='ahp'), 'dbs_enhanced',       'Enhanced DBS',              'B', true,  '{"type":"issue_plus_days","days":1461}'::jsonb, null, false, 70),
 ((select id from candidate.disciplines where code='ahp'), 'occupational_health','Occupational health clearance', 'A', true, '{"type":"from_certificate"}'::jsonb, null, false, 80),
 ((select id from candidate.disciplines where code='ahp'), 'immunisations',      'Immunisations',             'A', true,  '{"type":"from_certificate"}'::jsonb, null, false, 90),
 ((select id from candidate.disciplines where code='ahp'), 'mandatory_training', 'Mandatory training',        'A', true,  '{"type":"from_certificate"}'::jsonb, null, false, 100)
on conflict (coalesce(discipline_id, '00000000-0000-0000-0000-000000000000'::uuid),
             coalesce(specialty_id,  '00000000-0000-0000-0000-000000000000'::uuid),
             code) do nothing;

-- COMPLEX CARE (CQC) -------------------------------------------------------
insert into candidate.compliance_requirements (discipline_id, code, name, tier, required, expiry_rule, coverage_rule, needs_human, sort_order)
values
 ((select id from candidate.disciplines where code='complex_care'), 'dbs_enhanced',      'Enhanced DBS',               'B', true,  '{"type":"issue_plus_days","days":1461}'::jsonb, null, false, 70),
 ((select id from candidate.disciplines where code='complex_care'), 'care_certificate',  'Care Certificate',           'A', true,  null, null, false, 55),
 ((select id from candidate.disciplines where code='complex_care'), 'occupational_health','Occupational health clearance','A', true, '{"type":"from_certificate"}'::jsonb, null, false, 80),
 ((select id from candidate.disciplines where code='complex_care'), 'mandatory_training','Mandatory training',          'A', true,  '{"type":"from_certificate"}'::jsonb, null, false, 100)
on conflict (coalesce(discipline_id, '00000000-0000-0000-0000-000000000000'::uuid),
             coalesce(specialty_id,  '00000000-0000-0000-0000-000000000000'::uuid),
             code) do nothing;

-- CARE HOMES (CQC) ---------------------------------------------------------
insert into candidate.compliance_requirements (discipline_id, code, name, tier, required, expiry_rule, coverage_rule, needs_human, sort_order)
values
 ((select id from candidate.disciplines where code='care_homes'), 'dbs_enhanced_adults','Enhanced DBS (adults barred list)', 'B', true, '{"type":"issue_plus_days","days":1461}'::jsonb, null, false, 70),
 ((select id from candidate.disciplines where code='care_homes'), 'care_certificate',   'Care Certificate',           'A', true,  null, null, false, 55),
 ((select id from candidate.disciplines where code='care_homes'), 'mandatory_training', 'Mandatory training',         'A', true,  '{"type":"from_certificate"}'::jsonb, null, false, 100),
 ((select id from candidate.disciplines where code='care_homes'), 'occupational_health','Occupational health clearance','A', true, '{"type":"from_certificate"}'::jsonb, null, false, 80)
on conflict (coalesce(discipline_id, '00000000-0000-0000-0000-000000000000'::uuid),
             coalesce(specialty_id,  '00000000-0000-0000-0000-000000000000'::uuid),
             code) do nothing;

-- CHILDREN'S SERVICES (Ofsted) ---------------------------------------------
insert into candidate.compliance_requirements (discipline_id, code, name, tier, required, expiry_rule, coverage_rule, needs_human, sort_order)
values
 ((select id from candidate.disciplines where code='childrens'), 'dbs_enhanced_children','Enhanced DBS (children''s barred list)', 'B', true, '{"type":"issue_plus_days","days":1461}'::jsonb, null, false, 70),
 ((select id from candidate.disciplines where code='childrens'), 'qualification_cert',   'Level 3 Diploma (Children & Young People)', 'C', true, null, null, true, 60),
 ((select id from candidate.disciplines where code='childrens'), 'mandatory_training',   'Mandatory training',        'A', true,  '{"type":"from_certificate"}'::jsonb, null, false, 100),
 ((select id from candidate.disciplines where code='childrens'), 'occupational_health',  'Occupational health clearance','A', true, '{"type":"from_certificate"}'::jsonb, null, false, 80)
on conflict (coalesce(discipline_id, '00000000-0000-0000-0000-000000000000'::uuid),
             coalesce(specialty_id,  '00000000-0000-0000-0000-000000000000'::uuid),
             code) do nothing;

-- INSURANCE (John Williams) — non-clinical --------------------------------
insert into candidate.compliance_requirements (discipline_id, code, name, tier, required, expiry_rule, coverage_rule, needs_human, sort_order)
values
 ((select id from candidate.disciplines where code='insurance'), 'cii_qualification',  'CII / professional qualification', 'C', false, null, null, false, 50),
 ((select id from candidate.disciplines where code='insurance'), 'financial_reference','Financial / credit reference',     'B', false, null, null, true,  60)
on conflict (coalesce(discipline_id, '00000000-0000-0000-0000-000000000000'::uuid),
             coalesce(specialty_id,  '00000000-0000-0000-0000-000000000000'::uuid),
             code) do nothing;

-- REGISTERED MANAGERS (specialty-scoped extras) ----------------------------
-- Children's home registered manager
insert into candidate.compliance_requirements (discipline_id, specialty_id, code, name, tier, required, needs_human, sort_order)
select d.id, s.id, v.code, v.name, v.tier, true, v.nh, v.so
from candidate.disciplines d
join candidate.specialties s on s.discipline_id = d.id and s.code = 'registered_mgr'
cross join (values
  ('level5_diploma',        'Level 5 Diploma (Leadership & Management)', 'C', false, 110),
  ('fit_person_declaration','Fit-person declaration / interview',        'H', true,  120)
) as v(code,name,tier,nh,so)
where d.code in ('childrens','care_homes')
on conflict (coalesce(discipline_id, '00000000-0000-0000-0000-000000000000'::uuid),
             coalesce(specialty_id,  '00000000-0000-0000-0000-000000000000'::uuid),
             code) do nothing;

-- ==== sql/14_early_warnings.sql ====
-- ============================================================================
--  Day Webster — Candidate Pipeline · Early Warnings
--  File: candidate-pipeline/sql/14_early_warnings.sql
--  Run AFTER 10–13. Idempotent / additive.
--
--  STATUS: DRAFT — NOT YET APPLIED. For review only.
--
--  The assessment's highest-ROI loop (§6): the system already knows every
--  expiry date, so a human shouldn't be running queries and chasing by hand.
--  This adds:
--    - chased_at  : so the monitor doesn't re-chase the same item every run
--    - expiring_items view : the live worklist (expired + next 60 days, bucketed)
--  The `early-warnings` edge function sweeps these and auto-chases candidates.
-- ============================================================================

alter table candidate.compliance_items
  add column if not exists chased_at timestamptz;

-- Live worklist: anything expired or expiring within 60 days, with the same
-- buckets the assessment uses (expired / 1-7 / 8-14 / 15-30 / 31-60 days).
create or replace view candidate.expiring_items
with (security_invoker = true) as
select
  ci.id            as item_id,
  ci.candidate_id,
  c.first_name, c.last_name, c.email,
  d.name           as discipline,
  cr.name          as requirement,
  ci.status,
  ci.expires_at,
  ci.chased_at,
  (ci.expires_at::date - current_date) as days_left,
  case
    when ci.expires_at <  now()                       then 'expired'
    when ci.expires_at <  now() + interval '8 days'   then '1-7'
    when ci.expires_at <  now() + interval '15 days'  then '8-14'
    when ci.expires_at <  now() + interval '31 days'  then '15-30'
    else '31-60'
  end as bucket
from candidate.compliance_items ci
join candidate.candidates c               on c.id = ci.candidate_id
left join candidate.disciplines d         on d.id = c.discipline_id
left join candidate.compliance_requirements cr on cr.id = ci.requirement_id
where ci.expires_at is not null
  and ci.expires_at < now() + interval '60 days'
  and ci.status <> 'expired'  -- already-handled expiries drop off the worklist
order by ci.expires_at;

-- ==== sql/15_inbound_email.sql ====
-- ============================================================================
--  Day Webster — Candidate Pipeline · Inbound email
--  File: candidate-pipeline/sql/15_inbound_email.sql
--  Run AFTER 10–14. Idempotent / additive.
--
--  STATUS: DRAFT — NOT YET APPLIED. For review only.
--
--  Supports the inbound-email pipeline. Documents and references arrive by
--  email; to link an email back to the right candidate (and requirement) when
--  the sender is a referee — not the candidate — we issue a correlation TOKEN
--  embedded in the reply-to / plus-address / subject when we request a doc.
--
--  The `inbound-email` edge function looks the token up; if there's no token it
--  falls back to matching the sender's email to a candidate. Ingested files go
--  to a private Storage bucket `candidate-docs` (create it at deploy time) and
--  land on a compliance_item as status='received' — never auto-verified.
-- ============================================================================

create table if not exists candidate.email_tokens (
  token          text primary key,
  candidate_id   uuid not null references candidate.candidates(id) on delete cascade,
  requirement_id uuid references candidate.compliance_requirements(id) on delete set null,
  purpose        text not null default 'document'
                 check (purpose in ('document','reference')),
  created_at     timestamptz not null default now(),
  expires_at     timestamptz
);
create index if not exists email_tokens_candidate_idx on candidate.email_tokens (candidate_id);

alter table candidate.email_tokens enable row level security;

do $$
begin
  if not exists (select 1 from pg_policies where schemaname='candidate' and tablename='email_tokens' and policyname='auth read email_tokens') then
    execute 'create policy "auth read email_tokens"   on candidate.email_tokens for select to authenticated using (candidate.is_authorized_user())';
    execute 'create policy "auth insert email_tokens" on candidate.email_tokens for insert to authenticated with check (candidate.is_authorized_user())';
    execute 'create policy "auth update email_tokens" on candidate.email_tokens for update to authenticated using (candidate.is_authorized_user()) with check (candidate.is_authorized_user())';
    execute 'create policy "auth delete email_tokens" on candidate.email_tokens for delete to authenticated using (candidate.is_authorized_user())';
  end if;
end $$;

-- ==== sql/16_sourcing.sql ====
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

-- ==== sql/17_dashboard.sql ====
-- ============================================================================
--  Day Webster — Candidate Pipeline · Control-tower views (Phase 3)
--  File: candidate-pipeline/sql/17_dashboard.sql
--  Run AFTER 10–16. Idempotent.
--
--  STATUS: DRAFT — NOT YET APPLIED. For review only.
--
--  Oversight metrics for dashboard.html:
--    - campaign_performance : spend + candidates + cost-per-candidate per campaign
--    - channel_spend        : advert spend rolled up by channel
--  (intake_by_channel already exists from sql/16; pipeline counts + needs-review
--   + expiring + unassigned-discipline are simple counts done in the dashboard.)
-- ============================================================================

create or replace view candidate.campaign_performance
with (security_invoker = true) as
select
  sc.id, sc.name, sc.kind, sc.channel, sc.status,
  sc.budget, sc.spend,
  d.name as discipline,
  count(c.id)                                              as candidates,
  count(c.id) filter (where c.status = 'qualified')        as qualified,
  count(c.id) filter (where c.status in ('ready','placed')) as ready_or_placed,
  case when count(c.id) > 0 then round(sc.spend / count(c.id), 2) end as cost_per_candidate
from candidate.sourcing_campaigns sc
left join candidate.candidates c   on c.campaign_id = sc.id
left join candidate.disciplines d  on d.id = sc.discipline_id
group by sc.id, d.name
order by candidates desc;

create or replace view candidate.channel_spend
with (security_invoker = true) as
select
  a.channel,
  count(*)                          as adverts,
  count(*) filter (where a.status='posted') as posted,
  coalesce(sum(a.cost), 0)          as spend
from candidate.adverts a
group by a.channel
order by spend desc;

-- ==== sql/18_desks.sql ====
-- ============================================================================
--  Day Webster — Candidate Pipeline · Desks & co-pilot (multi-desk)
--  File: candidate-pipeline/sql/18_desks.sql
--  Run AFTER 10–17. Idempotent / additive.
--
--  STATUS: DRAFT — NOT YET APPLIED. For review only.
--
--  Desks are a SEPARATE organisational layer from the discipline/specialty
--  taxonomy. A desk covers a set of specialties (optionally by region), so
--  candidates AUTO-ROUTE to the right desk on qualification. Visibility is
--  SILOED: recruiters see only their desk(s); admins see everything; unassigned
--  candidates are visible to admins (the "to route" queue).
--
--  SAFE BOOTSTRAP: until you populate `staff`, everyone on an authorised domain
--  is treated as admin (sees all) — so applying this never locks anyone out.
--  Siloing switches on once you add staff + desk_members.
-- ============================================================================

-- ── Extra nursing specialties to match the real desks ──────────────────────
insert into candidate.specialties (discipline_id, code, name, sort_order)
select d.id, v.code, v.name, v.so from candidate.disciplines d,
 (values
   ('ward','Ward Nursing',12),('ae','A&E Nursing',13),('itu','ITU/ICU Nursing',14),
   ('hca','Healthcare Assistant',15),('rmn','RMN (Mental Health)',16),
   ('neonatal','Neonatal',32),('paediatrics','Paediatrics',33),
   ('anp','Advanced Nurse Practitioner',42),('enp','Emergency Nurse Practitioner',43)
 ) as v(code,name,so)
where d.code='nursing'
on conflict (discipline_id, code) do nothing;

-- ── Desks ──────────────────────────────────────────────────────────────────
create table if not exists candidate.desks (
  id        uuid primary key default gen_random_uuid(),
  code      text not null unique,
  name      text not null,
  region    text,                       -- informational (routing uses coverage.region)
  active    boolean not null default true,
  created_at timestamptz not null default now()
);

insert into candidate.desks (code, name, region) values
  ('theatres',      'Theatres',                 null),
  ('midwifery',     'Midwifery (+ Neonatal & Paeds)', null),
  ('nursing_north', 'Nursing — North',          'North'),
  ('nursing_south', 'Nursing — South',          'South'),
  ('primary_care',  'Primary Care (ANP/ENP)',   null),
  ('ahp',           'AHP',                      null),
  ('doctors',       'Doctors',                  null),
  ('complex_care',  'Complex Care',             null),
  ('care_homes',    'Care Homes',               null),
  ('childrens',     'Children''s Services',     null),
  ('insurance',     'Insurance — John Williams',null)
on conflict (code) do nothing;

-- ── Coverage rules: (discipline, specialty, region) -> desk ────────────────
create table if not exists candidate.desk_coverage (
  id            uuid primary key default gen_random_uuid(),
  desk_id       uuid not null references candidate.desks(id) on delete cascade,
  discipline_id uuid references candidate.disciplines(id) on delete cascade,
  specialty_id  uuid references candidate.specialties(id) on delete cascade,
  region        text
);

-- nursing specialty-based desks
insert into candidate.desk_coverage (desk_id, discipline_id, specialty_id, region)
select dk.id, d.id, s.id, v.region
from candidate.desks dk
join candidate.disciplines d on d.code = 'nursing'
join (values
  ('theatres',      'theatres',     null), ('theatres',      'theatres_odp', null),
  ('midwifery',     'midwifery',    null), ('midwifery',     'neonatal',     null), ('midwifery','paediatrics',null),
  ('nursing_north', 'ward','North'),('nursing_north','ae','North'),('nursing_north','itu','North'),('nursing_north','hca','North'),('nursing_north','rmn','North'),
  ('nursing_south', 'ward','South'),('nursing_south','ae','South'),('nursing_south','itu','South'),('nursing_south','hca','South'),('nursing_south','rmn','South'),
  ('primary_care',  'primary_care', null), ('primary_care', 'anp', null), ('primary_care','enp',null)
) as v(desk_code, spec_code, region) on v.desk_code = dk.code
join candidate.specialties s on s.discipline_id = d.id and s.code = v.spec_code
on conflict do nothing;

-- discipline-level desks (whole discipline -> one desk)
insert into candidate.desk_coverage (desk_id, discipline_id)
select dk.id, d.id
from candidate.desks dk
join candidate.disciplines d on d.code = dk.code
where dk.code in ('ahp','doctors','complex_care','care_homes','childrens','insurance')
on conflict do nothing;

-- ── Staff (roles) + desk membership ────────────────────────────────────────
create table if not exists candidate.staff (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  full_name  text,
  is_admin   boolean not null default false,
  created_at timestamptz not null default now()
);
create table if not exists candidate.desk_members (
  desk_id   uuid not null references candidate.desks(id) on delete cascade,
  user_id   uuid not null references auth.users(id) on delete cascade,
  role      text not null default 'recruiter',
  primary key (desk_id, user_id)
);

-- ── Attribution on candidates ──────────────────────────────────────────────
alter table candidate.candidates add column if not exists desk_id uuid references candidate.desks(id) on delete set null;
create index if not exists candidates_desk_idx on candidate.candidates (desk_id);

-- ── Role helpers (SECURITY DEFINER) ────────────────────────────────────────
create or replace function candidate.is_admin()
returns boolean language sql stable security definer set search_path = candidate, public as $$
  select coalesce(
    (select s.is_admin from candidate.staff s where s.user_id = auth.uid()),
    not exists (select 1 from candidate.staff)   -- bootstrap: no staff yet => admin
  );
$$;
grant execute on function candidate.is_admin() to authenticated;

create or replace function candidate.my_desk_ids()
returns setof uuid language sql stable security definer set search_path = candidate, public as $$
  select desk_id from candidate.desk_members where user_id = auth.uid();
$$;
grant execute on function candidate.my_desk_ids() to authenticated;

-- ── Routing: pick the best-matching desk for a candidate ───────────────────
create or replace function candidate.desk_for(p_disc uuid, p_spec uuid, p_region text)
returns uuid language sql stable set search_path = candidate, public as $$
  select dc.desk_id
  from candidate.desk_coverage dc
  where (dc.specialty_id  is null or dc.specialty_id  = p_spec)
    and (dc.discipline_id is null or dc.discipline_id = p_disc)
    and (dc.region is null or (p_region is not null and lower(dc.region) = lower(p_region)))
  order by (dc.specialty_id is not null) desc,
           (dc.region is not null) desc,
           (dc.discipline_id is not null) desc
  limit 1;
$$;

-- Auto-route on insert/update when a desk isn't already set.
create or replace function candidate.autoroute()
returns trigger language plpgsql as $$
begin
  if new.desk_id is null and (new.primary_specialty_id is not null or new.discipline_id is not null) then
    new.desk_id := candidate.desk_for(new.discipline_id, new.primary_specialty_id, new.region);
  end if;
  return new;
end;
$$;
drop trigger if exists candidates_autoroute on candidate.candidates;
create trigger candidates_autoroute
  before insert or update of discipline_id, primary_specialty_id, region, desk_id
  on candidate.candidates for each row execute function candidate.autoroute();

-- ── RLS ────────────────────────────────────────────────────────────────────
alter table candidate.desks         enable row level security;
alter table candidate.desk_coverage enable row level security;
alter table candidate.desk_members  enable row level security;
alter table candidate.staff         enable row level security;

-- Reference tables: any authorised staff may read; only admins may change.
do $$
declare t text;
begin
  foreach t in array array['desks','desk_coverage','desk_members','staff'] loop
    execute format('drop policy if exists "auth read %1$s" on candidate.%1$s', t);
    execute format('create policy "auth read %1$s" on candidate.%1$s for select to authenticated using (candidate.is_authorized_user());', t);
    execute format('drop policy if exists "admin write %1$s" on candidate.%1$s', t);
    execute format('create policy "admin write %1$s" on candidate.%1$s for all to authenticated using (candidate.is_authorized_user() and candidate.is_admin()) with check (candidate.is_authorized_user() and candidate.is_admin());', t);
  end loop;
end $$;

-- Candidates: SILOED. Replace the open read/update/delete with desk-scoped ones
-- (insert stays open so anyone can add; the trigger routes to a desk).
drop policy if exists "auth read candidates"   on candidate.candidates;
drop policy if exists "auth update candidates" on candidate.candidates;
drop policy if exists "auth delete candidates" on candidate.candidates;

create policy "desk read candidates" on candidate.candidates for select to authenticated
  using (candidate.is_authorized_user() and (candidate.is_admin() or desk_id in (select candidate.my_desk_ids())));
create policy "desk update candidates" on candidate.candidates for update to authenticated
  using (candidate.is_authorized_user() and (candidate.is_admin() or desk_id in (select candidate.my_desk_ids())))
  with check (candidate.is_authorized_user());
create policy "desk delete candidates" on candidate.candidates for delete to authenticated
  using (candidate.is_authorized_user() and candidate.is_admin());

-- NOTE: child tables (messages, employment, consent, compliance_items) keep the
-- open authorised-domain policies for now. With siloing on, tighten them to the
-- parent candidate's desk in a follow-up if strict isolation is required.

-- ==== sql/19_app_users.sql ====
-- ============================================================================
--  Day Webster — Candidate Pipeline · People directory (for the admin UI)
--  File: candidate-pipeline/sql/19_app_users.sql
--  Run AFTER 10–18. Idempotent / additive.
--
--  STATUS: DRAFT — NOT YET APPLIED. For review only.
--
--  So admins can assign desks/roles by clicking (not SQL), staff pages record
--  the logged-in user here on sign-in. The admin screen lists this directory
--  and writes to `staff` (admin flag) and `desk_members` (desk assignment).
-- ============================================================================

create table if not exists candidate.app_users (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  email      text,
  full_name  text,
  last_seen  timestamptz not null default now()
);

alter table candidate.app_users enable row level security;

-- A user may upsert/see their own row; admins may see everyone.
drop policy if exists "self read app_users"   on candidate.app_users;
drop policy if exists "admin read app_users"  on candidate.app_users;
drop policy if exists "self write app_users"   on candidate.app_users;
drop policy if exists "self update app_users"  on candidate.app_users;
create policy "self read app_users"  on candidate.app_users for select to authenticated using (user_id = auth.uid());
create policy "admin read app_users" on candidate.app_users for select to authenticated using (candidate.is_authorized_user() and candidate.is_admin());
create policy "self write app_users"  on candidate.app_users for insert to authenticated with check (user_id = auth.uid());
create policy "self update app_users" on candidate.app_users for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ==== sql/22_compliance_sets.sql ====
-- ============================================================================
--  Day Webster — Candidate Pipeline · Compliance: versioned requirement sets
--  File: candidate-pipeline/sql/22_compliance_sets.sql
--  Run AFTER 10–21. Idempotent / additive.  STATUS: DRAFT — NOT YET APPLIED.
--
--  Layers versioned requirement SETS over the existing compliance_requirements
--  catalogue, adds the compliance-officer capability, and the append-only audit
--  spine. Sector-generic engine; NHS is just the first seeded set (file 24).
-- ============================================================================

-- ── Additive columns on the catalogue (Phase 0 minimum only) ────────────────
-- criticality is the PLACEMENT-BLOCKING dimension; orthogonal to `tier`
-- (which is the automation/verification tier). Deferred brief columns
-- (evidence_type, verification_method, barred_list, retention_months,
-- regulator, provider_key) are intentionally NOT added yet — Phase 2.
alter table candidate.compliance_requirements
  add column if not exists criticality text not null default 'blocking'
    check (criticality in ('blocking','standard','advisory'));

-- ── Compliance-officer capability (mirrors staff.is_admin from 18_desks) ─────
alter table candidate.staff
  add column if not exists is_compliance boolean not null default false;

create or replace function candidate.is_compliance_officer()
returns boolean language sql stable security definer
set search_path = candidate, public as $$
  select coalesce(
    (select (s.is_compliance or s.is_admin)
       from candidate.staff s where s.user_id = auth.uid()),
    not exists (select 1 from candidate.staff)   -- bootstrap: no staff yet => allow
  );
$$;
grant execute on function candidate.is_compliance_officer() to authenticated;

-- ── Versioned requirement SETS ──────────────────────────────────────────────
-- Each (code, version) is its own immutable row; assigning a set row therefore
-- pins the exact version.
create table if not exists candidate.requirement_sets (
  id            uuid primary key default gen_random_uuid(),
  code          text not null,                       -- e.g. 'NHS_RN'
  version       int  not null default 1,
  name          text not null,
  sector        text not null default 'nhs',         -- engine is sector-generic
  discipline_id uuid references candidate.disciplines(id) on delete set null,
  status        text not null default 'active'
                check (status in ('draft','active','retired')),
  notes         text,
  created_at    timestamptz not null default now(),
  created_by    uuid references auth.users(id) on delete set null,
  unique (code, version)
);

-- Definitions bundled into a set, with per-set OVERRIDES (null = use catalogue).
create table if not exists candidate.requirement_set_items (
  id             uuid primary key default gen_random_uuid(),
  set_id         uuid not null references candidate.requirement_sets(id) on delete cascade,
  requirement_id uuid not null references candidate.compliance_requirements(id) on delete restrict,
  criticality      text    check (criticality in ('blocking','standard','advisory')), -- null = catalogue default
  required_override boolean,                          -- null = catalogue `required`
  expiry_rule_override jsonb,                          -- null = catalogue expiry_rule
  conditional      jsonb,                              -- e.g. {"if":"overseas_history"}
  sort_order       int not null default 100,
  unique (set_id, requirement_id)
);
create index if not exists requirement_set_items_set_idx
  on candidate.requirement_set_items (set_id);

-- Which set(s) apply to a candidate. Denormalise code+version for audit stability.
create table if not exists candidate.candidate_requirement_sets (
  id           uuid primary key default gen_random_uuid(),
  candidate_id uuid not null references candidate.candidates(id) on delete cascade,
  set_id       uuid not null references candidate.requirement_sets(id) on delete restrict,
  set_code     text not null,
  set_version  int  not null,
  active       boolean not null default true,
  assigned_at  timestamptz not null default now(),
  assigned_by  uuid references auth.users(id) on delete set null,
  unique (candidate_id, set_id)
);
create index if not exists candidate_requirement_sets_candidate_idx
  on candidate.candidate_requirement_sets (candidate_id);

-- ── APPEND-ONLY audit spine (who/when/method/source). No update/delete ever. ─
create table if not exists candidate.verification_events (
  id             uuid primary key default gen_random_uuid(),
  candidate_id   uuid not null references candidate.candidates(id) on delete cascade,
  item_id        uuid references candidate.compliance_items(id) on delete set null,
  requirement_id uuid references candidate.compliance_requirements(id) on delete set null,
  set_id         uuid references candidate.requirement_sets(id) on delete set null,
  event_type     text not null
                 check (event_type in ('verified','rejected','unsuitable','expired',
                        'waived','reinstated','evidence_received','recheck_requested',
                        'status_recomputed')),
  old_status     text,
  new_status     text,
  method         text
                 check (method in ('human','idvt','rtw','dbs_update','register_check',
                        'ocr','import','system')),
  source_ref     text,                                -- cert no / provider job id
  notes          text,
  actor          uuid references auth.users(id) on delete set null,  -- null = system/service
  actor_kind     text not null default 'human'
                 check (actor_kind in ('human','system','service')),
  occurred_at    timestamptz not null default now()
);
create index if not exists verification_events_candidate_idx
  on candidate.verification_events (candidate_id, occurred_at desc);

-- ── RLS ─────────────────────────────────────────────────────────────────────
alter table candidate.requirement_sets            enable row level security;
alter table candidate.requirement_set_items       enable row level security;
alter table candidate.candidate_requirement_sets  enable row level security;
alter table candidate.verification_events         enable row level security;

-- Set catalogue: authorised staff read; admins write (mirror 18_desks).
do $$ declare t text; begin
  foreach t in array array['requirement_sets','requirement_set_items'] loop
    execute format('drop policy if exists "auth read %1$s" on candidate.%1$s', t);
    execute format('create policy "auth read %1$s" on candidate.%1$s for select to authenticated using (candidate.is_authorized_user());', t);
    execute format('drop policy if exists "admin write %1$s" on candidate.%1$s', t);
    execute format('create policy "admin write %1$s" on candidate.%1$s for all to authenticated using (candidate.is_authorized_user() and candidate.is_admin()) with check (candidate.is_authorized_user() and candidate.is_admin());', t);
  end loop;
end $$;

-- Candidate<->set assignment: authorised staff read/insert/update; admin delete.
drop policy if exists "auth read cand_sets"   on candidate.candidate_requirement_sets;
drop policy if exists "auth insert cand_sets" on candidate.candidate_requirement_sets;
drop policy if exists "auth update cand_sets" on candidate.candidate_requirement_sets;
drop policy if exists "admin delete cand_sets" on candidate.candidate_requirement_sets;
create policy "auth read cand_sets"   on candidate.candidate_requirement_sets for select to authenticated using (candidate.is_authorized_user());
create policy "auth insert cand_sets" on candidate.candidate_requirement_sets for insert to authenticated with check (candidate.is_authorized_user());
create policy "auth update cand_sets" on candidate.candidate_requirement_sets for update to authenticated using (candidate.is_authorized_user()) with check (candidate.is_authorized_user());
create policy "admin delete cand_sets" on candidate.candidate_requirement_sets for delete to authenticated using (candidate.is_authorized_user() and candidate.is_admin());

-- Audit spine: compliance officers + admin may READ and INSERT only.
-- No UPDATE/DELETE policy => immutable (system writes via SECURITY DEFINER).
drop policy if exists "compliance read events"   on candidate.verification_events;
drop policy if exists "compliance insert events" on candidate.verification_events;
create policy "compliance read events"   on candidate.verification_events for select to authenticated using (candidate.is_authorized_user() and candidate.is_compliance_officer());
create policy "compliance insert events" on candidate.verification_events for insert to authenticated with check (candidate.is_authorized_user() and candidate.is_compliance_officer());

-- ==== sql/23_work_ready_gate.sql ====
-- ============================================================================
--  Day Webster — Candidate Pipeline · Work-Ready gate (status + recompute)
--  File: candidate-pipeline/sql/23_work_ready_gate.sql
--  Run AFTER 22. Idempotent / additive.  STATUS: DRAFT — NOT YET APPLIED.
--
--  Derived red/amber/green per (candidate, set). FAIL-CLOSED: no row => not
--  work-ready. Only recompute_candidate_status() (SECURITY DEFINER) writes the
--  status table; there is no client write policy, so a green cannot be forged.
--    red   = >=1 blocking, required item not verified OR expired
--    amber = all blocking verified, but a required standard item is open
--            OR a verified item expires within the amber window
--    green = all blocking + standard required items verified and unexpired
-- ============================================================================

create table if not exists candidate.candidate_compliance_status (
  id            uuid primary key default gen_random_uuid(),
  candidate_id  uuid not null references candidate.candidates(id) on delete cascade,
  set_id        uuid not null references candidate.requirement_sets(id) on delete cascade,
  status        text not null default 'red' check (status in ('red','amber','green')),
  blocking_open int  not null default 0,     -- blocking, required items unmet
  next_expiry   timestamptz,                 -- earliest upcoming expiry (verified items)
  detail        jsonb,                       -- optional per-requirement breakdown
  computed_at   timestamptz not null default now(),
  unique (candidate_id, set_id)
);
create index if not exists candidate_compliance_status_candidate_idx
  on candidate.candidate_compliance_status (candidate_id);

-- Amber "expiring soon" window is 30 days (a literal below). Change if policy
-- differs; kept inline for Phase 0 simplicity.

create or replace function candidate.recompute_candidate_status(p_candidate_id uuid)
returns void language plpgsql security definer
set search_path = candidate, public as $$
declare
  v_set_id        uuid;
  v_blocking_open int;
  v_standard_open int;
  v_expiring      int;
  v_next_expiry   timestamptz;
  v_status        text;
begin
  -- Fail-closed on de-assignment: drop any status row for a set the candidate
  -- no longer ACTIVELY holds (assignment deleted or set active=false), so the
  -- gate reverts to "no row => not work-ready" rather than a stale green/amber.
  delete from candidate.candidate_compliance_status s
  where s.candidate_id = p_candidate_id
    and not exists (
      select 1 from candidate.candidate_requirement_sets crs
      where crs.candidate_id = p_candidate_id and crs.active and crs.set_id = s.set_id
    );

  for v_set_id in
    select crs.set_id
    from candidate.candidate_requirement_sets crs
    where crs.candidate_id = p_candidate_id and crs.active
  loop
    with reqs as (
      select rsi.requirement_id,
             coalesce(rsi.criticality, cr.criticality)   as criticality,
             coalesce(rsi.required_override, cr.required) as required
      from candidate.requirement_set_items rsi
      join candidate.compliance_requirements cr on cr.id = rsi.requirement_id
      where rsi.set_id = v_set_id
    ),
    item_state as (
      select r.requirement_id, r.criticality, r.required,
             ci.status, ci.expires_at
      from reqs r
      left join lateral (
        select ci.status, ci.expires_at
        from candidate.compliance_items ci
        where ci.candidate_id = p_candidate_id
          and ci.requirement_id = r.requirement_id
        order by (ci.status = 'verified') desc, ci.updated_at desc
        limit 1
      ) ci on true
    )
    select
      count(*) filter (where required and criticality = 'blocking'
                         and (status is distinct from 'verified'
                              or (expires_at is not null and expires_at <= now()))),
      count(*) filter (where required and criticality = 'standard'
                         and (status is distinct from 'verified'
                              or (expires_at is not null and expires_at <= now()))),
      count(*) filter (where status = 'verified' and expires_at is not null
                         and expires_at > now()
                         and expires_at <= now() + interval '30 days'),
      min(expires_at) filter (where status = 'verified' and expires_at > now())
      into v_blocking_open, v_standard_open, v_expiring, v_next_expiry
    from item_state;

    v_status := case
      when v_blocking_open > 0                     then 'red'
      when v_standard_open > 0 or v_expiring > 0   then 'amber'
      else 'green'
    end;

    insert into candidate.candidate_compliance_status
      (candidate_id, set_id, status, blocking_open, next_expiry, computed_at)
    values (p_candidate_id, v_set_id, v_status, v_blocking_open, v_next_expiry, now())
    on conflict (candidate_id, set_id) do update
      set status = excluded.status,
          blocking_open = excluded.blocking_open,
          next_expiry   = excluded.next_expiry,
          computed_at   = now();
  end loop;
end;
$$;
-- recompute is driven by the triggers below (which run with definer rights) and
-- by service-role tooling; no direct authenticated caller needs it, so lock it
-- down rather than exposing a mutation to any logged-in user.
revoke all on function candidate.recompute_candidate_status(uuid) from public;
grant execute on function candidate.recompute_candidate_status(uuid) to service_role;

-- ── The GATE (fail-closed). Callable by staff JWT and by service_role. ──────
create or replace function candidate.is_work_ready(p_candidate_id uuid, p_set_id uuid)
returns boolean language sql stable security definer
set search_path = candidate, public as $$
  select exists (
    select 1 from candidate.candidate_compliance_status s
    where s.candidate_id = p_candidate_id
      and s.set_id = p_set_id
      and s.status in ('green','amber')   -- amber is PLACEABLE; only red blocks
  );
$$;
-- Callable by the booking system (service_role) and staff cockpit (authenticated).
-- Returns only a boolean derived from the traffic light — no PII/evidence — so
-- broad execute is acceptable; it must stay callable by service_role.
revoke all on function candidate.is_work_ready(uuid, uuid) from public;
grant execute on function candidate.is_work_ready(uuid, uuid) to authenticated, service_role;

-- Companion the read-endpoint uses to expose the traffic light. Fail-closed.
create or replace function candidate.work_ready_status(p_candidate_id uuid, p_set_id uuid)
returns text language sql stable security definer
set search_path = candidate, public as $$
  select coalesce(
    (select s.status from candidate.candidate_compliance_status s
      where s.candidate_id = p_candidate_id and s.set_id = p_set_id),
    'red');
$$;
revoke all on function candidate.work_ready_status(uuid, uuid) from public;
grant execute on function candidate.work_ready_status(uuid, uuid) to authenticated, service_role;

-- ── Triggers: recompute on every input that can change the light ────────────
create or replace function candidate.trg_recompute_from_item()
returns trigger language plpgsql security definer
set search_path = candidate, public as $$
begin
  perform candidate.recompute_candidate_status(coalesce(new.candidate_id, old.candidate_id));
  return coalesce(new, old);
end $$;

drop trigger if exists compliance_items_recompute on candidate.compliance_items;
create trigger compliance_items_recompute
  after insert or update of status, expires_at, requirement_id or delete
  on candidate.compliance_items
  for each row execute function candidate.trg_recompute_from_item();

create or replace function candidate.trg_recompute_from_cand_set()
returns trigger language plpgsql security definer
set search_path = candidate, public as $$
begin
  perform candidate.recompute_candidate_status(coalesce(new.candidate_id, old.candidate_id));
  return coalesce(new, old);
end $$;

drop trigger if exists cand_sets_recompute on candidate.candidate_requirement_sets;
create trigger cand_sets_recompute
  after insert or update or delete
  on candidate.candidate_requirement_sets
  for each row execute function candidate.trg_recompute_from_cand_set();

-- Set-definition edits fan out to every candidate holding that set.
create or replace function candidate.trg_recompute_from_set_item()
returns trigger language plpgsql security definer
set search_path = candidate, public as $$
begin
  perform candidate.recompute_candidate_status(crs.candidate_id)
  from candidate.candidate_requirement_sets crs
  where crs.set_id = coalesce(new.set_id, old.set_id) and crs.active;
  return coalesce(new, old);
end $$;

drop trigger if exists set_items_recompute on candidate.requirement_set_items;
create trigger set_items_recompute
  after insert or update or delete
  on candidate.requirement_set_items
  for each row execute function candidate.trg_recompute_from_set_item();

-- ── RLS: traffic light readable to all authorised staff; NO write policy ────
alter table candidate.candidate_compliance_status enable row level security;
drop policy if exists "auth read status" on candidate.candidate_compliance_status;
create policy "auth read status" on candidate.candidate_compliance_status
  for select to authenticated using (candidate.is_authorized_user());
-- (No insert/update/delete policy: only recompute() [SECURITY DEFINER] writes it.)

-- ==== sql/24_seed_nhs_rn_set.sql ====
-- ============================================================================
--  Day Webster — Candidate Pipeline · Seed: NHS Registered Nurse set (v1)
--  File: candidate-pipeline/sql/24_seed_nhs_rn_set.sql
--  Run AFTER 22, 23, and 13 (catalogue). Idempotent.  STATUS: DRAFT.
--
--  One versioned set composed from already-seeded compliance_requirements
--  codes. tier (A–E/H) = automation tier (unchanged); criticality below is the
--  placement-blocking dimension. Maps the six NHS ECS checks -> 'blocking'.
--    ECS1 Identity            -> proof_of_address        blocking
--    ECS2 Right to work       -> right_to_work           blocking
--    ECS3 Registration/quals  -> nmc_registration,
--                                qualification_cert       blocking
--    ECS4 References (3yr)     -> references_3yr          blocking
--    ECS5 Occupational health -> occupational_health,
--                                immunisations            blocking
--    ECS6 DBS                  -> dbs_enhanced            blocking
--    CSTF training            -> mandatory_training      standard  [DECISION]
--    Internal / conditional   -> cv, overseas_police_check advisory
-- ============================================================================

insert into candidate.requirement_sets (code, version, name, sector, discipline_id, status, notes)
select 'NHS_RN', 1, 'NHS Registered Nurse (RM6281 / NHS ECS)', 'nhs',
       (select id from candidate.disciplines where code = 'nursing'),
       'active', 'Phase 0 seed: six NHS Employment Check Standards + CSTF.'
on conflict (code, version) do nothing;

-- Compose from catalogue codes. Global reqs (discipline_id is null) + nursing.
insert into candidate.requirement_set_items
  (set_id, requirement_id, criticality, required_override, conditional, sort_order)
select rs.id, cr.id, v.criticality, v.required_override, v.conditional, v.so
from candidate.requirement_sets rs
join (values
  -- code,                 discipline_code, criticality, required_override, conditional,                    sort
  ('right_to_work',        null,            'blocking', null::boolean,  null::jsonb,                       10),
  ('proof_of_address',     null,            'blocking', null,           null,                              20),
  ('references_3yr',       null,            'blocking', null,           null,                              30),
  ('nmc_registration',     'nursing',       'blocking', null,           null,                              40),
  ('qualification_cert',   'nursing',       'blocking', null,           null,                              50),
  ('dbs_enhanced',         'nursing',       'blocking', null,           null,                              60),
  ('occupational_health',  'nursing',       'blocking', null,           null,                              70),
  ('immunisations',        'nursing',       'blocking', null,           null,                              80),
  ('mandatory_training',   'nursing',       'standard', null,           null,                              90),
  ('cv',                   null,            'advisory', null,           null,                             100),
  ('overseas_police_check',null,            'advisory', false,          '{"if":"overseas_history"}'::jsonb,110)
) as v(code, disc, criticality, required_override, conditional, so) on true
join candidate.compliance_requirements cr
  on cr.code = v.code
 and cr.discipline_id is not distinct from
     (select id from candidate.disciplines where code = v.disc)
where rs.code = 'NHS_RN' and rs.version = 1
on conflict (set_id, requirement_id) do nothing;

-- ==== sql/25_compliance_scale.sql ====
-- ============================================================================
--  Day Webster — Candidate Pipeline · Compliance Phase 1: scale + bulk guard
--  File: candidate-pipeline/sql/25_compliance_scale.sql
--  Run AFTER 22, 23, 24. Idempotent / additive.  STATUS: DRAFT — NOT YET APPLIED.
--
--  Prepares the Phase 0 gate for 10–15k candidates / ~150k items:
--    · adds 'waived' to compliance_items.status + a `migrated` provenance flag
--    · a transaction-local `candidate.bulk_load` guard so the recompute/assign
--      triggers early-return during a set-based bulk migration (no trigger storm)
--    · extends recompute_candidate_status() to write two indexed scalars
--      (needs_human_count, expiring_count) the worklist filters/sorts on, and to
--      treat a WAIVED blocking item as satisfied-but-capped-at-amber (never green)
--    · recompute_candidate_status_bulk(uuid[]) — one call per migration batch
--    · lets compliance officers read the whole bench (desk-silo exemption)
--    · the scale indexes for the recompute hot path + worklist filters
-- ============================================================================

-- ── compliance_items: 'waived' status + migrated provenance flag ────────────
-- The status check is an unnamed column check; Postgres names it
-- <table>_<column>_check. Drop + re-add to widen the domain idempotently.
alter table candidate.compliance_items drop constraint if exists compliance_items_status_check;
alter table candidate.compliance_items add constraint compliance_items_status_check
  check (status in ('not_started','requested','received','verifying',
                    'verified','unsuitable','expired','waived'));

alter table candidate.compliance_items
  add column if not exists migrated boolean not null default false;

-- ── candidate_compliance_status: precomputed scalars for the worklist ───────
-- Filtering/sorting a 15k-row worklist on these scalars is indexable; computing
-- them live over 150k items per query is not.
alter table candidate.candidate_compliance_status
  add column if not exists needs_human_count int not null default 0,
  add column if not exists expiring_count    int not null default 0;

-- ── Recompute: waived handling + the two new scalars ────────────────────────
-- Semantics vs Phase 0:
--   · a WAIVED blocking/standard item is treated as SATISFIED (does not count as
--     open), but a waived BLOCKING item caps the set at amber — it can never go
--     green (D3).
--   · needs_human_count = requirements whose latest item is awaiting a human
--     (received/verifying), is flagged needs_human, or is a migrated item due
--     re-verification.
--   · expiring_count = verified items expiring inside the 30-day amber window.
create or replace function candidate.recompute_candidate_status(p_candidate_id uuid)
returns void language plpgsql security definer
set search_path = candidate, public as $$
declare
  v_set_id        uuid;
  v_blocking_open int;
  v_standard_open int;
  v_waived_block  int;
  v_expiring      int;
  v_needs_human   int;
  v_next_expiry   timestamptz;
  v_status        text;
begin
  -- Fail-closed on de-assignment: drop any status row for a set the candidate
  -- no longer ACTIVELY holds, so the gate reverts to "no row => not work-ready".
  delete from candidate.candidate_compliance_status s
  where s.candidate_id = p_candidate_id
    and not exists (
      select 1 from candidate.candidate_requirement_sets crs
      where crs.candidate_id = p_candidate_id and crs.active and crs.set_id = s.set_id
    );

  for v_set_id in
    select crs.set_id
    from candidate.candidate_requirement_sets crs
    where crs.candidate_id = p_candidate_id and crs.active
  loop
    with reqs as (
      select rsi.requirement_id,
             coalesce(rsi.criticality, cr.criticality)   as criticality,
             coalesce(rsi.required_override, cr.required) as required
      from candidate.requirement_set_items rsi
      join candidate.compliance_requirements cr on cr.id = rsi.requirement_id
      where rsi.set_id = v_set_id
    ),
    item_state as (
      select r.requirement_id, r.criticality, r.required,
             ci.status, ci.expires_at, ci.needs_human, ci.migrated
      from reqs r
      left join lateral (
        select ci.status, ci.expires_at, ci.needs_human, ci.migrated
        from candidate.compliance_items ci
        where ci.candidate_id = p_candidate_id
          and ci.requirement_id = r.requirement_id
        order by (ci.status = 'verified') desc, ci.updated_at desc
        limit 1
      ) ci on true
    )
    select
      -- blocking open: required blocking not satisfied. WAIVED counts as satisfied.
      count(*) filter (where required and criticality = 'blocking'
                         and status is distinct from 'waived'
                         and (status is distinct from 'verified'
                              or (expires_at is not null and expires_at <= now()))),
      -- standard open: same, waived satisfies.
      count(*) filter (where required and criticality = 'standard'
                         and status is distinct from 'waived'
                         and (status is distinct from 'verified'
                              or (expires_at is not null and expires_at <= now()))),
      -- waived BLOCKING items force amber (cannot be green).
      count(*) filter (where required and criticality = 'blocking'
                         and status = 'waived'),
      -- expiring soon (30-day amber window) among verified, unexpired items.
      count(*) filter (where status = 'verified' and expires_at is not null
                         and expires_at > now()
                         and expires_at <= now() + interval '30 days'),
      -- needs a human: awaiting decision, flagged, or a migrated item to re-verify.
      count(*) filter (where status is not null
                         and (status in ('received','verifying')
                              or needs_human or migrated)),
      min(expires_at) filter (where status = 'verified' and expires_at > now())
      into v_blocking_open, v_standard_open, v_waived_block, v_expiring, v_needs_human, v_next_expiry
    from item_state;

    v_status := case
      when v_blocking_open > 0                                      then 'red'
      when v_standard_open > 0 or v_expiring > 0 or v_waived_block > 0 then 'amber'
      else 'green'
    end;

    insert into candidate.candidate_compliance_status
      (candidate_id, set_id, status, blocking_open, needs_human_count,
       expiring_count, next_expiry, computed_at)
    values
      (p_candidate_id, v_set_id, v_status, v_blocking_open, v_needs_human,
       v_expiring, v_next_expiry, now())
    on conflict (candidate_id, set_id) do update
      set status            = excluded.status,
          blocking_open     = excluded.blocking_open,
          needs_human_count = excluded.needs_human_count,
          expiring_count    = excluded.expiring_count,
          next_expiry       = excluded.next_expiry,
          computed_at       = now();
  end loop;
end;
$$;
revoke all on function candidate.recompute_candidate_status(uuid) from public;
grant execute on function candidate.recompute_candidate_status(uuid) to service_role;

-- ── Batch recompute (one call per migration batch) ──────────────────────────
create or replace function candidate.recompute_candidate_status_bulk(p_ids uuid[])
returns void language plpgsql security definer
set search_path = candidate, public as $$
declare v_id uuid;
begin
  foreach v_id in array coalesce(p_ids, '{}'::uuid[]) loop
    perform candidate.recompute_candidate_status(v_id);
  end loop;
end;
$$;
revoke all on function candidate.recompute_candidate_status_bulk(uuid[]) from public;
grant execute on function candidate.recompute_candidate_status_bulk(uuid[]) to service_role;

-- ── Trigger guard: early-return during a bulk load ──────────────────────────
-- `set_config('candidate.bulk_load','on', true)` is transaction-local, so the
-- migration RPC disables these fan-out triggers for its own transaction only.
-- current_setting(..., true) returns NULL when unset => normal operation.
create or replace function candidate.trg_recompute_from_item()
returns trigger language plpgsql security definer
set search_path = candidate, public as $$
begin
  if current_setting('candidate.bulk_load', true) = 'on' then
    return coalesce(new, old);
  end if;
  perform candidate.recompute_candidate_status(coalesce(new.candidate_id, old.candidate_id));
  return coalesce(new, old);
end $$;

create or replace function candidate.trg_recompute_from_cand_set()
returns trigger language plpgsql security definer
set search_path = candidate, public as $$
begin
  if current_setting('candidate.bulk_load', true) = 'on' then
    return coalesce(new, old);
  end if;
  perform candidate.recompute_candidate_status(coalesce(new.candidate_id, old.candidate_id));
  return coalesce(new, old);
end $$;

create or replace function candidate.trg_recompute_from_set_item()
returns trigger language plpgsql security definer
set search_path = candidate, public as $$
begin
  if current_setting('candidate.bulk_load', true) = 'on' then
    return coalesce(new, old);
  end if;
  perform candidate.recompute_candidate_status(crs.candidate_id)
  from candidate.candidate_requirement_sets crs
  where crs.set_id = coalesce(new.set_id, old.set_id) and crs.active;
  return coalesce(new, old);
end $$;

-- ── RLS: let compliance officers see the whole bench ────────────────────────
-- Amends the 18_desks.sql desk-silo read policy. Recruiters still see only their
-- desk(s); compliance officers (and admins) see every candidate.
drop policy if exists "desk read candidates" on candidate.candidates;
create policy "desk read candidates" on candidate.candidates for select to authenticated
  using (candidate.is_authorized_user()
         and (candidate.is_admin()
              or candidate.is_compliance_officer()
              or desk_id in (select candidate.my_desk_ids())));

-- ── Scale indexes ───────────────────────────────────────────────────────────
-- The recompute lateral hot path (latest item per candidate+requirement).
create index if not exists compliance_items_recompute_idx
  on candidate.compliance_items (candidate_id, requirement_id, updated_at desc);
create index if not exists compliance_items_requirement_idx
  on candidate.compliance_items (requirement_id);
create index if not exists compliance_items_migrated_idx
  on candidate.compliance_items (migrated) where migrated;

create index if not exists candidate_compliance_status_status_idx
  on candidate.candidate_compliance_status (status);
create index if not exists candidate_compliance_status_set_status_idx
  on candidate.candidate_compliance_status (set_id, status);
create index if not exists candidate_compliance_status_expiry_idx
  on candidate.candidate_compliance_status (next_expiry);

create index if not exists candidate_requirement_sets_active_set_idx
  on candidate.candidate_requirement_sets (set_id) where active;

-- ==== sql/26_requirement_set_map.sql ====
-- ============================================================================
--  Day Webster — Candidate Pipeline · Compliance Phase 1: set auto-assignment
--  File: candidate-pipeline/sql/26_requirement_set_map.sql
--  Run AFTER 25. Idempotent / additive.  STATUS: DRAFT — NOT YET APPLIED.
--
--  Maps (discipline, specialty) -> requirement set(s) and auto-assigns them to a
--  candidate whenever their discipline/specialty changes. Resolution:
--    · BASE set = highest-priority non-add-on row matching (discipline, specialty);
--      a specialty match beats a discipline-wide (specialty_id is null) row.
--    · plus ALL add_on=true matches (add-ons STACK).
--  Assignments always pin the LATEST ACTIVE VERSION of the resolved set code.
--  Both functions early-return under the `candidate.bulk_load` guard so the bulk
--  migration (file 29) drives assignment itself, set-based, with no trigger storm.
-- ============================================================================

create table if not exists candidate.requirement_set_map (
  id            uuid primary key default gen_random_uuid(),
  discipline_id uuid not null references candidate.disciplines(id) on delete cascade,
  specialty_id  uuid references candidate.specialties(id) on delete cascade,
  set_id        uuid not null references candidate.requirement_sets(id) on delete cascade,
  add_on        boolean not null default false,
  active        boolean not null default true,
  priority      int not null default 100,   -- higher wins among equal-specificity base rows
  unique (discipline_id, specialty_id, set_id)
);
create index if not exists requirement_set_map_lookup_idx
  on candidate.requirement_set_map (discipline_id, specialty_id);

alter table candidate.requirement_set_map enable row level security;
drop policy if exists "auth read set_map"  on candidate.requirement_set_map;
drop policy if exists "admin write set_map" on candidate.requirement_set_map;
create policy "auth read set_map" on candidate.requirement_set_map
  for select to authenticated using (candidate.is_authorized_user());
create policy "admin write set_map" on candidate.requirement_set_map
  for all to authenticated
  using (candidate.is_authorized_user() and candidate.is_admin())
  with check (candidate.is_authorized_user() and candidate.is_admin());

-- ── materialize_items: insert `not_started` placeholders for a candidate ────
-- One placeholder per requirement across the candidate's ACTIVE sets that has no
-- compliance_item yet. `distinct` dedupes requirements shared by several sets.
create or replace function candidate.materialize_items(p_candidate_id uuid)
returns void language plpgsql security definer
set search_path = candidate, public as $$
begin
  if current_setting('candidate.bulk_load', true) = 'on' then return; end if;

  insert into candidate.compliance_items (candidate_id, requirement_id, status)
  select distinct p_candidate_id, rsi.requirement_id, 'not_started'
  from candidate.candidate_requirement_sets crs
  join candidate.requirement_set_items rsi on rsi.set_id = crs.set_id
  where crs.candidate_id = p_candidate_id and crs.active
    and not exists (
      select 1 from candidate.compliance_items ci
      where ci.candidate_id = p_candidate_id
        and ci.requirement_id = rsi.requirement_id
    );
end;
$$;
revoke all on function candidate.materialize_items(uuid) from public;
grant execute on function candidate.materialize_items(uuid) to service_role;

-- ── assign_requirement_sets: resolve + upsert + deactivate + materialize ────
create or replace function candidate.assign_requirement_sets(p_candidate_id uuid)
returns void language plpgsql security definer
set search_path = candidate, public as $$
declare
  v_disc     uuid;
  v_spec     uuid;
  v_resolved uuid[];   -- latest-active-version set ids the candidate should hold
begin
  if current_setting('candidate.bulk_load', true) = 'on' then return; end if;

  select discipline_id, primary_specialty_id into v_disc, v_spec
  from candidate.candidates where id = p_candidate_id;

  if v_disc is null then
    -- Nothing to resolve; leave any existing assignments untouched.
    return;
  end if;

  -- Resolve base (best single) + all add-ons, then map each to its latest
  -- active version id.
  select coalesce(array_agg(lv.id), '{}'::uuid[])
  into v_resolved
  from (
    with matches as (
      select m.set_id, m.add_on, m.priority,
             (m.specialty_id is not null) as spec_match
      from candidate.requirement_set_map m
      where m.active
        and m.discipline_id = v_disc
        and (m.specialty_id is null or m.specialty_id = v_spec)
    ),
    base as (
      select set_id from matches
      where not add_on
      order by spec_match desc, priority desc
      limit 1
    ),
    chosen as (
      select set_id from base
      union
      select set_id from matches where add_on
    )
    select distinct rs.code
    from chosen c
    join candidate.requirement_sets rs on rs.id = c.set_id
  ) codes
  join lateral (
    select rs2.id
    from candidate.requirement_sets rs2
    where rs2.code = codes.code and rs2.status = 'active'
    order by rs2.version desc
    limit 1
  ) lv on true;

  -- Upsert the resolved sets active.
  insert into candidate.candidate_requirement_sets
    (candidate_id, set_id, set_code, set_version, active)
  select p_candidate_id, rs.id, rs.code, rs.version, true
  from unnest(v_resolved) as r(set_id)
  join candidate.requirement_sets rs on rs.id = r.set_id
  on conflict (candidate_id, set_id) do update set active = true;

  -- Deactivate previously-assigned sets that no longer resolve (Phase 0
  -- recompute then drops their stale status row => fail-closed).
  update candidate.candidate_requirement_sets crs
  set active = false
  where crs.candidate_id = p_candidate_id
    and crs.active
    and not (crs.set_id = any(v_resolved));

  perform candidate.materialize_items(p_candidate_id);
end;
$$;
revoke all on function candidate.assign_requirement_sets(uuid) from public;
grant execute on function candidate.assign_requirement_sets(uuid) to service_role;

-- ── Day-to-day trigger: (re)assign on discipline/specialty change ───────────
create or replace function candidate.trg_assign_sets()
returns trigger language plpgsql security definer
set search_path = candidate, public as $$
begin
  if current_setting('candidate.bulk_load', true) = 'on' then return new; end if;
  perform candidate.assign_requirement_sets(new.id);
  return new;
end $$;

drop trigger if exists candidates_assign_sets on candidate.candidates;
create trigger candidates_assign_sets
  after insert or update of discipline_id, primary_specialty_id
  on candidate.candidates
  for each row execute function candidate.trg_assign_sets();

-- ==== sql/27_seed_requirement_sets.sql ====
-- ============================================================================
--  Day Webster — Candidate Pipeline · Compliance Phase 1: seed requirement sets
--  File: candidate-pipeline/sql/27_seed_requirement_sets.sql
--  Run AFTER 22-26 and 13 (catalogue). Idempotent.  STATUS: DRAFT — NOT APPLIED.
--
--  Composes one versioned set per job type from the already-seeded catalogue
--  codes in 13_compliance_requirements.sql, and seeds requirement_set_map so
--  candidates auto-assign on qualification (file 26). NHS_RN is seeded by 24.
--
--  D5: HCAs need a Care Certificate but 13_ only scopes `care_certificate` to
--  complex_care / care_homes. We add a nursing-scoped row here so NHS_HCA can
--  require it (cleaner than cross-scoping an existing row).
--
--  Every referenced (code, discipline, specialty) was reconciled against
--  13_compliance_requirements.sql: 'rtw' in the design table == catalogue code
--  `right_to_work`; DBS variants are `dbs_enhanced` (nursing/doctors/ahp/
--  complex_care), `dbs_enhanced_adults` (care_homes), `dbs_enhanced_children`
--  (childrens); `fit_person_declaration` is specialty-scoped to registered_mgr.
--  INSURANCE `financial_reference` is required=false in the catalogue, so the set
--  carries required_override=true to make it a real (standard/amber) requirement.
-- ============================================================================

-- ── D5: nursing-scoped Care Certificate (for the HCA set) ───────────────────
-- NB: the catalogue unique key is (discipline_id, specialty_id, code); here
-- specialty_id is NULL and Postgres treats NULLs as distinct, so an ON CONFLICT
-- on that key would never fire (and would insert a duplicate on re-run). Guard
-- idempotency with an explicit NOT EXISTS instead.
insert into candidate.compliance_requirements
  (discipline_id, code, name, tier, required, expiry_rule, coverage_rule, needs_human, sort_order)
select (select id from candidate.disciplines where code = 'nursing'),
       'care_certificate', 'Care Certificate', 'A', true, null, null, false, 55
where not exists (
  select 1 from candidate.compliance_requirements
  where code = 'care_certificate'
    and discipline_id = (select id from candidate.disciplines where code = 'nursing')
    and specialty_id is null
);

-- ── The sets (all version 1) ────────────────────────────────────────────────
insert into candidate.requirement_sets (code, version, name, sector, discipline_id, status, notes)
select v.code, 1, v.name, v.sector,
       (select id from candidate.disciplines where code = v.disc),
       'active', v.notes
from (values
  ('NHS_HCA',           'NHS Healthcare Assistant',              'nhs',       'nursing',      'Phase 1: NHS HCA checks + Care Certificate.'),
  ('NHS_DOCTOR',        'NHS Doctor / Locum',                    'nhs',       'doctors',      'Phase 1: NHS doctor checks + GMC + indemnity.'),
  ('AHP_HCPC',          'AHP (HCPC registered)',                 'nhs',       'ahp',          'Phase 1: NHS AHP checks + HCPC.'),
  ('COMPLEX_CARE',      'Complex Care (CQC)',                    'care',      'complex_care', 'Phase 1: complex care package.'),
  ('CARE_HOME',         'Care Home (CQC)',                       'care',      'care_homes',   'Phase 1: care home package (adults barred DBS).'),
  ('CHILDRENS',         'Children''s Services (Ofsted)',         'childrens', 'childrens',    'Phase 1: children''s services package (children barred DBS).'),
  ('INSURANCE',         'Insurance (John Williams)',             'insurance', 'insurance',    'Phase 1: non-clinical insurance package.'),
  ('REG_MGR_CHILDRENS', 'Registered Manager add-on (Children''s)','childrens','childrens',    'Phase 1 add-on: fit-person declaration.'),
  ('REG_MGR_CARE_HOME', 'Registered Manager add-on (Care Home)', 'care',      'care_homes',   'Phase 1 add-on: fit-person declaration.')
) as v(code, name, sector, disc, notes)
on conflict (code, version) do nothing;

-- ── Compose the set items from catalogue codes ──────────────────────────────
-- Join key: (code, discipline, specialty). disc/spec NULL matches a global /
-- discipline-scoped catalogue row via `is not distinct from`.
insert into candidate.requirement_set_items
  (set_id, requirement_id, criticality, required_override, sort_order)
select rs.id, cr.id, v.criticality, v.req_override, v.so
from (values
  -- set_code,            code,                    disc,           spec,             criticality, req_override, sort
  -- NHS_HCA (nursing/hca base)
  ('NHS_HCA',            'right_to_work',          null::text,     null::text,       'blocking',  null::boolean,  10),
  ('NHS_HCA',            'proof_of_address',       null,           null,             'blocking',  null,           20),
  ('NHS_HCA',            'references_3yr',         null,           null,             'blocking',  null,           30),
  ('NHS_HCA',            'care_certificate',       'nursing',      null,             'blocking',  null,           55),
  ('NHS_HCA',            'dbs_enhanced',           'nursing',      null,             'blocking',  null,           60),
  ('NHS_HCA',            'occupational_health',    'nursing',      null,             'blocking',  null,           70),
  ('NHS_HCA',            'immunisations',          'nursing',      null,             'blocking',  null,           80),
  ('NHS_HCA',            'mandatory_training',     'nursing',      null,             'standard',  null,           90),
  ('NHS_HCA',            'cv',                     null,           null,             'advisory',  null,          100),
  -- NHS_DOCTOR
  ('NHS_DOCTOR',         'right_to_work',          null,           null,             'blocking',  null,           10),
  ('NHS_DOCTOR',         'proof_of_address',       null,           null,             'blocking',  null,           20),
  ('NHS_DOCTOR',         'references_3yr',         null,           null,             'blocking',  null,           30),
  ('NHS_DOCTOR',         'gmc_registration',       'doctors',      null,             'blocking',  null,           40),
  ('NHS_DOCTOR',         'qualification_cert',     'doctors',      null,             'blocking',  null,           50),
  ('NHS_DOCTOR',         'indemnity',              'doctors',      null,             'blocking',  null,           55),
  ('NHS_DOCTOR',         'dbs_enhanced',           'doctors',      null,             'blocking',  null,           60),
  ('NHS_DOCTOR',         'occupational_health',    'doctors',      null,             'blocking',  null,           70),
  ('NHS_DOCTOR',         'immunisations',          'doctors',      null,             'blocking',  null,           80),
  ('NHS_DOCTOR',         'mandatory_training',     'doctors',      null,             'standard',  null,           90),
  ('NHS_DOCTOR',         'cv',                     null,           null,             'advisory',  null,          100),
  ('NHS_DOCTOR',         'overseas_police_check',  null,           null,             'advisory',  false,         110),
  -- AHP_HCPC
  ('AHP_HCPC',           'right_to_work',          null,           null,             'blocking',  null,           10),
  ('AHP_HCPC',           'proof_of_address',       null,           null,             'blocking',  null,           20),
  ('AHP_HCPC',           'references_3yr',         null,           null,             'blocking',  null,           30),
  ('AHP_HCPC',           'hcpc_registration',      'ahp',          null,             'blocking',  null,           40),
  ('AHP_HCPC',           'qualification_cert',     'ahp',          null,             'blocking',  null,           50),
  ('AHP_HCPC',           'dbs_enhanced',           'ahp',          null,             'blocking',  null,           60),
  ('AHP_HCPC',           'occupational_health',    'ahp',          null,             'blocking',  null,           70),
  ('AHP_HCPC',           'immunisations',          'ahp',          null,             'blocking',  null,           80),
  ('AHP_HCPC',           'mandatory_training',     'ahp',          null,             'standard',  null,           90),
  ('AHP_HCPC',           'cv',                     null,           null,             'advisory',  null,          100),
  ('AHP_HCPC',           'overseas_police_check',  null,           null,             'advisory',  false,         110),
  -- COMPLEX_CARE
  ('COMPLEX_CARE',       'right_to_work',          null,           null,             'blocking',  null,           10),
  ('COMPLEX_CARE',       'proof_of_address',       null,           null,             'blocking',  null,           20),
  ('COMPLEX_CARE',       'references_3yr',         null,           null,             'blocking',  null,           30),
  ('COMPLEX_CARE',       'care_certificate',       'complex_care', null,             'blocking',  null,           55),
  ('COMPLEX_CARE',       'dbs_enhanced',           'complex_care', null,             'blocking',  null,           60),
  ('COMPLEX_CARE',       'occupational_health',    'complex_care', null,             'blocking',  null,           70),
  ('COMPLEX_CARE',       'mandatory_training',     'complex_care', null,             'standard',  null,           90),
  ('COMPLEX_CARE',       'cv',                     null,           null,             'advisory',  null,          100),
  -- CARE_HOME
  ('CARE_HOME',          'right_to_work',          null,           null,             'blocking',  null,           10),
  ('CARE_HOME',          'proof_of_address',       null,           null,             'blocking',  null,           20),
  ('CARE_HOME',          'references_3yr',         null,           null,             'blocking',  null,           30),
  ('CARE_HOME',          'care_certificate',       'care_homes',   null,             'blocking',  null,           55),
  ('CARE_HOME',          'dbs_enhanced_adults',    'care_homes',   null,             'blocking',  null,           60),
  ('CARE_HOME',          'occupational_health',    'care_homes',   null,             'blocking',  null,           70),
  ('CARE_HOME',          'mandatory_training',     'care_homes',   null,             'standard',  null,           90),
  ('CARE_HOME',          'cv',                     null,           null,             'advisory',  null,          100),
  -- CHILDRENS
  ('CHILDRENS',          'right_to_work',          null,           null,             'blocking',  null,           10),
  ('CHILDRENS',          'proof_of_address',       null,           null,             'blocking',  null,           20),
  ('CHILDRENS',          'references_3yr',         null,           null,             'blocking',  null,           30),
  ('CHILDRENS',          'qualification_cert',     'childrens',    null,             'blocking',  null,           50),
  ('CHILDRENS',          'dbs_enhanced_children',  'childrens',    null,             'blocking',  null,           60),
  ('CHILDRENS',          'mandatory_training',     'childrens',    null,             'standard',  null,           90),
  ('CHILDRENS',          'cv',                     null,           null,             'advisory',  null,          100),
  -- INSURANCE (non-clinical). financial_reference is catalogue-optional => force required.
  ('INSURANCE',          'right_to_work',          null,           null,             'blocking',  null,           10),
  ('INSURANCE',          'proof_of_address',       null,           null,             'standard',  null,           20),
  ('INSURANCE',          'financial_reference',    'insurance',    null,             'standard',  true,           60),
  ('INSURANCE',          'cii_qualification',      'insurance',    null,             'advisory',  null,           50),
  ('INSURANCE',          'cv',                     null,           null,             'advisory',  null,          100),
  -- REG_MGR add-ons (specialty-scoped fit_person_declaration)
  ('REG_MGR_CHILDRENS',  'fit_person_declaration', 'childrens',    'registered_mgr', 'blocking',  null,          120),
  ('REG_MGR_CARE_HOME',  'fit_person_declaration', 'care_homes',   'registered_mgr', 'blocking',  null,          120)
) as v(set_code, code, disc, spec, criticality, req_override, so)
join candidate.requirement_sets rs
  on rs.code = v.set_code and rs.version = 1
join candidate.compliance_requirements cr
  on cr.code = v.code
 and cr.discipline_id is not distinct from
     (select id from candidate.disciplines where code = v.disc)
 and cr.specialty_id is not distinct from
     (select s.id from candidate.specialties s
        join candidate.disciplines d2 on d2.id = s.discipline_id
       where d2.code = v.disc and s.code = v.spec)
on conflict (set_id, requirement_id) do nothing;

-- ── requirement_set_map: (discipline, specialty) -> set ─────────────────────
-- Base rows (specialty null except HCA); add-ons flagged. NHS_RN stays the
-- nursing discipline-wide base; hca specialty overrides it to NHS_HCA.
insert into candidate.requirement_set_map (discipline_id, specialty_id, set_id, add_on, priority)
select d.id, s.id, rs.id, v.add_on, v.priority
from (values
  ('nursing',      null::text,        'NHS_RN',            false, 100),
  ('nursing',      'hca',             'NHS_HCA',           false, 200),
  ('doctors',      null,              'NHS_DOCTOR',        false, 100),
  ('ahp',          null,              'AHP_HCPC',          false, 100),
  ('complex_care', null,              'COMPLEX_CARE',      false, 100),
  ('care_homes',   null,              'CARE_HOME',         false, 100),
  ('childrens',    null,              'CHILDRENS',         false, 100),
  ('insurance',    null,              'INSURANCE',         false, 100),
  ('childrens',    'registered_mgr',  'REG_MGR_CHILDRENS', true,  100),
  ('care_homes',   'registered_mgr',  'REG_MGR_CARE_HOME', true,  100)
) as v(disc, spec, set_code, add_on, priority)
join candidate.disciplines d on d.code = v.disc
left join candidate.specialties s on s.discipline_id = d.id and s.code = v.spec
join candidate.requirement_sets rs on rs.code = v.set_code and rs.version = 1
where not exists (
  select 1 from candidate.requirement_set_map m
  where m.discipline_id = d.id
    and m.specialty_id is not distinct from s.id
    and m.set_id = rs.id
);

-- ==== sql/28_evidence.sql ====
-- ============================================================================
--  Day Webster — Candidate Pipeline · Compliance Phase 1: evidence store
--  File: candidate-pipeline/sql/28_evidence.sql
--  Run AFTER 22-27. Idempotent / additive.  STATUS: DRAFT — NOT YET APPLIED.
--
--  compliance_items.artefact_path holds a single document; the portal needs
--  multiple docs per requirement (+ audit-pack compilation). This table records
--  every uploaded artefact in the private `candidate-docs` bucket. RLS: any
--  authorised staff may READ (to build audit packs / preview signed URLs);
--  only compliance officers may INSERT; only admins may DELETE.
-- ============================================================================

create table if not exists candidate.candidate_evidence (
  id             uuid primary key default gen_random_uuid(),
  candidate_id   uuid not null references candidate.candidates(id) on delete cascade,
  item_id        uuid references candidate.compliance_items(id) on delete set null,
  requirement_id uuid references candidate.compliance_requirements(id) on delete set null,
  bucket         text not null default 'candidate-docs',
  path           text not null,               -- object path within the bucket
  filename       text,
  content_type   text,
  size_bytes     bigint,
  sha256         text,
  uploaded_by    uuid references auth.users(id) on delete set null,
  uploaded_at    timestamptz not null default now()
);
create index if not exists candidate_evidence_candidate_idx
  on candidate.candidate_evidence (candidate_id);
create index if not exists candidate_evidence_item_idx
  on candidate.candidate_evidence (item_id);
create index if not exists candidate_evidence_requirement_idx
  on candidate.candidate_evidence (requirement_id);

alter table candidate.candidate_evidence enable row level security;

drop policy if exists "auth read evidence"          on candidate.candidate_evidence;
drop policy if exists "compliance insert evidence"  on candidate.candidate_evidence;
drop policy if exists "admin delete evidence"       on candidate.candidate_evidence;

create policy "auth read evidence" on candidate.candidate_evidence
  for select to authenticated
  using (candidate.is_authorized_user());

create policy "compliance insert evidence" on candidate.candidate_evidence
  for insert to authenticated
  with check (candidate.is_authorized_user() and candidate.is_compliance_officer());

create policy "admin delete evidence" on candidate.candidate_evidence
  for delete to authenticated
  using (candidate.is_authorized_user() and candidate.is_admin());
-- (No UPDATE policy: evidence rows are write-once; correct a mistake by
--  deleting [admin] and re-inserting.)

-- ==== sql/29_compliance_ops.sql ====
-- ============================================================================
--  Day Webster — Candidate Pipeline · Compliance Phase 1: ops surface
--  File: candidate-pipeline/sql/29_compliance_ops.sql
--  Run AFTER 22-28. Idempotent / additive.  STATUS: DRAFT — NOT YET APPLIED.
--
--  The compliance team's server side:
--    · compliance_worklist  — security_invoker view (one row per candidate+set),
--      pre-joined so the cockpit paginates on indexed scalars.
--    · compliance_dashboard(desk,set) — RAG / expiring / needs-review / backlog.
--    · decide_item(item,decision,reason) — atomic status update + audit event.
--    · bulk_assign_set / bulk_request    — bulk_load-guarded, one recompute.
--    · import_compliance_bulk(rows)      — the set-based migration path (D1/D2).
--
--  Invariants preserved: candidate_compliance_status keeps NO client write
--  policy (only SECURITY DEFINER recompute writes it); verification_events stays
--  append-only. Every SECURITY DEFINER fn pins search_path = candidate, public.
-- ============================================================================

-- ── Worklist view (security_invoker: RLS is the querying user's) ────────────
-- A recruiter sees only their desk's rows; a compliance officer / admin sees the
-- whole bench (25_ desk-read policy). One row per (candidate, active set).
create or replace view candidate.compliance_worklist
with (security_invoker = true) as
select
  s.candidate_id,
  s.set_id,
  s.status,
  s.blocking_open,
  s.needs_human_count,
  s.expiring_count,
  s.next_expiry,
  s.computed_at,
  crs.set_code,
  crs.set_version,
  c.first_name,
  c.last_name,
  c.email,
  c.phone,
  c.discipline_id,
  c.primary_specialty_id,
  c.desk_id,
  c.owner_user,
  d.code as discipline_code,
  d.name as discipline_name,
  exists (
    select 1 from candidate.compliance_items ci
    where ci.candidate_id = s.candidate_id and ci.migrated
  ) as has_migrated
from candidate.candidate_compliance_status s
join candidate.candidate_requirement_sets crs
  on crs.candidate_id = s.candidate_id and crs.set_id = s.set_id and crs.active
join candidate.candidates c on c.id = s.candidate_id
left join candidate.disciplines d on d.id = c.discipline_id;

grant select on candidate.compliance_worklist to authenticated;

-- ── Dashboard: aggregate counters for the compliance team ───────────────────
create or replace function candidate.compliance_dashboard(p_desk uuid default null,
                                                          p_set  uuid default null)
returns jsonb language plpgsql stable security definer
set search_path = candidate, public as $$
declare v jsonb;
begin
  if not (candidate.is_authorized_user() and candidate.is_compliance_officer()) then
    raise exception 'not authorized';
  end if;

  with scope as (
    select s.*
    from candidate.candidate_compliance_status s
    join candidate.candidate_requirement_sets crs
      on crs.candidate_id = s.candidate_id and crs.set_id = s.set_id and crs.active
    join candidate.candidates c on c.id = s.candidate_id
    where (p_desk is null or c.desk_id = p_desk)
      and (p_set  is null or s.set_id  = p_set)
  )
  select jsonb_build_object(
    'rag', (
      select coalesce(jsonb_object_agg(status, cnt), '{}'::jsonb)
      from (select status, count(*) cnt from scope group by status) t
    ),
    'needs_review', (select count(*) from scope where needs_human_count > 0),
    'migration_backlog', (
      select count(distinct s.candidate_id)
      from scope s
      where exists (select 1 from candidate.compliance_items ci
                    where ci.candidate_id = s.candidate_id and ci.migrated)
    ),
    'expiring', jsonb_build_object(
      'd30', (select count(*) from scope where next_expiry is not null
                and next_expiry <= now() + interval '30 days'),
      'd60', (select count(*) from scope where next_expiry is not null
                and next_expiry <= now() + interval '60 days'),
      'd90', (select count(*) from scope where next_expiry is not null
                and next_expiry <= now() + interval '90 days')
    )
  ) into v;

  return v;
end;
$$;
revoke all on function candidate.compliance_dashboard(uuid, uuid) from public;
grant execute on function candidate.compliance_dashboard(uuid, uuid) to authenticated;

-- ── decide_item: atomic decision + append-only audit event ──────────────────
-- decision ∈ {verify, reject, waive}; waive requires a reason. The compliance_
-- items update fires trg_recompute_from_item => the RAG light refreshes.
create or replace function candidate.decide_item(p_item_id  uuid,
                                                 p_decision text,
                                                 p_reason   text default null)
returns void language plpgsql security definer
set search_path = candidate, public as $$
declare
  v_item       candidate.compliance_items;
  v_new_status text;
  v_event      text;
begin
  if not (candidate.is_authorized_user() and candidate.is_compliance_officer()) then
    raise exception 'not authorized';
  end if;
  if p_decision not in ('verify', 'reject', 'waive') then
    raise exception 'unknown decision: %', p_decision;
  end if;
  if p_decision = 'waive' and (p_reason is null or btrim(p_reason) = '') then
    raise exception 'a reason is required to waive a requirement';
  end if;

  select * into v_item from candidate.compliance_items where id = p_item_id;
  if not found then
    raise exception 'compliance item % not found', p_item_id;
  end if;

  v_new_status := case p_decision
                    when 'verify' then 'verified'
                    when 'reject' then 'unsuitable'
                    when 'waive'  then 'waived' end;
  v_event      := case p_decision
                    when 'verify' then 'verified'
                    when 'reject' then 'unsuitable'
                    when 'waive'  then 'waived' end;

  update candidate.compliance_items
  set status      = v_new_status,
      -- a human verification clears the migrated re-verify flag
      migrated    = case when p_decision = 'verify' then false else migrated end,
      needs_human = false,
      decided_by  = auth.uid(),
      human_notes = coalesce(p_reason, human_notes),
      updated_at  = now()
  where id = p_item_id;

  insert into candidate.verification_events
    (candidate_id, item_id, requirement_id, event_type, old_status, new_status,
     method, notes, actor, actor_kind)
  values
    (v_item.candidate_id, p_item_id, v_item.requirement_id, v_event,
     v_item.status, v_new_status, 'human', p_reason, auth.uid(), 'human');
end;
$$;
revoke all on function candidate.decide_item(uuid, text, text) from public;
grant execute on function candidate.decide_item(uuid, text, text) to authenticated;

-- ── bulk_assign_set: assign a set (latest active version) to many candidates ─
create or replace function candidate.bulk_assign_set(p_ids uuid[], p_set_code text)
returns int language plpgsql security definer
set search_path = candidate, public as $$
declare
  v_set record;
begin
  -- D8: compliance-officer capability required (matches decide_item). No
  -- service-role bypass — the edge function calls the dedicated import RPC.
  if not candidate.is_compliance_officer() then
    raise exception 'not authorized';
  end if;

  select id, code, version into v_set
  from candidate.requirement_sets
  where code = p_set_code and status = 'active'
  order by version desc
  limit 1;
  if not found then
    raise exception 'unknown or inactive set: %', p_set_code;
  end if;

  perform set_config('candidate.bulk_load', 'on', true);

  insert into candidate.candidate_requirement_sets
    (candidate_id, set_id, set_code, set_version, active, assigned_by)
  select u.id, v_set.id, v_set.code, v_set.version, true, auth.uid()
  from unnest(p_ids) as u(id)
  join candidate.candidates c on c.id = u.id
  on conflict (candidate_id, set_id) do update set active = true;

  insert into candidate.compliance_items (candidate_id, requirement_id, status)
  select distinct u.id, rsi.requirement_id, 'not_started'
  from unnest(p_ids) as u(id)
  join candidate.requirement_set_items rsi on rsi.set_id = v_set.id
  where not exists (
    select 1 from candidate.compliance_items ci
    where ci.candidate_id = u.id and ci.requirement_id = rsi.requirement_id
  );

  perform candidate.recompute_candidate_status_bulk(p_ids);
  perform set_config('candidate.bulk_load', 'off', true);

  return coalesce(array_length(p_ids, 1), 0);
end;
$$;
revoke all on function candidate.bulk_assign_set(uuid[], text) from public;
grant execute on function candidate.bulk_assign_set(uuid[], text) to authenticated, service_role;

-- ── bulk_request: mark listed requirement codes as 'requested' ──────────────
-- Only requirements that already belong to the candidate's active set(s) are
-- touched, so we never invent an out-of-scope item.
create or replace function candidate.bulk_request(p_ids uuid[], p_codes text[])
returns int language plpgsql security definer
set search_path = candidate, public as $$
declare v_count int;
begin
  -- D8: compliance-officer capability required (matches decide_item).
  if not candidate.is_compliance_officer() then
    raise exception 'not authorized';
  end if;

  perform set_config('candidate.bulk_load', 'on', true);

  -- Create placeholders for in-scope requirements with no item yet.
  insert into candidate.compliance_items (candidate_id, requirement_id, status)
  select distinct crs.candidate_id, rsi.requirement_id, 'requested'
  from candidate.candidate_requirement_sets crs
  join candidate.requirement_set_items rsi on rsi.set_id = crs.set_id
  join candidate.compliance_requirements cr on cr.id = rsi.requirement_id
  where crs.active
    and crs.candidate_id = any(p_ids)
    and cr.code = any(p_codes)
    and not exists (
      select 1 from candidate.compliance_items ci
      where ci.candidate_id = crs.candidate_id and ci.requirement_id = rsi.requirement_id
    );

  -- Advance existing not_started items to requested.
  update candidate.compliance_items ci
  set status = 'requested', updated_at = now()
  from candidate.candidate_requirement_sets crs
  join candidate.requirement_set_items rsi on rsi.set_id = crs.set_id
  join candidate.compliance_requirements cr on cr.id = rsi.requirement_id
  where ci.candidate_id = crs.candidate_id
    and ci.requirement_id = rsi.requirement_id
    and crs.active
    and crs.candidate_id = any(p_ids)
    and cr.code = any(p_codes)
    and ci.status = 'not_started';

  perform candidate.recompute_candidate_status_bulk(p_ids);
  perform set_config('candidate.bulk_load', 'off', true);

  select coalesce(array_length(p_ids, 1), 0) into v_count;
  return v_count;
end;
$$;
revoke all on function candidate.bulk_request(uuid[], text[]) from public;
grant execute on function candidate.bulk_request(uuid[], text[]) to authenticated, service_role;

-- ── Migrated-item expiry helper (D2) ────────────────────────────────────────
-- Provided expiry wins; else derive from the catalogue rule + issue date; else
-- the 90-day migration grace window so nothing stays trusted-but-unverified.
create or replace function candidate.compute_migrated_expiry(p_rule   jsonb,
                                                             p_issue  date,
                                                             p_expiry date)
returns timestamptz language sql stable
set search_path = candidate, public as $$
  select coalesce(
    p_expiry::timestamptz,
    case
      when p_issue is null then null
      when p_rule->>'type' = 'issue_plus'
        then (p_issue + make_interval(years => (p_rule->>'years')::int))::timestamptz
      when p_rule->>'type' = 'upload_plus'
        then (p_issue + make_interval(years => (p_rule->>'years')::int))::timestamptz
      when p_rule->>'type' = 'issue_plus_days'
        then (p_issue + make_interval(days => (p_rule->>'days')::int))::timestamptz
      else null
    end,
    now() + interval '90 days'
  );
$$;

-- ── import_compliance_bulk: the set-based bulk migration (D1/D2) ─────────────
-- p_rows = jsonb array of normalized item rows produced by the compliance-import
-- edge function, each:
--   { email, phone, code, status?, issue_date?, expiry_date?, number?, evidence_note? }
-- Steps (all under the txn-local bulk_load guard so no fan-out triggers fire):
--   1 match candidate by lower(email) then phone   2 auto-assign sets via the map
--   3 set-based insert of verified/migrated items  4 one audit event per item
--   5 one recompute per batch.  Returns a match/insert report.
create or replace function candidate.import_compliance_bulk(p_rows jsonb)
returns jsonb language plpgsql security definer
set search_path = candidate, public as $$
declare
  v_total    int;
  v_unmatched int;
  v_items    int;
  v_unparsed int;
  v_oos      int;
  v_migrated_at timestamptz := now();  -- one migration timestamp for the batch
  v_result   jsonb;
begin
  perform set_config('candidate.bulk_load', 'on', true);

  -- 1. Parse + match to candidates (email first, then phone).
  --    expiry_unparsed = the source had a non-empty expiry cell the edge fn could
  --    not parse to a real date (D1/D3). Such items must NOT get the D2 90-day
  --    grace — an unknown/expired date can't be silently trusted.
  create temporary table _imp_match on commit drop as
  select r.email, r.phone, r.code, r.status, r.issue_date, r.expiry_date,
         coalesce(r.expiry_unparsed, false) as expiry_unparsed,
         r.number, r.evidence_note,
         coalesce(
           (select c.id from candidate.candidates c
             where r.email is not null and lower(c.email) = lower(r.email) limit 1),
           (select c.id from candidate.candidates c
             where r.phone is not null and c.phone = r.phone limit 1)
         ) as candidate_id
  from jsonb_to_recordset(p_rows) as r(
         email text, phone text, code text, status text,
         issue_date date, expiry_date date, expiry_unparsed boolean,
         number text, evidence_note text);

  select count(*), count(*) filter (where candidate_id is null),
         count(*) filter (where expiry_unparsed)
    into v_total, v_unmatched, v_unparsed
  from _imp_match;

  -- 2. Auto-assign sets for matched candidates (base best-match + all add-ons),
  --    each pinned to its latest active version.
  with cand as (
    select distinct candidate_id from _imp_match where candidate_id is not null
  ),
  resolved as (
    select r.candidate_id, r.set_id from (
      -- all add-ons
      select c.candidate_id, mp.set_id
      from cand c
      join candidate.candidates ca on ca.id = c.candidate_id
      join candidate.requirement_set_map mp
        on mp.active and mp.add_on and mp.discipline_id = ca.discipline_id
       and (mp.specialty_id is null or mp.specialty_id = ca.primary_specialty_id)
      union
      -- single best base
      select candidate_id, set_id from (
        select c.candidate_id, mp.set_id,
               row_number() over (partition by c.candidate_id
                 order by (mp.specialty_id is not null) desc, mp.priority desc) rn
        from cand c
        join candidate.candidates ca on ca.id = c.candidate_id
        join candidate.requirement_set_map mp
          on mp.active and not mp.add_on and mp.discipline_id = ca.discipline_id
         and (mp.specialty_id is null or mp.specialty_id = ca.primary_specialty_id)
      ) b where rn = 1
    ) r
  )
  insert into candidate.candidate_requirement_sets
    (candidate_id, set_id, set_code, set_version, active)
  select r.candidate_id, lv.id, lv.code, lv.version, true
  from resolved r
  join candidate.requirement_sets rs0 on rs0.id = r.set_id
  join lateral (
    select rs2.id, rs2.code, rs2.version
    from candidate.requirement_sets rs2
    where rs2.code = rs0.code and rs2.status = 'active'
    order by rs2.version desc limit 1
  ) lv on true
  on conflict (candidate_id, set_id) do nothing;

  -- 3. Set-based insert of migrated, verified items — only for codes that belong
  --    to the candidate's now-active set(s), so requirement scoping is exact.
  create temporary table _imp_ins on commit drop as
  with ins as (
    insert into candidate.compliance_items
      (candidate_id, requirement_id, status, channel, source_confidence,
       received_at, expires_at, needs_human, extracted, migrated)
    -- D7: two source rows for the same requirement collapse to ONE item; keep the
    -- best/newest deterministically (latest parsed expiry, then latest issue).
    select distinct on (i.candidate_id, rsi.requirement_id)
      i.candidate_id,
      rsi.requirement_id,
      'verified',
      'import',
      'migrated',
      v_migrated_at,
      -- D1/D3: an UNPARSEABLE expiry cell is landed as due-now (expires_at =
      -- migration_date) so the gate flags it red + needs re-verify immediately,
      -- rather than trusting an unknown date for the 90-day grace window.
      case when i.expiry_unparsed then v_migrated_at
           else candidate.compute_migrated_expiry(cr.expiry_rule, i.issue_date, i.expiry_date)
      end,
      i.expiry_unparsed,   -- needs_human: force a human to reconcile the bad date
      jsonb_strip_nulls(jsonb_build_object(
        'number', i.number, 'note', i.evidence_note, 'imported_status', i.status,
        'expiry_unparsed', nullif(i.expiry_unparsed, false))),
      true
    from _imp_match i
    join candidate.candidate_requirement_sets crs
      on crs.candidate_id = i.candidate_id and crs.active
    join candidate.requirement_set_items rsi on rsi.set_id = crs.set_id
    join candidate.compliance_requirements cr
      on cr.id = rsi.requirement_id and cr.code = i.code
    where i.candidate_id is not null
      and not exists (
        select 1 from candidate.compliance_items ci
        where ci.candidate_id = i.candidate_id
          and ci.requirement_id = rsi.requirement_id
          and ci.status = 'verified'
      )
    order by i.candidate_id, rsi.requirement_id,
             i.expiry_date desc nulls last, i.issue_date desc nulls last
    returning id, candidate_id, requirement_id
  )
  select * from ins;

  select count(*) into v_items from _imp_ins;

  -- D2: rows that matched a candidate but whose code is NOT in any of that
  -- candidate's active set items produce no item — count them so they don't
  -- vanish (distinct from unmatched-candidate rows).
  select count(*) into v_oos
  from _imp_match i
  where i.candidate_id is not null
    and not exists (
      select 1
      from candidate.candidate_requirement_sets crs
      join candidate.requirement_set_items rsi on rsi.set_id = crs.set_id
      join candidate.compliance_requirements cr on cr.id = rsi.requirement_id
      where crs.candidate_id = i.candidate_id and crs.active and cr.code = i.code
    );

  -- 4. One append-only provenance event per migrated item (D1).
  insert into candidate.verification_events
    (candidate_id, item_id, requirement_id, event_type, new_status,
     method, notes, actor_kind)
  select candidate_id, id, requirement_id, 'verified', 'verified',
         'import', 'bulk migration — provenance only', 'system'
  from _imp_ins;

  -- 5. One recompute per batch (covers matched-but-no-item candidates too).
  perform candidate.recompute_candidate_status_bulk(
    (select coalesce(array_agg(distinct candidate_id), '{}'::uuid[])
       from _imp_match where candidate_id is not null));

  perform set_config('candidate.bulk_load', 'off', true);

  v_result := jsonb_build_object(
    'rows',           v_total,
    'matched_rows',   v_total - v_unmatched,
    'unmatched_rows', v_unmatched,
    'candidates',     (select count(distinct candidate_id) from _imp_match
                        where candidate_id is not null),
    'items_inserted', v_items,
    'expiry_unparsed', v_unparsed,           -- D1/D3 data-quality signal
    'skipped_out_of_scope', v_oos,           -- D2 matched-but-not-in-set
    'unmatched_sample', (
      select coalesce(jsonb_agg(jsonb_build_object('email', email, 'phone', phone)), '[]'::jsonb)
      from (select distinct email, phone from _imp_match
             where candidate_id is null limit 50) s),
    'out_of_scope_sample', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'code', code, 'email', email, 'phone', phone)), '[]'::jsonb)
      from (
        select distinct i.code, i.email, i.phone
        from _imp_match i
        where i.candidate_id is not null
          and not exists (
            select 1
            from candidate.candidate_requirement_sets crs
            join candidate.requirement_set_items rsi on rsi.set_id = crs.set_id
            join candidate.compliance_requirements cr on cr.id = rsi.requirement_id
            where crs.candidate_id = i.candidate_id and crs.active and cr.code = i.code
          )
        limit 20) s)
  );
  return v_result;
end;
$$;
revoke all on function candidate.import_compliance_bulk(jsonb) from public;
grant execute on function candidate.import_compliance_bulk(jsonb) to service_role;

-- ==== sql/30_divisions.sql ====
-- ============================================================================
--  Day Webster — Candidate Pipeline · Division taxonomy (top of the tree)
--  File: candidate-pipeline/sql/30_divisions.sql
--  Run AFTER 10-29. Idempotent / additive.  STATUS: DRAFT — NOT YET APPLIED.
--
--  Adds the DIVISION layer above disciplines: divisions -> disciplines ->
--  specialties. A division is the business-unit grouping (Nursing, Doctors,
--  AHP & HSS, Social Care, Other) the cockpit filters and reports on. Purely a
--  parent grouping — the compliance engine still resolves sets from
--  (discipline, specialty); divisions never change what a candidate needs.
--
--  RLS mirrors 22/26: authorised staff READ; admins WRITE (is_admin()).
-- ============================================================================

-- ── Divisions table ─────────────────────────────────────────────────────────
create table if not exists candidate.divisions (
  id          uuid primary key default gen_random_uuid(),
  code        text not null unique,          -- machine key, e.g. 'nursing'
  name        text not null,                 -- display, e.g. 'Nursing Division'
  sort_order  int  not null default 100,
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

-- ── disciplines.division_id FK (+ lookup index) ─────────────────────────────
alter table candidate.disciplines
  add column if not exists division_id uuid references candidate.divisions(id) on delete set null;
create index if not exists disciplines_division_idx
  on candidate.disciplines (division_id);

-- ── RLS: auth read, admin write (mirror 22/26) ──────────────────────────────
alter table candidate.divisions enable row level security;
drop policy if exists "auth read divisions"  on candidate.divisions;
drop policy if exists "admin write divisions" on candidate.divisions;
create policy "auth read divisions" on candidate.divisions
  for select to authenticated using (candidate.is_authorized_user());
create policy "admin write divisions" on candidate.divisions
  for all to authenticated
  using (candidate.is_authorized_user() and candidate.is_admin())
  with check (candidate.is_authorized_user() and candidate.is_admin());

-- ── Seed the day-one divisions ──────────────────────────────────────────────
insert into candidate.divisions (code, name, sort_order) values
  ('nursing',     'Nursing Division',     10),
  ('doctors',     'Doctors Division',     20),
  ('ahp_hss',     'AHP & HSS Division',   30),
  ('social_care', 'Social Care',          40),
  ('other',       'Other / Non-clinical', 50)
on conflict (code) do nothing;

-- ── Map existing disciplines -> divisions ───────────────────────────────────
-- Deterministic Phase-1b mapping. `is distinct from` makes the re-run a no-op
-- and avoids clobbering a division that already matches.
update candidate.disciplines d
set division_id = dv.id
from (values
  ('nursing',      'nursing'),
  ('doctors',      'doctors'),
  ('ahp',          'ahp_hss'),
  ('complex_care', 'social_care'),
  ('care_homes',   'social_care'),
  ('childrens',    'social_care'),
  ('insurance',    'other')
) as m(disc_code, div_code)
join candidate.divisions dv on dv.code = m.div_code
where d.code = m.disc_code
  and d.division_id is distinct from dv.id;

-- ==== sql/31_role_taxonomy.sql ====
-- ============================================================================
--  Day Webster — Candidate Pipeline · Seed: role taxonomy extensions
--  File: candidate-pipeline/sql/31_role_taxonomy.sql
--  Run AFTER 12 (and 30). Idempotent (on conflict do nothing).
--
--  STATUS: DRAFT — NOT YET APPLIED. For review only.
--
--  Adds the specialties that Phase-1b role sets attach to (file 32), matching
--  the 12_candidate_seed.sql conventions (rows, never code). Specialties are
--  additive: new role = a new row.
--
--  Reconciliation vs 12_candidate_seed.sql:
--    · nursing already has: general, theatres, theatres_odp (HCPC), midwifery,
--      primary_care. We ADD hca (no reg), enp, anp here. The midwifery /
--      theatres_odp inserts below are defensive no-ops (present since 12) so
--      this file is self-sufficient regardless of 12's state.
--    · doctors already has: general, gp, specialty, consultant. We ADD
--      psychiatry (a specialty that INHERITS NHS_DOCTOR — no map row).
--    · ahp already has an `odp` specialty (used by file 32's belt-and-suspenders
--      ahp/odp -> NHS_ODP map row) — unchanged here.
-- ============================================================================

-- NURSING — new roles ---------------------------------------------------------
-- hca carries no regulator (support role); enp/anp are advanced-practice nurses
-- that INHERIT the base NHS_RN set (no map row in file 32).
insert into candidate.specialties (discipline_id, code, name, sort_order)
select d.id, v.code, v.name, v.so
from candidate.disciplines d,
  (values
    ('hca', 'Healthcare Assistant',          15),
    ('enp', 'Emergency Nurse Practitioner',  45),
    ('anp', 'Advanced Nurse Practitioner',   50)
  ) as v(code,name,so)
where d.code = 'nursing'
on conflict (discipline_id, code) do nothing;

-- NURSING — defensive (already seeded in 12; ODP within nursing -> HCPC) -------
insert into candidate.specialties (discipline_id, code, name, regulator_override, sort_order)
select d.id, v.code, v.name, v.reg, v.so
from candidate.disciplines d,
  (values
    ('midwifery',    'Midwifery',       null::text, 30),
    ('theatres_odp', 'Theatres (ODP)',  'HCPC',     25)
  ) as v(code,name,reg,so)
where d.code = 'nursing'
on conflict (discipline_id, code) do nothing;

-- DOCTORS — psychiatry (inherits NHS_DOCTOR — no map row) ----------------------
insert into candidate.specialties (discipline_id, code, name, sort_order)
select d.id, 'psychiatry', 'Psychiatry', 50
from candidate.disciplines d where d.code = 'doctors'
on conflict (discipline_id, code) do nothing;

-- ==== sql/32_seed_role_sets.sql ====
-- ============================================================================
--  Day Webster — Candidate Pipeline · Seed: role requirement sets + map fix
--  File: candidate-pipeline/sql/32_seed_role_sets.sql
--  Run AFTER 13, 22-27, 30, 31. Idempotent.  STATUS: DRAFT — NOT YET APPLIED.
--
--  Composes three more versioned sets from the seeded catalogue codes and wires
--  the (discipline, specialty) -> set map, THEN fixes the Phase-1 map bug.
--
--  Locked decisions honoured:
--    · NHS_MIDWIFE is a distinct set with composition identical to NHS_RN
--      (file 24) for now — diverge later by publishing a v2, never by editing.
--    · NHS_ODP is nursing-scoped but REUSES the ahp-scoped `hcpc_registration`
--      catalogue row (DRY) for its registration item; its clinical checks
--      (quals/dbs/oh/immunisations/training) are nursing-scoped.
--    · NHS_GP = NHS_DOCTOR + the National Performers List (blocking).
--    · enp/anp/psychiatry are specialties that INHERIT their discipline's base
--      set (NHS_RN / NHS_DOCTOR) — no map row, so the base resolves.
--
--  THE PHASE-1 BUG (fixed in section (c)):
--    27_seed_requirement_sets.sql maps nursing/hca -> NHS_HCA via a LEFT JOIN to
--    candidate.specialties, but the `hca` specialty did not exist yet (it is
--    added in file 31). The left join therefore produced specialty_id = NULL, so
--    NHS_HCA landed as a DISCIPLINE-WIDE row at priority 200 — outranking the
--    nursing-wide NHS_RN (priority 100). Result: EVERY nurse resolved to
--    NHS_HCA. Now that file 31 has added the specialties, we delete that bogus
--    row and insert the correct specialty-scoped rows.
-- ============================================================================

-- ── (a) New catalogue requirement: National Performers List (doctors) ───────
-- NULL-safe idempotency (per 27): specialty_id is NULL and the catalogue unique
-- key treats NULLs as distinct, so ON CONFLICT never fires — guard with NOT
-- EXISTS instead. criticality defaults to 'blocking' (added in 22).
insert into candidate.compliance_requirements
  (discipline_id, code, name, tier, required, expiry_rule, coverage_rule, needs_human, sort_order)
select (select id from candidate.disciplines where code = 'doctors'),
       'performers_list', 'National Performers List (NHS England)', 'C', true, null, null, true, 45
where not exists (
  select 1 from candidate.compliance_requirements
  where code = 'performers_list'
    and discipline_id = (select id from candidate.disciplines where code = 'doctors')
    and specialty_id is null
);

-- ── (b) The sets (all version 1) ────────────────────────────────────────────
insert into candidate.requirement_sets (code, version, name, sector, discipline_id, status, notes)
select v.code, 1, v.name, v.sector,
       (select id from candidate.disciplines where code = v.disc),
       'active', v.notes
from (values
  ('NHS_MIDWIFE', 'NHS Midwife',                            'nhs', 'nursing', 'Phase 1: composition identical to NHS_RN pending midwifery divergence.'),
  ('NHS_ODP',     'NHS Operating Department Practitioner',  'nhs', 'nursing', 'Phase 1: HCPC-registered ODP; reuses ahp hcpc_registration, nursing-scoped clinical checks.'),
  ('NHS_GP',      'NHS General Practitioner',               'nhs', 'doctors', 'Phase 1: NHS doctor checks + National Performers List.')
) as v(code, name, sector, disc, notes)
on conflict (code, version) do nothing;

-- ── Compose set items from catalogue codes (27's is-not-distinct-from join) ──
-- Join key: (code, discipline, specialty). disc/spec NULL matches a global /
-- discipline-scoped catalogue row. `conditional` carried like file 24 so
-- NHS_MIDWIFE stays byte-for-byte identical to NHS_RN.
insert into candidate.requirement_set_items
  (set_id, requirement_id, criticality, required_override, conditional, sort_order)
select rs.id, cr.id, v.criticality, v.req_override, v.conditional, v.so
from (values
  -- set_code,       code,                    disc,           spec,        criticality, req_override,  conditional,                        sort
  -- NHS_MIDWIFE (identical composition to NHS_RN / file 24)
  ('NHS_MIDWIFE',   'right_to_work',          null::text,     null::text,  'blocking',  null::boolean, null::jsonb,                        10),
  ('NHS_MIDWIFE',   'proof_of_address',       null,           null,        'blocking',  null,          null,                               20),
  ('NHS_MIDWIFE',   'references_3yr',          null,           null,        'blocking',  null,          null,                               30),
  ('NHS_MIDWIFE',   'nmc_registration',        'nursing',      null,        'blocking',  null,          null,                               40),
  ('NHS_MIDWIFE',   'qualification_cert',      'nursing',      null,        'blocking',  null,          null,                               50),
  ('NHS_MIDWIFE',   'dbs_enhanced',            'nursing',      null,        'blocking',  null,          null,                               60),
  ('NHS_MIDWIFE',   'occupational_health',     'nursing',      null,        'blocking',  null,          null,                               70),
  ('NHS_MIDWIFE',   'immunisations',           'nursing',      null,        'blocking',  null,          null,                               80),
  ('NHS_MIDWIFE',   'mandatory_training',      'nursing',      null,        'standard',  null,          null,                               90),
  ('NHS_MIDWIFE',   'cv',                      null,           null,        'advisory',  null,          null,                              100),
  ('NHS_MIDWIFE',   'overseas_police_check',   null,           null,        'advisory',  false,         '{"if":"overseas_history"}'::jsonb,110),
  -- NHS_ODP (AHP_HCPC shape; registration DRY-reuses ahp hcpc_registration)
  ('NHS_ODP',       'right_to_work',           null,           null,        'blocking',  null,          null,                               10),
  ('NHS_ODP',       'proof_of_address',        null,           null,        'blocking',  null,          null,                               20),
  ('NHS_ODP',       'references_3yr',          null,           null,        'blocking',  null,          null,                               30),
  ('NHS_ODP',       'hcpc_registration',       'ahp',          null,        'blocking',  null,          null,                               40),
  ('NHS_ODP',       'qualification_cert',      'nursing',      null,        'blocking',  null,          null,                               50),
  ('NHS_ODP',       'dbs_enhanced',            'nursing',      null,        'blocking',  null,          null,                               60),
  ('NHS_ODP',       'occupational_health',     'nursing',      null,        'blocking',  null,          null,                               70),
  ('NHS_ODP',       'immunisations',           'nursing',      null,        'blocking',  null,          null,                               80),
  ('NHS_ODP',       'mandatory_training',      'nursing',      null,        'standard',  null,          null,                               90),
  ('NHS_ODP',       'cv',                      null,           null,        'advisory',  null,          null,                              100),
  ('NHS_ODP',       'overseas_police_check',   null,           null,        'advisory',  false,         null,                              110),
  -- NHS_GP (NHS_DOCTOR items + performers_list)
  ('NHS_GP',        'right_to_work',           null,           null,        'blocking',  null,          null,                               10),
  ('NHS_GP',        'proof_of_address',        null,           null,        'blocking',  null,          null,                               20),
  ('NHS_GP',        'references_3yr',          null,           null,        'blocking',  null,          null,                               30),
  ('NHS_GP',        'gmc_registration',        'doctors',      null,        'blocking',  null,          null,                               40),
  ('NHS_GP',        'performers_list',         'doctors',      null,        'blocking',  null,          null,                               45),
  ('NHS_GP',        'qualification_cert',      'doctors',      null,        'blocking',  null,          null,                               50),
  ('NHS_GP',        'indemnity',               'doctors',      null,        'blocking',  null,          null,                               55),
  ('NHS_GP',        'dbs_enhanced',            'doctors',      null,        'blocking',  null,          null,                               60),
  ('NHS_GP',        'occupational_health',     'doctors',      null,        'blocking',  null,          null,                               70),
  ('NHS_GP',        'immunisations',           'doctors',      null,        'blocking',  null,          null,                               80),
  ('NHS_GP',        'mandatory_training',      'doctors',      null,        'standard',  null,          null,                               90),
  ('NHS_GP',        'cv',                      null,           null,        'advisory',  null,          null,                              100),
  ('NHS_GP',        'overseas_police_check',   null,           null,        'advisory',  false,         null,                              110)
) as v(set_code, code, disc, spec, criticality, req_override, conditional, so)
join candidate.requirement_sets rs
  on rs.code = v.set_code and rs.version = 1
join candidate.compliance_requirements cr
  on cr.code = v.code
 and cr.discipline_id is not distinct from
     (select id from candidate.disciplines where code = v.disc)
 and cr.specialty_id is not distinct from
     (select s.id from candidate.specialties s
        join candidate.disciplines d2 on d2.id = s.discipline_id
       where d2.code = v.disc and s.code = v.spec)
on conflict (set_id, requirement_id) do nothing;

-- ── (c) Fix the Phase-1 map bug, then wire the specialty rows ────────────────
-- 1. Delete the bogus DISCIPLINE-WIDE NHS_HCA row (specialty_id IS NULL) that
--    27 inserted before the `hca` specialty existed.
delete from candidate.requirement_set_map m
using candidate.disciplines d, candidate.requirement_sets rs
where m.discipline_id = d.id and d.code = 'nursing'
  and m.set_id = rs.id and rs.code = 'NHS_HCA'
  and m.specialty_id is null;

-- 2. Insert the correct SPECIALTY-scoped base rows (priority 200 beats the
--    discipline-wide base at 100). INNER JOIN to specialties so a missing
--    specialty is skipped rather than re-creating a null-specialty row. The
--    ahp/odp row is belt-and-suspenders (odp exists under ahp since file 12).
insert into candidate.requirement_set_map (discipline_id, specialty_id, set_id, add_on, priority)
select d.id, s.id, rs.id, false, 200
from (values
  ('nursing', 'hca',          'NHS_HCA'),
  ('nursing', 'midwifery',    'NHS_MIDWIFE'),
  ('nursing', 'theatres_odp', 'NHS_ODP'),
  ('doctors', 'gp',           'NHS_GP'),
  ('ahp',     'odp',          'NHS_ODP')
) as v(disc, spec, set_code)
join candidate.disciplines d on d.code = v.disc
join candidate.specialties s on s.discipline_id = d.id and s.code = v.spec
join candidate.requirement_sets rs on rs.code = v.set_code and rs.version = 1
where not exists (
  select 1 from candidate.requirement_set_map m
  where m.discipline_id = d.id
    and m.specialty_id is not distinct from s.id
    and m.set_id = rs.id
);

-- ==== sql/33_worklist_division.sql ====
-- ============================================================================
--  Day Webster — Candidate Pipeline · Worklist: division columns
--  File: candidate-pipeline/sql/33_worklist_division.sql
--  Run AFTER 29-32. Idempotent (create or replace).  STATUS: DRAFT — NOT YET APPLIED.
--
--  Re-declares candidate.compliance_worklist (from 29) so the cockpit can filter
--  and group by DIVISION. Same security_invoker view (RLS is the querying
--  user's); the three division columns are appended (create-or-replace requires
--  the existing column prefix to stay identical).
-- ============================================================================

create or replace view candidate.compliance_worklist
with (security_invoker = true) as
select
  s.candidate_id,
  s.set_id,
  s.status,
  s.blocking_open,
  s.needs_human_count,
  s.expiring_count,
  s.next_expiry,
  s.computed_at,
  crs.set_code,
  crs.set_version,
  c.first_name,
  c.last_name,
  c.email,
  c.phone,
  c.discipline_id,
  c.primary_specialty_id,
  c.desk_id,
  c.owner_user,
  d.code as discipline_code,
  d.name as discipline_name,
  exists (
    select 1 from candidate.compliance_items ci
    where ci.candidate_id = s.candidate_id and ci.migrated
  ) as has_migrated,
  d.division_id,
  dv.code as division_code,
  dv.name as division_name
from candidate.candidate_compliance_status s
join candidate.candidate_requirement_sets crs
  on crs.candidate_id = s.candidate_id and crs.set_id = s.set_id and crs.active
join candidate.candidates c on c.id = s.candidate_id
left join candidate.disciplines d on d.id = c.discipline_id
left join candidate.divisions dv on dv.id = d.division_id;

grant select on candidate.compliance_worklist to authenticated;

-- ==== sql/34_compliance_officer.sql ====
-- ============================================================================
--  Day Webster — Candidate Pipeline · Compliance officer assignment
--  File: candidate-pipeline/sql/34_compliance_officer.sql
--  Run AFTER 10-33. Idempotent / additive.  STATUS: DRAFT — NOT YET APPLIED.
--
--  Who owns a candidate's compliance? Adds a `compliance_officer` on the golden
--  record, an append-only assignment HISTORY (its own table — NOT the
--  verification_events audit spine, which is item-level), and the RPCs the
--  cockpit calls to (re)assign one, many, or a whole division of candidates.
--
--  Visibility model (locked): NO hard row restriction by officer. Every
--  authorised officer still sees the whole bench (desk-silo exemption from 25);
--  "my candidates" is a client-side filter on this column, not an RLS gate.
--
--  Assignment is ON-DEMAND ONLY — no trigger. NB: the `compliance_officer`
--  column is deliberately absent from the 26 trg_assign_sets `OF (...)` list and
--  the 18 autoroute `OF (...)` list, so writing it never fans out a set
--  re-assignment or a desk re-route.
-- ============================================================================

-- ── Attribution column (+ index) ────────────────────────────────────────────
alter table candidate.candidates
  add column if not exists compliance_officer uuid references auth.users(id) on delete set null;
create index if not exists candidates_compliance_officer_idx
  on candidate.candidates (compliance_officer);

-- ── Append-only assignment history ──────────────────────────────────────────
-- Own table (not verification_events): that spine is item/verification-level and
-- immutable for evidence; officer changes are a separate ownership ledger.
create table if not exists candidate.officer_assignments (
  id               uuid primary key default gen_random_uuid(),
  candidate_id     uuid not null references candidate.candidates(id) on delete cascade,
  officer          uuid references auth.users(id) on delete set null,   -- null = unassigned
  previous_officer uuid references auth.users(id) on delete set null,
  method           text not null default 'manual'
                   check (method in ('manual','bulk','auto','system')),
  reason           text,
  assigned_by      uuid references auth.users(id) on delete set null,
  assigned_at      timestamptz not null default now()
);
create index if not exists officer_assignments_candidate_idx
  on candidate.officer_assignments (candidate_id, assigned_at desc);
create index if not exists officer_assignments_officer_idx
  on candidate.officer_assignments (officer);

-- ── RLS: compliance officers READ + INSERT; NO update/delete => immutable ────
alter table candidate.officer_assignments enable row level security;
drop policy if exists "compliance read officer_assign"   on candidate.officer_assignments;
drop policy if exists "compliance insert officer_assign" on candidate.officer_assignments;
create policy "compliance read officer_assign"   on candidate.officer_assignments
  for select to authenticated
  using (candidate.is_authorized_user() and candidate.is_compliance_officer());
create policy "compliance insert officer_assign" on candidate.officer_assignments
  for insert to authenticated
  with check (candidate.is_authorized_user() and candidate.is_compliance_officer());
-- (No UPDATE/DELETE policy: history is append-only; SECURITY DEFINER RPCs write.)

-- ── Helper: is a user an assignable compliance officer? ─────────────────────
-- Target must be staff carrying is_compliance OR is_admin. NULL (unassign) is
-- validated separately by the callers (allowed).
create or replace function candidate.is_compliance_staff(p_user uuid)
returns boolean language sql stable security definer
set search_path = candidate, public as $$
  select exists (
    select 1 from candidate.staff s
    where s.user_id = p_user and (s.is_compliance or s.is_admin)
  );
$$;
revoke all on function candidate.is_compliance_staff(uuid) from public;
grant execute on function candidate.is_compliance_staff(uuid) to authenticated;

-- ── assign_officer: single candidate, method 'manual' ───────────────────────
create or replace function candidate.assign_officer(p_candidate_id uuid,
                                                    p_officer      uuid,
                                                    p_reason       text default null)
returns void language plpgsql security definer
set search_path = candidate, public as $$
declare v_prev uuid;
begin
  if not (candidate.is_authorized_user() and candidate.is_compliance_officer()) then
    raise exception 'not authorized';
  end if;
  if p_officer is not null and not candidate.is_compliance_staff(p_officer) then
    raise exception 'target % is not a compliance officer (needs staff.is_compliance or is_admin)', p_officer;
  end if;

  select compliance_officer into v_prev
  from candidate.candidates where id = p_candidate_id;
  if not found then
    raise exception 'candidate % not found', p_candidate_id;
  end if;

  -- No-op if unchanged (no history row).
  if v_prev is not distinct from p_officer then
    return;
  end if;

  update candidate.candidates set compliance_officer = p_officer where id = p_candidate_id;

  insert into candidate.officer_assignments
    (candidate_id, officer, previous_officer, method, reason, assigned_by)
  values (p_candidate_id, p_officer, v_prev, 'manual', p_reason, auth.uid());
end;
$$;
revoke all on function candidate.assign_officer(uuid, uuid, text) from public;
grant execute on function candidate.assign_officer(uuid, uuid, text) to authenticated;

-- ── bulk_assign_officer: many candidates, method 'bulk' ─────────────────────
-- One data-modifying CTE captures each row's PREVIOUS officer (from the pre-
-- statement snapshot) before the update, so history is exact. Returns rows changed.
create or replace function candidate.bulk_assign_officer(p_ids    uuid[],
                                                         p_officer uuid,
                                                         p_reason  text default null)
returns int language plpgsql security definer
set search_path = candidate, public as $$
declare v_changed int;
begin
  if not (candidate.is_authorized_user() and candidate.is_compliance_officer()) then
    raise exception 'not authorized';
  end if;
  if p_officer is not null and not candidate.is_compliance_staff(p_officer) then
    raise exception 'target % is not a compliance officer (needs staff.is_compliance or is_admin)', p_officer;
  end if;

  with targets as (
    select c.id, c.compliance_officer as previous_officer
    from candidate.candidates c
    where c.id = any(p_ids)
      and c.compliance_officer is distinct from p_officer
  ),
  upd as (
    update candidate.candidates c
    set compliance_officer = p_officer
    from targets t where c.id = t.id
    returning c.id
  ),
  hist as (
    insert into candidate.officer_assignments
      (candidate_id, officer, previous_officer, method, reason, assigned_by)
    select t.id, p_officer, t.previous_officer, 'bulk', p_reason, auth.uid()
    from targets t
    returning 1
  )
  select count(*) into v_changed from hist;

  return coalesce(v_changed, 0);
end;
$$;
revoke all on function candidate.bulk_assign_officer(uuid[], uuid, text) from public;
grant execute on function candidate.bulk_assign_officer(uuid[], uuid, text) to authenticated, service_role;

-- ── auto_assign_officers_by_division: fill a division, method 'auto' ────────
-- Candidates -> disciplines(division_id). p_only_unassigned=true (default) skips
-- candidates that already have an officer; only rows whose officer actually
-- changes are touched (and logged).
create or replace function candidate.auto_assign_officers_by_division(
    p_division        uuid,
    p_officer         uuid,
    p_only_unassigned boolean default true,
    p_reason          text default null)
returns int language plpgsql security definer
set search_path = candidate, public as $$
declare v_changed int;
begin
  if not (candidate.is_authorized_user() and candidate.is_compliance_officer()) then
    raise exception 'not authorized';
  end if;
  if p_officer is not null and not candidate.is_compliance_staff(p_officer) then
    raise exception 'target % is not a compliance officer (needs staff.is_compliance or is_admin)', p_officer;
  end if;

  with targets as (
    select c.id, c.compliance_officer as previous_officer
    from candidate.candidates c
    join candidate.disciplines d on d.id = c.discipline_id
    where d.division_id = p_division
      and (not p_only_unassigned or c.compliance_officer is null)
      and c.compliance_officer is distinct from p_officer
  ),
  upd as (
    update candidate.candidates c
    set compliance_officer = p_officer
    from targets t where c.id = t.id
    returning c.id
  ),
  hist as (
    insert into candidate.officer_assignments
      (candidate_id, officer, previous_officer, method, reason, assigned_by)
    select t.id, p_officer, t.previous_officer, 'auto', p_reason, auth.uid()
    from targets t
    returning 1
  )
  select count(*) into v_changed from hist;

  return coalesce(v_changed, 0);
end;
$$;
revoke all on function candidate.auto_assign_officers_by_division(uuid, uuid, boolean, text) from public;
grant execute on function candidate.auto_assign_officers_by_division(uuid, uuid, boolean, text) to authenticated, service_role;

-- ── Extend the worklist with the officer column (create or replace from 33) ─
-- Keeps security_invoker + every 33 column (incl. the division cols); appends
-- compliance_officer at the end (create-or-replace requires the prefix intact).
create or replace view candidate.compliance_worklist
with (security_invoker = true) as
select
  s.candidate_id,
  s.set_id,
  s.status,
  s.blocking_open,
  s.needs_human_count,
  s.expiring_count,
  s.next_expiry,
  s.computed_at,
  crs.set_code,
  crs.set_version,
  c.first_name,
  c.last_name,
  c.email,
  c.phone,
  c.discipline_id,
  c.primary_specialty_id,
  c.desk_id,
  c.owner_user,
  d.code as discipline_code,
  d.name as discipline_name,
  exists (
    select 1 from candidate.compliance_items ci
    where ci.candidate_id = s.candidate_id and ci.migrated
  ) as has_migrated,
  d.division_id,
  dv.code as division_code,
  dv.name as division_name,
  c.compliance_officer
from candidate.candidate_compliance_status s
join candidate.candidate_requirement_sets crs
  on crs.candidate_id = s.candidate_id and crs.set_id = s.set_id and crs.active
join candidate.candidates c on c.id = s.candidate_id
left join candidate.disciplines d on d.id = c.discipline_id
left join candidate.divisions dv on dv.id = d.division_id;

grant select on candidate.compliance_worklist to authenticated;

-- ==== sql/35_overseeing_hierarchy.sql ====
-- ============================================================================
--  Day Webster — Candidate Pipeline · Overseeing-officer hierarchy
--  File: candidate-pipeline/sql/35_overseeing_hierarchy.sql
--  Run AFTER 18 (staff) and 34. Idempotent / additive.  STATUS: DRAFT — NOT YET APPLIED.
--
--  A senior/overseeing officer supervises a group of compliance officers. This
--  is a soft reporting line on `staff` (who oversees whom); it drives the
--  officer report's team roll-up, NOT row-level access (visibility stays open).
-- ============================================================================

alter table candidate.staff
  add column if not exists overseen_by uuid references auth.users(id) on delete set null;
create index if not exists staff_overseen_by_idx on candidate.staff (overseen_by);

-- Officers the current user oversees (their direct reports).
create or replace function candidate.my_reports()
returns setof uuid language sql stable security definer
set search_path = candidate, public as $$
  select s.user_id from candidate.staff s where s.overseen_by = auth.uid();
$$;
grant execute on function candidate.my_reports() to authenticated;

-- Does the current user oversee anyone?
create or replace function candidate.is_overseeing_officer()
returns boolean language sql stable security definer
set search_path = candidate, public as $$
  select exists (select 1 from candidate.staff s where s.overseen_by = auth.uid());
$$;
grant execute on function candidate.is_overseeing_officer() to authenticated;

-- ==== sql/36_compliance_reporting.sql ====
-- ============================================================================
--  Day Webster — Candidate Pipeline · Compliance reporting layer
--  File: candidate-pipeline/sql/36_compliance_reporting.sql
--  Run AFTER 33-35. Idempotent / additive.  STATUS: DRAFT — NOT YET APPLIED.
--
--  Roll-up reporting over the traffic lights:
--    · candidate_overall_status — ONE row per in-pipeline candidate, collapsing
--      their per-set lights into a single overall RAG (fail-closed).
--    · compliance_officer_report — candidate counts by officer × division ×
--      discipline × RAG, scoped to an overseer / officer / division.
--    · compliance_exec_overview  — division/discipline rollup: in-pipeline,
--      red, amber, green (green = ready-to-work).
--
--  Both RPCs are SECURITY DEFINER + gated is_compliance_officer(); they read the
--  security_invoker view under definer rights, so a compliance officer sees the
--  whole bench regardless of desk silo.
-- ============================================================================

-- ── One overall RAG per in-pipeline candidate (fail-closed) ─────────────────
-- INNER JOIN to active sets => only candidates actually in the pipeline. A set
-- with NO status row coalesces to 'red' (fail-closed). One row per candidate, so
-- a candidate is never double-counted no matter how many sets they hold.
create or replace view candidate.candidate_overall_status
with (security_invoker = true) as
select
  c.id                as candidate_id,
  c.compliance_officer,
  c.discipline_id,
  d.division_id,
  count(*)            as active_set_count,
  case
    when bool_or(coalesce(s.status, 'red') = 'red')   then 'red'
    when bool_or(coalesce(s.status, 'red') = 'amber') then 'amber'
    else 'green'
  end                 as overall_rag
from candidate.candidates c
join candidate.candidate_requirement_sets crs
  on crs.candidate_id = c.id and crs.active
left join candidate.candidate_compliance_status s
  on s.candidate_id = crs.candidate_id and s.set_id = crs.set_id
left join candidate.disciplines d on d.id = c.discipline_id
group by c.id, c.compliance_officer, c.discipline_id, d.division_id;

grant select on candidate.candidate_overall_status to authenticated;

-- ── Officer report: counts by officer × division × discipline × RAG ─────────
create or replace function candidate.compliance_officer_report(
    p_overseer uuid default null,
    p_officer  uuid default null,
    p_division uuid default null)
returns table(
    officer         uuid,
    officer_name    text,
    overseen_by     uuid,
    division_id     uuid,
    division_name   text,
    discipline_id   uuid,
    discipline_name text,
    overall_rag     text,
    candidate_count bigint)
language plpgsql stable security definer
set search_path = candidate, public as $$
begin
  if not (candidate.is_authorized_user() and candidate.is_compliance_officer()) then
    raise exception 'not authorized';
  end if;

  return query
    select
      os.compliance_officer,
      coalesce(st.full_name, au.email),
      st.overseen_by,
      os.division_id,
      dv.name,
      os.discipline_id,
      d.name,
      os.overall_rag,
      count(*)
    from candidate.candidate_overall_status os
    left join candidate.staff      st on st.user_id = os.compliance_officer
    left join candidate.app_users  au on au.user_id = os.compliance_officer
    left join candidate.divisions  dv on dv.id = os.division_id
    left join candidate.disciplines d on d.id = os.discipline_id
    where (p_officer  is null or os.compliance_officer = p_officer)
      and (p_division is null or os.division_id = p_division)
      -- Scope to an overseer's team; still surface UNASSIGNED candidates (no
      -- officer) so nothing falls through the cracks.
      and (p_overseer is null
           or st.overseen_by = p_overseer
           or os.compliance_officer is null)
    group by os.compliance_officer, coalesce(st.full_name, au.email), st.overseen_by,
             os.division_id, dv.name, os.discipline_id, d.name, os.overall_rag;
end;
$$;
revoke all on function candidate.compliance_officer_report(uuid, uuid, uuid) from public;
grant execute on function candidate.compliance_officer_report(uuid, uuid, uuid) to authenticated;

-- ── Exec overview: division/discipline rollup with RAG counters ─────────────
-- rollup over (division) then (division, discipline) — id+name grouped as a
-- single unit so the FD name never spawns a redundant subtotal level. NULLs in
-- division_id/discipline_id mark the subtotal / grand-total rows.
create or replace function candidate.compliance_exec_overview(p_division uuid default null)
returns table(
    division_id     uuid,
    division_name   text,
    discipline_id   uuid,
    discipline_name text,
    in_pipeline     bigint,
    red             bigint,
    amber           bigint,
    green           bigint,
    -- ROLLUP markers so a consumer can tell a subtotal/grand-total row apart
    -- from a genuine candidate that has NO division/discipline (both would
    -- otherwise show NULL ids). is_division_total=1 => grand total;
    -- is_discipline_total=1 (with is_division_total=0) => a division subtotal;
    -- both 0 => a real detail row (division/discipline may still be NULL).
    is_division_total   int,
    is_discipline_total int)
language plpgsql stable security definer
set search_path = candidate, public as $$
begin
  if not (candidate.is_authorized_user() and candidate.is_compliance_officer()) then
    raise exception 'not authorized';
  end if;

  return query
    select
      os.division_id,
      dv.name,
      os.discipline_id,
      d.name,
      count(*),
      count(*) filter (where os.overall_rag = 'red'),
      count(*) filter (where os.overall_rag = 'amber'),
      count(*) filter (where os.overall_rag = 'green'),  -- green = ready-to-work
      grouping(os.division_id),
      grouping(os.discipline_id)
    from candidate.candidate_overall_status os
    left join candidate.divisions   dv on dv.id = os.division_id
    left join candidate.disciplines d  on d.id = os.discipline_id
    where (p_division is null or os.division_id = p_division)
    group by rollup((os.division_id, dv.name), (os.discipline_id, d.name));
end;
$$;
revoke all on function candidate.compliance_exec_overview(uuid) from public;
grant execute on function candidate.compliance_exec_overview(uuid) to authenticated;

-- ==== sql/37_verification_providers.sql ====
-- ============================================================================
--  Day Webster — Candidate Pipeline · Compliance Phase 2: verification providers
--  File: candidate-pipeline/sql/37_verification_providers.sql
--  Run AFTER 10-36. Idempotent / additive.  STATUS: DRAFT — NOT YET APPLIED.
--
--  The provider/adapter layer that automates register / DBS / Right-to-Work
--  checks over the EXISTING compliance_items + verification_events spine (Phase 2
--  scoping §2). Three new tables + the deferred requirement columns:
--    · verification_providers — the source registry (NON-SECRET config only; a
--      `secret_ref` NAMES an env var, credentials never live here / client-side).
--    · provider_jobs          — the fail-closed queue + request/response audit,
--      with an in-flight UNIQUE guard for idempotency (a completed job is never
--      re-run; a re-check is a NEW row).
--    · verification_consent   — DBS/RTW are lawful only with candidate identifiers
--      + consent; the table exists now (capture UI is stubbed for the POC).
--  Plus the deferred `regulator`/`provider_key`/`verification_method` columns on
--  compliance_requirements + the LOAD-BEARING regulator_driven expiry fix so the
--  existing expiry sweep + amber window start working for registrations.
--
--  Invariants: provider_jobs has NO client write policy (service-role + SECURITY
--  DEFINER RPCs only, migration 38). verification_events / compliance_items are
--  unchanged. Every fail-closed guarantee from Phase 0/1 is preserved.
-- ============================================================================

-- ── 1. Provider registry ─────────────────────────────────────────────────────
-- kind: realtime_api  = a real-time official/aggregator API (e.g. HCPC)
--       bulk_facility = an official batched web facility (NMC/GMC confirmations)
--       aggregator    = a licensed data processor stitching facilities together
--       manual        = a human performs the check (DBS Update / RTW share code)
--       sim           = the POC simulation adapter (no network, deterministic)
-- config is NON-SECRET only. `secret_ref` names the Function/Vault env var that
-- holds the credential; the credential itself is NEVER stored in this table.
create table if not exists candidate.verification_providers (
  id                 uuid primary key default gen_random_uuid(),
  provider_key       text not null unique,
  name               text not null,
  kind               text not null
                     check (kind in ('realtime_api','bulk_facility','aggregator','manual','sim')),
  regulator          text,
  status             text not null default 'active'
                     check (status in ('active','paused','retired')),
  endpoint           text,
  config             jsonb not null default '{}'::jsonb,   -- non-secret; may hold {"secret_ref":"ENV_VAR"}
  rate_limit_per_min int  not null default 60,
  max_concurrency    int  not null default 2,
  recheck_months     int  not null default 12,             -- annual rolling cadence (per-provider)
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

drop trigger if exists verification_providers_set_updated_at on candidate.verification_providers;
create trigger verification_providers_set_updated_at
  before update on candidate.verification_providers
  for each row execute function candidate.set_updated_at();

-- ── 2. The job queue + request/response audit ────────────────────────────────
-- trigger: WHY this check ran.  status: queued→running→(succeeded|failed|
-- needs_human|cancelled). A completed job is terminal — a re-check is a new row.
create table if not exists candidate.provider_jobs (
  id               uuid primary key default gen_random_uuid(),
  provider_id      uuid references candidate.verification_providers(id) on delete set null,
  provider_key     text not null,                          -- denormalised for the claim query + partial index
  candidate_id     uuid not null references candidate.candidates(id) on delete cascade,
  requirement_id   uuid references candidate.compliance_requirements(id) on delete set null,
  item_id          uuid references candidate.compliance_items(id) on delete set null,
  requirement_code text,
  trigger          text not null
                   check (trigger in ('pre_placement','annual_recheck','pre_expiry','manual')),
  status           text not null default 'queued'
                   check (status in ('queued','running','succeeded','failed','needs_human','cancelled')),
  attempts         int  not null default 0,
  max_attempts     int  not null default 5,
  run_after        timestamptz not null default now(),
  locked_at        timestamptz,
  locked_by        text,
  request          jsonb,                                  -- frozen request (minimise PII — §2.6)
  response         jsonb,                                  -- raw provider payload (retention-purged in 39)
  outcome          text,                                   -- verified|expired|unsuitable|needs_human|not_found|error
  source_ref       text,                                   -- regulator/provider reference (audit)
  error            text,
  created_by       uuid references auth.users(id) on delete set null,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

drop trigger if exists provider_jobs_set_updated_at on candidate.provider_jobs;
create trigger provider_jobs_set_updated_at
  before update on candidate.provider_jobs
  for each row execute function candidate.set_updated_at();

-- The drain hot-path: pull queued, due jobs oldest-first.
create index if not exists provider_jobs_claim_idx
  on candidate.provider_jobs (status, run_after) where status = 'queued';
create index if not exists provider_jobs_candidate_idx
  on candidate.provider_jobs (candidate_id, requirement_id);
create index if not exists provider_jobs_provider_idx
  on candidate.provider_jobs (provider_key, status);
-- IDEMPOTENCY: at most one in-flight (queued OR running) job per candidate+
-- requirement, so a double "Verify now" / overlapping sweep can't double-enqueue.
create unique index if not exists provider_jobs_inflight_uniq
  on candidate.provider_jobs (candidate_id, requirement_id)
  where status in ('queued','running');

-- ── 3. DBS / RTW consent (stubbed capture for the POC) ───────────────────────
-- DBS Update Service + Right-to-Work checks transmit candidate identifiers to a
-- third party — lawful only with recorded consent. `identifier_ref` NAMES where
-- the identifier lives (e.g. an evidence ref), never the raw number here.
create table if not exists candidate.verification_consent (
  id             uuid primary key default gen_random_uuid(),
  candidate_id   uuid not null references candidate.candidates(id) on delete cascade,
  scope          text not null check (scope in ('dbs_update','rtw')),
  identifier_ref text,
  consented_at   timestamptz,
  via            text,                                     -- 'portal' | 'email' | 'signed_form' | ...
  captured_by    uuid references auth.users(id) on delete set null,
  revoked_at     timestamptz,
  created_at     timestamptz not null default now()
);
create index if not exists verification_consent_candidate_idx
  on candidate.verification_consent (candidate_id, scope);

-- ── 4. Requirement wiring (the deferred Phase-2 columns) ─────────────────────
-- verification_method: register_check (NMC/GMC/HCPC), dbs_update, rtw, idvt, human.
alter table candidate.compliance_requirements
  add column if not exists regulator           text,
  add column if not exists provider_key        text,
  add column if not exists verification_method text
    check (verification_method in ('register_check','dbs_update','rtw','idvt','human'));

-- Idempotent wiring by code (updates every discipline-scoped row of that code).
update candidate.compliance_requirements
  set regulator = 'NMC', provider_key = 'nmc', verification_method = 'register_check'
  where code = 'nmc_registration';
update candidate.compliance_requirements
  set regulator = 'GMC', provider_key = 'gmc', verification_method = 'register_check'
  where code = 'gmc_registration';
update candidate.compliance_requirements
  set regulator = 'HCPC', provider_key = 'hcpc', verification_method = 'register_check'
  where code = 'hcpc_registration';
update candidate.compliance_requirements
  set regulator = 'DBS', provider_key = 'dbs_update', verification_method = 'dbs_update'
  where code in ('dbs_enhanced','dbs_enhanced_adults','dbs_enhanced_children');
update candidate.compliance_requirements
  set regulator = 'RTW', provider_key = 'rtw_share_code', verification_method = 'rtw'
  where code = 'right_to_work';

-- LOAD-BEARING FIX: the register codes carried expiry_rule = null ("never
-- expires"), wrong for annual-renewal registers. regulator_driven means the
-- provider writes the regulator's own renewal date into expires_at, so the
-- existing expiry sweep (early-warnings) + the 30-day amber window start working
-- for registrations automatically — no gate logic changes.
update candidate.compliance_requirements
  set expiry_rule = '{"type":"regulator_driven"}'::jsonb
  where code in ('nmc_registration','gmc_registration','hcpc_registration')
    and expiry_rule is null;

-- ── 5. Seed the Phase 2a providers (idempotent) ──────────────────────────────
-- All active. secret_ref NAMES the env var each real adapter reads; the `sim`
-- provider needs no credential (POC demo). Real credentials live in Function env
-- / Supabase Vault — never in this table.
insert into candidate.verification_providers
  (provider_key, name, kind, regulator, status, endpoint, config, rate_limit_per_min, max_concurrency, recheck_months)
values
  ('nmc',            'NMC Employer Confirmations',   'bulk_facility', 'NMC',  'active',
     null, '{"secret_ref":"NMC_API_KEY"}'::jsonb,  30, 2, 12),
  ('gmc',            'GMC LRMP / register licence',  'bulk_facility', 'GMC',  'active',
     null, '{"secret_ref":"GMC_API_KEY"}'::jsonb,  30, 2, 12),
  ('hcpc',           'HCPC Employer Check API',      'realtime_api',  'HCPC', 'active',
     'https://api.hcpc-uk.org/employer-check', '{"secret_ref":"HCPC_API_KEY"}'::jsonb, 60, 4, 12),
  ('dbs_update',     'DBS Update Service',           'manual',        'DBS',  'active',
     null, '{"secret_ref":"DBS_API_KEY"}'::jsonb,  20, 1, 12),
  ('rtw_share_code', 'Right-to-Work share code',     'manual',        'RTW',  'active',
     null, '{"secret_ref":"RTW_API_KEY"}'::jsonb,  20, 1, 12),
  ('sim',            'Simulation (POC demo)',        'sim',           null,   'active',
     null, '{}'::jsonb, 600, 8, 12)
on conflict (provider_key) do nothing;

-- ── 6. RLS ───────────────────────────────────────────────────────────────────
alter table candidate.verification_providers enable row level security;
alter table candidate.provider_jobs          enable row level security;
alter table candidate.verification_consent   enable row level security;

-- Providers: compliance officers READ; admins WRITE (mirror 18_desks pattern).
drop policy if exists "compliance read providers" on candidate.verification_providers;
drop policy if exists "admin write providers"     on candidate.verification_providers;
create policy "compliance read providers" on candidate.verification_providers
  for select to authenticated
  using (candidate.is_authorized_user() and candidate.is_compliance_officer());
create policy "admin write providers" on candidate.verification_providers
  for all to authenticated
  using (candidate.is_authorized_user() and candidate.is_admin())
  with check (candidate.is_authorized_user() and candidate.is_admin());

-- provider_jobs: compliance officers READ only. NO insert/update/delete policy =>
-- the queue is writable ONLY by service_role (RLS-exempt) + the SECURITY DEFINER
-- RPCs in 38. A logged-in user can never forge or edit a job (fail-closed).
drop policy if exists "compliance read provider_jobs" on candidate.provider_jobs;
create policy "compliance read provider_jobs" on candidate.provider_jobs
  for select to authenticated
  using (candidate.is_authorized_user() and candidate.is_compliance_officer());

-- Consent: compliance officers READ + INSERT (capture). No update/delete: a
-- revocation is a new state set via a definer path / re-insert, keeping history.
drop policy if exists "compliance read consent"   on candidate.verification_consent;
drop policy if exists "compliance insert consent" on candidate.verification_consent;
create policy "compliance read consent" on candidate.verification_consent
  for select to authenticated
  using (candidate.is_authorized_user() and candidate.is_compliance_officer());
create policy "compliance insert consent" on candidate.verification_consent
  for insert to authenticated
  with check (candidate.is_authorized_user() and candidate.is_compliance_officer());

-- ── F7 audit hardening: make verification_events UN-FORGEABLE ────────────────
-- Migration 22 granted compliance officers a direct client INSERT on the audit
-- spine, so an officer could forge a 'service'/'verified' event via PostgREST.
-- Every LEGITIMATE write already goes through a SECURITY DEFINER RPC (decide_item,
-- import_compliance_bulk, enqueue_verification, apply_verification_result,
-- fail_provider_job, enqueue_due_rechecks) — all run as owner and BYPASS RLS, so
-- they do not need this policy. Forward-drop it (we never edit applied 22) so the
-- append-only audit trail can ONLY be written by the definer RPCs. Reads are
-- unchanged (the "compliance read events" SELECT policy remains).
drop policy if exists "compliance insert events" on candidate.verification_events;

-- ==== sql/38_verification_rpcs.sql ====
-- ============================================================================
--  Day Webster — Candidate Pipeline · Compliance Phase 2: verification RPCs
--  File: candidate-pipeline/sql/38_verification_rpcs.sql
--  Run AFTER 37. Idempotent / additive.  STATUS: DRAFT — NOT YET APPLIED.
--
--  The fail-closed control surface for the provider/adapter layer. EVERY function
--  is SECURITY DEFINER + `set search_path = candidate, public`, revokes public,
--  and reaches the queue ONLY through here (provider_jobs has no client write
--  policy). There is NO code path from a provider error → `verified`.
--
--    · enqueue_verification      — officer/service: queue a check (idempotent).
--    · claim_provider_jobs       — service: FOR UPDATE SKIP LOCKED batch claim.
--    · apply_verification_result — service: map outcome→item + ONE audit event.
--    · fail_provider_job         — service: retry w/ backoff, else needs_human.
--    · enqueue_due_rechecks      — service: daily set-based re-check sweep.
--    · verification_counts       — officer: the dashboard tile.
--    · verification_history      — a read-only, actor-resolved audit view.
--
--  Audit: a human "Verify now" appends a request event NAMING the officer
--  (actor = auth.uid()), then apply_verification_result appends the result event
--  (actor_kind='service') — a complete, attributable, immutable request→result
--  pair. verification_events keeps NO update/delete policy (append-only).
-- ============================================================================

-- ── Role helper: is this call the service_role (edge function / cron)? ───────
-- Reads the JWT role claim. In the test harness auth.jwt() has no role => false;
-- set test.jwt = '{"role":"service_role"}' to exercise the service path.
create or replace function candidate.is_service_role()
returns boolean language sql stable
set search_path = candidate, public as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    auth.jwt()->>'role'
  ) = 'service_role';
$$;
revoke all on function candidate.is_service_role() from public;
grant execute on function candidate.is_service_role() to authenticated, service_role;

-- ── enqueue_verification: queue a check for one candidate+requirement ────────
-- Officer- or service-gated. Idempotent: the in-flight UNIQUE index collapses a
-- double click / overlapping sweep to the SAME job. Sets the item 'verifying'
-- ONLY IF NOT already 'verified' (an annual re-check must not drop a valid
-- registration to red mid-flight). Appends an attributable recheck_requested
-- event (human => actor = the acting officer; service => actor null).
create or replace function candidate.enqueue_verification(p_candidate_id       uuid,
                                                          p_requirement_code   text,
                                                          p_trigger            text default 'manual')
returns uuid language plpgsql security definer
set search_path = candidate, public as $$
declare
  v_is_service boolean := candidate.is_service_role();
  v_actor      uuid    := case when v_is_service then null else auth.uid() end;
  v_actor_kind text    := case when v_is_service then 'service' else 'human' end;
  v_req        record;
  v_provider   record;
  v_item_id    uuid;
  v_item_status text;
  v_job_id     uuid;
begin
  if not (candidate.is_compliance_officer() or v_is_service) then
    raise exception 'not authorized';
  end if;
  if p_trigger not in ('pre_placement','annual_recheck','pre_expiry','manual') then
    raise exception 'unknown trigger: %', p_trigger;
  end if;

  -- Resolve the requirement WITHIN the candidate's active set(s) (exact scope).
  select cr.id, cr.code, cr.provider_key, cr.verification_method
    into v_req
  from candidate.candidate_requirement_sets crs
  join candidate.requirement_set_items rsi on rsi.set_id = crs.set_id
  join candidate.compliance_requirements cr on cr.id = rsi.requirement_id
  where crs.candidate_id = p_candidate_id and crs.active and cr.code = p_requirement_code
  order by cr.discipline_id nulls last
  limit 1;
  if not found then
    raise exception 'requirement % is not in an active set for candidate %', p_requirement_code, p_candidate_id;
  end if;
  if v_req.provider_key is null then
    raise exception 'requirement % has no verification provider (not automatable)', p_requirement_code;
  end if;

  -- Resolve the provider; must exist and be active (not paused/retired).
  select id, provider_key, status into v_provider
  from candidate.verification_providers where provider_key = v_req.provider_key;
  if not found then
    raise exception 'no verification provider registered for %', v_req.provider_key;
  end if;
  if v_provider.status <> 'active' then
    raise exception 'verification provider % is % (not active)', v_provider.provider_key, v_provider.status;
  end if;

  -- Ensure a compliance_item exists to attach the result to (prefer verified).
  select id, status into v_item_id, v_item_status
  from candidate.compliance_items
  where candidate_id = p_candidate_id and requirement_id = v_req.id
  order by (status = 'verified') desc, updated_at desc
  limit 1;
  if v_item_id is null then
    insert into candidate.compliance_items (candidate_id, requirement_id, status)
    values (p_candidate_id, v_req.id, 'not_started')
    returning id, status into v_item_id, v_item_status;
  end if;

  -- Set 'verifying' ONLY IF NOT already verified (don't drop a valid reg to red).
  if v_item_status is distinct from 'verified' then
    update candidate.compliance_items
      set status = 'verifying', updated_at = now()
      where id = v_item_id and status is distinct from 'verified';
  end if;

  -- Enqueue. IDEMPOTENT: the in-flight partial-unique index makes a concurrent
  -- duplicate a no-op; we then return the EXISTING in-flight job id.
  insert into candidate.provider_jobs
    (provider_id, provider_key, candidate_id, requirement_id, item_id,
     requirement_code, trigger, status, request, created_by)
  values
    (v_provider.id, v_provider.provider_key, p_candidate_id, v_req.id, v_item_id,
     v_req.code, p_trigger, 'queued',
     jsonb_build_object('code', v_req.code, 'method', v_req.verification_method,
                        'trigger', p_trigger),
     v_actor)
  on conflict (candidate_id, requirement_id) where status in ('queued','running')
  do nothing
  returning id into v_job_id;

  if v_job_id is null then
    -- A check is already in flight: return it (idempotent), no second event.
    select id into v_job_id
    from candidate.provider_jobs
    where candidate_id = p_candidate_id and requirement_id = v_req.id
      and status in ('queued','running')
    order by created_at desc
    limit 1;
    return v_job_id;
  end if;

  -- Attributable request event: NAMES the officer on a human "Verify now".
  insert into candidate.verification_events
    (candidate_id, item_id, requirement_id, event_type, method,
     source_ref, notes, actor, actor_kind)
  values
    (p_candidate_id, v_item_id, v_req.id, 'recheck_requested',
     coalesce(v_req.verification_method, 'system'),
     v_job_id::text,
     format('verification queued via %s (trigger=%s)', v_provider.provider_key, p_trigger),
     v_actor, v_actor_kind);

  return v_job_id;
end;
$$;
revoke all on function candidate.enqueue_verification(uuid, text, text) from public;
grant execute on function candidate.enqueue_verification(uuid, text, text) to authenticated, service_role;

-- ── claim_provider_jobs: safe parallel batch claim (service only) ────────────
-- FOR UPDATE SKIP LOCKED + the per-provider limit => never double-processes a
-- job, never hammers a facility. Returns each claimed job joined to its (non-
-- secret) provider config so the adapter knows the kind/endpoint/secret_ref.
create or replace function candidate.claim_provider_jobs(p_worker       text,
                                                         p_provider_key text,
                                                         p_limit        int default 10)
returns table(
  job_id          uuid,
  candidate_id    uuid,
  requirement_id  uuid,
  item_id         uuid,
  requirement_code text,
  trigger         text,
  attempts        int,
  max_attempts    int,
  provider_key    text,
  provider_kind   text,
  regulator       text,
  endpoint        text,
  config          jsonb)
language plpgsql security definer
set search_path = candidate, public as $$
begin
  return query
  with claimed as (
    update candidate.provider_jobs j
    set status = 'running', locked_at = now(), locked_by = p_worker,
        attempts = j.attempts + 1, updated_at = now()
    where j.id in (
      select c.id from candidate.provider_jobs c
      where c.status = 'queued'
        and c.run_after <= now()
        and c.provider_key = p_provider_key
      order by c.run_after
      limit greatest(coalesce(p_limit, 10), 0)
      for update skip locked
    )
    returning j.*
  )
  select c.id, c.candidate_id, c.requirement_id, c.item_id, c.requirement_code,
         c.trigger, c.attempts, c.max_attempts, c.provider_key,
         p.kind, p.regulator, p.endpoint, p.config
  from claimed c
  left join candidate.verification_providers p on p.id = c.provider_id;
end;
$$;
revoke all on function candidate.claim_provider_jobs(text, text, int) from public;
grant execute on function candidate.claim_provider_jobs(text, text, int) to service_role;

-- ── apply_verification_result: write the outcome through the gate (service) ──
-- Guards job.status='running' (a duplicate callback is a no-op). Maps outcome→
-- item status: ONLY 'verified' outcome ever sets 'verified'. Sets the regulator
-- expiry, appends ONE immutable result event (actor_kind='service'), and updates
-- the job. The existing compliance_items trigger recomputes the gate.
create or replace function candidate.apply_verification_result(
    p_job_id              uuid,
    p_outcome             text,
    p_expires_at          timestamptz default null,
    p_source_ref          text        default null,
    p_registration_number text        default null,
    p_response            jsonb       default null,
    p_notes               text        default null)
returns void language plpgsql security definer
set search_path = candidate, public as $$
declare
  v_job         candidate.provider_jobs;
  v_method      text;
  v_outcome     text;                                     -- effective outcome after data-quality guard
  v_item_status text;
  v_needs_human boolean;
  v_event       text;
  v_job_status  text;
  v_dq          boolean := false;                         -- register_check verified w/ no renewal date
  v_note        text;
begin
  select * into v_job from candidate.provider_jobs where id = p_job_id for update;
  if not found then
    raise exception 'provider job % not found', p_job_id;
  end if;
  -- Duplicate / late callback for an already-finalised job: no-op (idempotent).
  if v_job.status <> 'running' then
    return;
  end if;

  select verification_method into v_method
  from candidate.compliance_requirements where id = v_job.requirement_id;

  -- F6 fail-closed data-quality guard: a register-check 'verified' with NO
  -- renewal date must NOT become a never-expiring green (a regulator-driven
  -- registration always carries a renewal date). Downgrade to needs_human so a
  -- human reconciles it, rather than crediting an open-ended pass.
  v_outcome := p_outcome;
  if p_outcome = 'verified' and v_method = 'register_check' and p_expires_at is null then
    v_outcome := 'needs_human';
    v_dq := true;
  end if;

  -- Outcome → item status (fail-closed: only 'verified' credits the gate).
  v_item_status := case v_outcome
                     when 'verified'    then 'verified'
                     when 'expired'     then 'expired'
                     when 'unsuitable'  then 'unsuitable'
                     else null end;                       -- needs_human/other: leave status
  v_needs_human := (v_outcome <> 'verified');
  v_event       := case v_outcome
                     when 'verified'   then 'verified'
                     when 'expired'    then 'expired'
                     when 'unsuitable' then 'unsuitable'
                     else 'status_recomputed' end;        -- needs_human/other: a check ran, human review
  v_job_status  := case when v_outcome in ('verified','expired','unsuitable')
                        then 'succeeded' else 'needs_human' end;
  v_note := coalesce(p_notes,
              case when v_dq then 'register check returned verified but NO renewal date — routed to human review'
                   else format('provider outcome: %s', p_outcome) end);

  if v_job.item_id is not null then
    update candidate.compliance_items ci
    set status            = coalesce(v_item_status, ci.status),  -- leave status for needs_human
        expires_at        = case when p_expires_at is not null then p_expires_at else ci.expires_at end,
        -- F4: label the channel by the verification method (register_check /
        -- dbs_update / rtw / …), not a hardcoded value, so DBS/RTW aren't mislabelled.
        channel           = coalesce(v_method, 'register_check'),
        source_confidence = case when v_outcome = 'verified' then 'high' else ci.source_confidence end,
        received_at       = now(),
        needs_human       = v_needs_human,
        migrated          = case when v_outcome = 'verified' then false else ci.migrated end,
        extracted         = coalesce(ci.extracted, '{}'::jsonb) || jsonb_strip_nulls(jsonb_build_object(
                              'registration_number', p_registration_number,
                              'source_ref',          p_source_ref,
                              'provider_outcome',    p_outcome,               -- raw adapter outcome
                              'applied_outcome',     v_outcome,               -- after the data-quality guard
                              'missing_expiry',      nullif(v_dq, false),
                              'provider_key',        v_job.provider_key,
                              'checked_at',          now())),
        updated_at        = now()
    where ci.id = v_job.item_id;
  end if;

  -- ONE immutable result event (actor_kind='service'). Completes the audit pair.
  insert into candidate.verification_events
    (candidate_id, item_id, requirement_id, event_type, new_status, method,
     source_ref, notes, actor, actor_kind)
  values
    (v_job.candidate_id, v_job.item_id, v_job.requirement_id, v_event, v_item_status,
     coalesce(v_method, 'system'), p_source_ref, v_note, null, 'service');

  update candidate.provider_jobs
  set status = v_job_status, outcome = v_outcome, source_ref = p_source_ref,
      response = coalesce(p_response, response),
      locked_at = null, locked_by = null, updated_at = now()
  where id = p_job_id;
end;
$$;
revoke all on function candidate.apply_verification_result(uuid, text, timestamptz, text, text, jsonb, text) from public;
grant execute on function candidate.apply_verification_result(uuid, text, timestamptz, text, text, jsonb, text) to service_role;

-- ── fail_provider_job: retry with backoff, else degrade to human (service) ───
-- Retryable + attempts left => requeue with exponential backoff. Otherwise the
-- job is 'failed' and the item is flagged needs_human — a provider outage NEVER
-- becomes a pass (no path from error → verified).
create or replace function candidate.fail_provider_job(p_job_id    uuid,
                                                       p_error     text,
                                                       p_retryable boolean default true,
                                                       p_response  jsonb   default null)
returns void language plpgsql security definer
set search_path = candidate, public as $$
declare
  v_job     candidate.provider_jobs;
  v_backoff interval;
begin
  select * into v_job from candidate.provider_jobs where id = p_job_id for update;
  if not found then
    raise exception 'provider job % not found', p_job_id;
  end if;
  if v_job.status <> 'running' then
    return;                                                -- idempotent no-op
  end if;

  if p_retryable and v_job.attempts < v_job.max_attempts then
    -- Exponential backoff: ~2^attempts minutes, capped.
    v_backoff := least(make_interval(mins => power(2, v_job.attempts)::int), interval '6 hours');
    update candidate.provider_jobs
    set status = 'queued', run_after = now() + v_backoff, error = p_error,
        response = coalesce(p_response, response),
        locked_at = null, locked_by = null, updated_at = now()
    where id = p_job_id;
    return;
  end if;

  -- Terminal failure: degrade to human review, never to a pass.
  update candidate.provider_jobs
  set status = 'failed', error = p_error, outcome = 'error',
      response = coalesce(p_response, response),
      locked_at = null, locked_by = null, updated_at = now()
  where id = p_job_id;

  if v_job.item_id is not null then
    update candidate.compliance_items
    set needs_human = true, updated_at = now()
    where id = v_job.item_id;
  end if;

  -- Attributable audit row for the terminal failure (append-only).
  insert into candidate.verification_events
    (candidate_id, item_id, requirement_id, event_type, method, source_ref, notes, actor, actor_kind)
  values
    (v_job.candidate_id, v_job.item_id, v_job.requirement_id, 'status_recomputed',
     'system', p_job_id::text,
     format('provider check failed (%s) — routed to human review', left(coalesce(p_error,'error'), 240)),
     null, 'service');
end;
$$;
revoke all on function candidate.fail_provider_job(uuid, text, boolean, jsonb) from public;
grant execute on function candidate.fail_provider_job(uuid, text, boolean, jsonb) to service_role;

-- ── enqueue_due_rechecks: the daily set-based re-check sweep (service) ───────
-- Enqueues register/dbs/rtw items on active sets whose provider is active and
-- that are DUE — nearing/at expiry OR last verified beyond the provider's
-- recheck_months — and that have no in-flight job. run_after is rate-spread per
-- provider (row_number × the provider's per-request spacing). Returns the count.
create or replace function candidate.enqueue_due_rechecks(p_limit int default 500)
returns int language plpgsql security definer
set search_path = candidate, public as $$
declare
  v_lead interval := interval '30 days';   -- pre-expiry lead window
  v_count int;
begin
  with due as (
    select distinct on (ci.id)
      ci.id            as item_id,
      ci.candidate_id,
      ci.requirement_id,
      cr.code          as requirement_code,
      cr.provider_key,
      vp.id            as provider_id,
      vp.rate_limit_per_min,
      case when ci.expires_at is not null and ci.expires_at <= now() + v_lead
           then 'pre_expiry' else 'annual_recheck' end as trigger
    from candidate.compliance_items ci
    join candidate.candidate_requirement_sets crs
      on crs.candidate_id = ci.candidate_id and crs.active
    join candidate.requirement_set_items rsi
      on rsi.set_id = crs.set_id and rsi.requirement_id = ci.requirement_id
    join candidate.compliance_requirements cr on cr.id = ci.requirement_id
    join candidate.verification_providers vp
      on vp.provider_key = cr.provider_key and vp.status = 'active'
    where cr.provider_key is not null
      and cr.verification_method in ('register_check','dbs_update','rtw')
      and ci.status in ('verified','expired')
      -- DUE: nearing/at expiry OR the last successful check is older than cadence.
      and (
        (ci.expires_at is not null and ci.expires_at <= now() + v_lead)
        or coalesce(
             (select max(ve.occurred_at) from candidate.verification_events ve
               where ve.candidate_id = ci.candidate_id
                 and ve.requirement_id = ci.requirement_id
                 and ve.event_type = 'verified'),
             ci.received_at)
           < now() - make_interval(months => vp.recheck_months)
      )
      -- No in-flight job for this candidate+requirement.
      and not exists (
        select 1 from candidate.provider_jobs pj
        where pj.candidate_id = ci.candidate_id
          and pj.requirement_id = ci.requirement_id
          and pj.status in ('queued','running')
      )
    order by ci.id, ci.expires_at nulls last
  ),
  ranked as (
    select d.*,
           row_number() over (partition by d.provider_key order by d.item_id) as rn
    from due d
    limit greatest(coalesce(p_limit, 500), 0)
  ),
  ins as (
    insert into candidate.provider_jobs
      (provider_id, provider_key, candidate_id, requirement_id, item_id,
       requirement_code, trigger, status, run_after, request)
    select r.provider_id, r.provider_key, r.candidate_id, r.requirement_id, r.item_id,
           r.requirement_code, r.trigger, 'queued',
           -- rate-spread: space requests by 60/rate_limit seconds within a provider.
           now() + ((r.rn - 1) * make_interval(secs => 60.0 / greatest(r.rate_limit_per_min, 1))),
           jsonb_build_object('code', r.requirement_code, 'trigger', r.trigger, 'sweep', true)
    from ranked r
    on conflict (candidate_id, requirement_id) where status in ('queued','running')
    do nothing
    returning id, candidate_id, item_id, requirement_id, provider_key
  ),
  ev as (
    insert into candidate.verification_events
      (candidate_id, item_id, requirement_id, event_type, method, source_ref, notes, actor, actor_kind)
    select i.candidate_id, i.item_id, i.requirement_id, 'recheck_requested',
           coalesce((select verification_method from candidate.compliance_requirements cr where cr.id = i.requirement_id), 'system'),
           i.id::text, 'annual/expiry re-check sweep', null, 'service'
    from ins i
    returning 1
  )
  select count(*) into v_count from ins;

  return coalesce(v_count, 0);
end;
$$;
revoke all on function candidate.enqueue_due_rechecks(int) from public;
grant execute on function candidate.enqueue_due_rechecks(int) to service_role;

-- ── verification_counts: the dashboard "Register checks" tile (officer) ──────
create or replace function candidate.verification_counts()
returns jsonb language plpgsql stable security definer
set search_path = candidate, public as $$
declare v jsonb;
begin
  if not (candidate.is_authorized_user() and candidate.is_compliance_officer()) then
    raise exception 'not authorized';
  end if;

  select jsonb_build_object(
    'queued',           count(*) filter (where status = 'queued'),
    'running',          count(*) filter (where status = 'running'),
    'failed',           count(*) filter (where status = 'failed'),
    'needs_human',      count(*) filter (where status = 'needs_human'),
    'auto_verified_24h', count(*) filter (where outcome = 'verified' and status = 'succeeded'
                                             and updated_at >= now() - interval '24 hours')
  ) into v
  from candidate.provider_jobs;

  return coalesce(v, '{}'::jsonb);
end;
$$;
revoke all on function candidate.verification_counts() from public;
grant execute on function candidate.verification_counts() to authenticated;

-- ── verification_history: actor-resolved, read-only audit view ───────────────
-- security_invoker => the underlying verification_events RLS (compliance read)
-- applies. Resolves the acting officer's uid → staff name / login email so the
-- audit pack (and the UI pill) can show WHO ran each check. Append-only is
-- preserved: this is a SELECT-only view over the immutable spine.
create or replace view candidate.verification_history
with (security_invoker = true) as
select
  ve.id,
  ve.candidate_id,
  ve.item_id,
  ve.requirement_id,
  cr.code           as requirement_code,
  cr.name           as requirement_name,
  ve.event_type,
  ve.method,
  ve.old_status,
  ve.new_status,
  ve.source_ref,
  ve.notes,
  ve.actor,
  ve.actor_kind,
  coalesce(st.full_name, au.email) as actor_name,
  au.email          as actor_email,
  ve.occurred_at
from candidate.verification_events ve
left join candidate.compliance_requirements cr on cr.id = ve.requirement_id
left join candidate.staff     st on st.user_id = ve.actor
left join candidate.app_users au on au.user_id = ve.actor;

grant select on candidate.verification_history to authenticated;

-- ==== sql/39_verification_schedule.sql ====
-- ============================================================================
--  Day Webster — Candidate Pipeline · Compliance Phase 2: verification schedule
--  File: candidate-pipeline/sql/39_verification_schedule.sql
--  Run AFTER 38. Idempotent / additive.  STATUS: DRAFT — NOT YET APPLIED.
--
--  Two pg_cron jobs that drive the queue via the `verification` edge function
--  (extends the early-warnings cron pattern), plus a raw-response retention
--  purge (§2.6 data-protection):
--    · verification-drain  — every 10 min: process queued jobs (mode=drain).
--    · verification-sweep  — daily: top up annual/expiry re-checks (mode=sweep)
--                            and purge stale raw provider responses.
--
--  The net.http_post call is COMMENTED with a <FUNCTIONS_BASE_URL> placeholder
--  (same convention as DEPLOY.md §5) — set the two GUCs below (or edit the command)
--  before relying on it. The whole block is guarded on pg_cron being installed, so
--  this migration still applies clean on a vanilla Postgres (it just NOTICEs).
-- ============================================================================

-- ── Retention purge: null out stale raw provider payloads ────────────────────
-- provider_jobs.response can hold third-party PII (§2.6). Once a job is finalised
-- and older than the retention window, drop the raw payload but KEEP the audit
-- skeleton (status/outcome/source_ref + the immutable verification_events). The
-- append-only audit spine is untouched — only the transient raw body is cleared.
create or replace function candidate.purge_provider_job_responses(p_days int default 90)
returns int language plpgsql security definer
set search_path = candidate, public as $$
declare v_count int;
begin
  with purged as (
    update candidate.provider_jobs
    set response = null,
        request  = null
    where status in ('succeeded','failed','needs_human','cancelled')
      and response is not null
      and updated_at < now() - make_interval(days => greatest(coalesce(p_days, 90), 1))
    returning 1
  )
  select count(*) into v_count from purged;
  return coalesce(v_count, 0);
end;
$$;
revoke all on function candidate.purge_provider_job_responses(int) from public;
grant execute on function candidate.purge_provider_job_responses(int) to service_role;

-- ── pg_cron schedules (guarded — apply-safe without the extension) ───────────
-- Configure once (per project) so the commands resolve:
--   alter database postgres set app.functions_base_url = 'https://<ref>.functions.supabase.co';
--   alter database postgres set app.cron_secret        = '<CRON_SECRET>';
-- (Coalesced to visible <PLACEHOLDER> tokens if unset, so an unconfigured job
--  is obviously-broken rather than silently pointing somewhere wrong.)
do $$
declare
  v_base   text := coalesce(current_setting('app.functions_base_url', true), '<FUNCTIONS_BASE_URL>');
  v_secret text := coalesce(current_setting('app.cron_secret', true), '<CRON_SECRET>');
  v_drain  text;
  v_sweep  text;
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice 'pg_cron not installed — skipping verification-drain / verification-sweep. Schedule them in the Supabase dashboard or after `create extension pg_cron;` (see DEPLOY.md §5).';
    return;
  end if;

  -- Mirror DEPLOY.md §5: net.http_post to the function with ?mode=&secret=.
  v_drain := format(
    $cmd$select net.http_post(url := '%s/verification?mode=drain&secret=%s', headers := '{"Content-Type":"application/json"}'::jsonb)$cmd$,
    v_base, v_secret);
  v_sweep := format(
    $cmd$select net.http_post(url := '%s/verification?mode=sweep&secret=%s', headers := '{"Content-Type":"application/json"}'::jsonb)$cmd$,
    v_base, v_secret);

  -- Idempotent: drop any prior job of the same name, then (re)schedule.
  perform cron.unschedule(jobid) from cron.job
    where jobname in ('verification-drain','verification-sweep');

  perform cron.schedule('verification-drain', '*/10 * * * *', v_drain);
  perform cron.schedule('verification-sweep', '30 6 * * *',   v_sweep);
  raise notice 'scheduled verification-drain (*/10) + verification-sweep (daily 06:30).';
end $$;

-- Note: the daily sweep (mode=sweep) in functions/verification calls
-- enqueue_due_rechecks() and MAY also call purge_provider_job_responses() to
-- enforce retention. To run the purge purely in-DB instead, add a third cron:
--   select cron.schedule('verification-purge','0 3 * * *',
--     $$ select candidate.purge_provider_job_responses(90) $$);

-- ==== sql/40_shift_compliance_gate.sql ====
-- ============================================================================
--  Day Webster — Candidate Pipeline · Shift-date work-ready gate + buffer + override
--  File: candidate-pipeline/sql/40_shift_compliance_gate.sql
--  Run AFTER 22–25 (needs the sets/items/status spine + verification_events).
--  Idempotent / additive.  STATUS: DRAFT — NOT YET APPLIED.
--
--  [DECISION E2/E3] Booking must confirm the candidate is compliant FOR THE
--  SHIFT DATE (not just today), with a small configurable BUFFER (no bookings
--  within N days of an expiry, default 3), plus a manager OVERRIDE that is
--  audited, reasoned, time-bounded and VISIBLE. Hard cut-off at expiry — the
--  override is the only exception.
--
--  Adds:
--    · compliance_settings          — single-row config (booking_buffer_days)
--    · booking_buffer_days()        — read the configured buffer (default 3)
--    · work_ready_status_on()       — red/amber/green evaluated AS-OF a date+buffer
--    · is_work_ready_on()           — the shift-date gate (override-aware)
--    · has_active_override()        — does a live override cover (candidate,set,date)
--    · compliance_overrides         — sensitive; READ = officer, NO client writes
--    · grant/revoke_compliance_override() — officer-gated, reasoned, audited RPCs
--
--  FAIL-CLOSED like is_work_ready(): no active assignment / no data => 'red'.
--  The override NEVER auto-verifies items — the underlying items stay red so the
--  audit shows the true state PLUS the override; it only PERMITS booking.
-- ============================================================================

-- ── Config: a single-row settings table + a configurable booking buffer ─────
-- Singleton enforced by a boolean PK pinned to true. Buffer is configurable;
-- an admin can UPDATE the one row. Default 3 days.
create table if not exists candidate.compliance_settings (
  id                  boolean primary key default true check (id),
  booking_buffer_days int not null default 3 check (booking_buffer_days >= 0),
  updated_at          timestamptz not null default now(),
  updated_by          uuid references auth.users(id) on delete set null
);
insert into candidate.compliance_settings (id) values (true) on conflict (id) do nothing;

create or replace function candidate.booking_buffer_days()
returns int language sql stable security definer
set search_path = candidate, public as $$
  select coalesce((select booking_buffer_days from candidate.compliance_settings where id = true), 3);
$$;
revoke all on function candidate.booking_buffer_days() from public;
grant execute on function candidate.booking_buffer_days() to authenticated, service_role;

-- ── Manager OVERRIDE table (sensitive) — defined early so the SQL-language ──
-- readiness helpers below can reference it. Writes go ONLY through the RPCs.
create table if not exists candidate.compliance_overrides (
  id            uuid primary key default gen_random_uuid(),
  candidate_id  uuid not null references candidate.candidates(id) on delete cascade,
  set_id        uuid references candidate.requirement_sets(id) on delete cascade, -- null = ALL sets
  reason        text not null check (length(btrim(reason)) > 0),
  granted_by    uuid references auth.users(id) on delete set null,
  granted_at    timestamptz not null default now(),
  valid_from    date not null default current_date,
  valid_until   date not null,
  revoked_at    timestamptz,
  revoked_by    uuid references auth.users(id) on delete set null,
  revoke_reason text,
  check (valid_until >= valid_from)
);
create index if not exists compliance_overrides_candidate_idx
  on candidate.compliance_overrides (candidate_id);
create index if not exists compliance_overrides_live_idx
  on candidate.compliance_overrides (candidate_id, set_id, valid_until)
  where revoked_at is null;

-- Extend the append-only audit vocabulary with a legible override lifecycle pair
-- so an auditor can trace grants/revokes by event_type (not just free-text notes).
-- Drop-then-add keeps this idempotent; the new list is a strict superset so no
-- existing verification_events row is invalidated.
alter table candidate.verification_events
  drop constraint if exists verification_events_event_type_check;
alter table candidate.verification_events
  add constraint verification_events_event_type_check
  check (event_type in ('verified','rejected','unsuitable','expired','waived',
         'reinstated','evidence_received','recheck_requested','status_recomputed',
         'override_granted','override_revoked'));

-- ── AS-OF traffic light: red/amber/green for a shift DATE (+buffer) ──────────
-- Mirrors recompute_candidate_status()'s red/amber/green logic (waived handling
-- included), but evaluated against a CUT-OFF = p_as_of + buffer instead of now().
-- A blocking/standard REQUIRED item counts satisfied only if it is 'verified'
-- (or 'waived') AND (expires_at is null OR expires_at > cut-off). FAIL-CLOSED:
-- a candidate not ACTIVELY holding the set => 'red'.
create or replace function candidate.work_ready_status_on(
  p_candidate_id uuid, p_set_id uuid, p_as_of date, p_buffer_days int default null)
returns text language plpgsql stable security definer
set search_path = candidate, public as $$
declare
  v_buffer        int := greatest(coalesce(p_buffer_days, candidate.booking_buffer_days()), 0);
  v_cut           timestamptz;
  v_blocking_open int;
  v_standard_open int;
  v_waived_block  int;
  v_expiring      int;
  v_has_set       boolean;
begin
  -- Fail-closed: the candidate must actively hold this set to be evaluated.
  select exists (
    select 1 from candidate.candidate_requirement_sets crs
    where crs.candidate_id = p_candidate_id and crs.set_id = p_set_id and crs.active
  ) into v_has_set;
  if not v_has_set then
    return 'red';
  end if;

  -- Cut-off = the shift date + buffer, but NEVER earlier than now(): a same-day
  -- (or past) evaluation with a small/zero buffer must not treat a document that
  -- already lapsed *today* as still valid (that would book past a same-day expiry
  -- with no override — the LOCKED hard cut-off). Clamping to now() makes an
  -- as-of=today check identical to recompute_candidate_status()'s now() compare,
  -- and leaves genuinely future cut-offs (future shift, or today+buffer) untouched.
  v_cut := greatest(now(), (p_as_of + make_interval(days => v_buffer))::timestamptz);

  with reqs as (
    select rsi.requirement_id,
           coalesce(rsi.criticality, cr.criticality)   as criticality,
           coalesce(rsi.required_override, cr.required) as required
    from candidate.requirement_set_items rsi
    join candidate.compliance_requirements cr on cr.id = rsi.requirement_id
    where rsi.set_id = p_set_id
  ),
  item_state as (
    select r.requirement_id, r.criticality, r.required, ci.status, ci.expires_at
    from reqs r
    left join lateral (
      select ci.status, ci.expires_at
      from candidate.compliance_items ci
      where ci.candidate_id = p_candidate_id
        and ci.requirement_id = r.requirement_id
      order by (ci.status = 'verified') desc, ci.updated_at desc
      limit 1
    ) ci on true
  )
  select
    -- blocking open: required blocking not satisfied AS-OF the cut-off (waived ok).
    count(*) filter (where required and criticality = 'blocking'
                       and status is distinct from 'waived'
                       and (status is distinct from 'verified'
                            or (expires_at is not null and expires_at <= v_cut))),
    -- standard open: same, waived satisfies.
    count(*) filter (where required and criticality = 'standard'
                       and status is distinct from 'waived'
                       and (status is distinct from 'verified'
                            or (expires_at is not null and expires_at <= v_cut))),
    -- waived BLOCKING items force amber (can never be green).
    count(*) filter (where required and criticality = 'blocking' and status = 'waived'),
    -- expiring within 30 days AFTER the cut-off (informational amber).
    count(*) filter (where status = 'verified' and expires_at is not null
                       and expires_at > v_cut and expires_at <= v_cut + interval '30 days')
    into v_blocking_open, v_standard_open, v_waived_block, v_expiring
  from item_state;

  return case
    when v_blocking_open > 0                                          then 'red'
    when v_standard_open > 0 or v_expiring > 0 or v_waived_block > 0  then 'amber'
    else 'green'
  end;
end;
$$;
revoke all on function candidate.work_ready_status_on(uuid, uuid, date, int) from public;
grant execute on function candidate.work_ready_status_on(uuid, uuid, date, int) to authenticated, service_role;

-- ── Override lookup: a live override covering (candidate, set, as-of) ────────
-- set_id NULL on the override = ALL sets. Non-revoked and as-of within window.
create or replace function candidate.has_active_override(
  p_candidate_id uuid, p_set_id uuid, p_as_of date)
returns boolean language sql stable security definer
set search_path = candidate, public as $$
  select exists (
    select 1 from candidate.compliance_overrides o
    where o.candidate_id = p_candidate_id
      and o.revoked_at is null
      and (o.set_id is null or o.set_id = p_set_id)
      and o.valid_from  <= p_as_of
      and o.valid_until >= p_as_of
  );
$$;
revoke all on function candidate.has_active_override(uuid, uuid, date) from public;
grant execute on function candidate.has_active_override(uuid, uuid, date) to authenticated, service_role;

-- ── THE SHIFT-DATE GATE (fail-closed, override-aware) ───────────────────────
-- green+amber (as-of the date+buffer) => ready; red => blocked. An ACTIVE
-- override makes the candidate bookable REGARDLESS of the traffic light — the
-- caller can see this because work_ready_status_on() still reports the true
-- (red) colour while is_work_ready_on() returns true (via_override at the edge).
create or replace function candidate.is_work_ready_on(
  p_candidate_id uuid, p_set_id uuid, p_as_of date, p_buffer_days int default null)
returns boolean language sql stable security definer
set search_path = candidate, public as $$
  -- The candidate must ACTIVELY hold the set (fail-closed) — an override rescues
  -- a compliance failure, it does NOT conjure eligibility for a set the candidate
  -- was never assigned. Given that, readiness comes from a live override OR a
  -- green/amber as-of light.
  select exists (
           select 1 from candidate.candidate_requirement_sets crs
           where crs.candidate_id = p_candidate_id and crs.set_id = p_set_id and crs.active
         )
     and ( candidate.has_active_override(p_candidate_id, p_set_id, p_as_of)
        or candidate.work_ready_status_on(p_candidate_id, p_set_id, p_as_of, p_buffer_days)
           in ('green','amber') );
$$;
revoke all on function candidate.is_work_ready_on(uuid, uuid, date, int) from public;
grant execute on function candidate.is_work_ready_on(uuid, uuid, date, int) to authenticated, service_role;

-- ── Manager OVERRIDE (sensitive): audited, reasoned, time-bounded, visible ──
-- (table defined near the top of this file; RLS + write RPCs below.)
-- RLS: compliance officers may READ. NO insert/update/delete policy exists, so
-- the table is NOT client-writable — the only writers are the SECURITY DEFINER
-- RPCs below (which run as the table owner and bypass RLS).
alter table candidate.compliance_overrides enable row level security;
drop policy if exists "officer read overrides" on candidate.compliance_overrides;
create policy "officer read overrides" on candidate.compliance_overrides
  for select to authenticated
  using (candidate.is_authorized_user() and candidate.is_compliance_officer());

-- grant: officer-gated, reason MANDATORY, time-bounded. Appends a 'reinstated'
-- audit row (method='human') to the append-only verification_events spine.
create or replace function candidate.grant_compliance_override(
  p_candidate_id uuid, p_set_id uuid, p_reason text, p_valid_until date)
returns uuid language plpgsql security definer
set search_path = candidate, public as $$
declare
  v_actor uuid := auth.uid();
  v_id    uuid;
begin
  if not (candidate.is_authorized_user() and candidate.is_compliance_officer()) then
    raise exception 'not authorized';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'a reason is required to grant a compliance override';
  end if;
  if p_valid_until is null then
    raise exception 'valid_until is required';
  end if;
  if p_valid_until < current_date then
    raise exception 'valid_until (%) is in the past', p_valid_until;
  end if;

  insert into candidate.compliance_overrides
    (candidate_id, set_id, reason, granted_by, valid_from, valid_until)
  values
    (p_candidate_id, p_set_id, btrim(p_reason), v_actor, current_date, p_valid_until)
  returning id into v_id;

  -- Append-only audit — legible override lifecycle event.
  insert into candidate.verification_events
    (candidate_id, set_id, event_type, method, source_ref, notes, actor, actor_kind)
  values
    (p_candidate_id, p_set_id, 'override_granted', 'human', v_id::text,
     format('booking override GRANTED until %s%s — reason: %s',
            p_valid_until,
            case when p_set_id is null then ' (all sets)' else '' end,
            btrim(p_reason)),
     v_actor, 'human');

  return v_id;
end;
$$;
revoke all on function candidate.grant_compliance_override(uuid, uuid, text, date) from public;
grant execute on function candidate.grant_compliance_override(uuid, uuid, text, date) to authenticated;

-- revoke: officer-gated, reason MANDATORY, idempotent. Appends an audit row.
create or replace function candidate.revoke_compliance_override(p_id uuid, p_reason text)
returns void language plpgsql security definer
set search_path = candidate, public as $$
declare
  v_actor uuid := auth.uid();
  v_ovr   candidate.compliance_overrides;
begin
  if not (candidate.is_authorized_user() and candidate.is_compliance_officer()) then
    raise exception 'not authorized';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'a reason is required to revoke a compliance override';
  end if;

  select * into v_ovr from candidate.compliance_overrides where id = p_id for update;
  if not found then
    raise exception 'override % not found', p_id;
  end if;
  if v_ovr.revoked_at is not null then
    return;                                     -- already revoked: idempotent no-op
  end if;

  update candidate.compliance_overrides
    set revoked_at = now(), revoked_by = v_actor, revoke_reason = btrim(p_reason)
    where id = p_id;

  insert into candidate.verification_events
    (candidate_id, set_id, event_type, method, source_ref, notes, actor, actor_kind)
  values
    (v_ovr.candidate_id, v_ovr.set_id, 'override_revoked', 'human', p_id::text,
     format('booking override REVOKED — reason: %s', btrim(p_reason)),
     v_actor, 'human');
end;
$$;
revoke all on function candidate.revoke_compliance_override(uuid, text) from public;
grant execute on function candidate.revoke_compliance_override(uuid, text) to authenticated;

-- ── RLS: compliance_settings — authorised staff read; admins write ──────────
alter table candidate.compliance_settings enable row level security;
drop policy if exists "auth read settings"  on candidate.compliance_settings;
drop policy if exists "admin write settings" on candidate.compliance_settings;
create policy "auth read settings" on candidate.compliance_settings
  for select to authenticated using (candidate.is_authorized_user());
create policy "admin write settings" on candidate.compliance_settings
  for all to authenticated
  using (candidate.is_authorized_user() and candidate.is_admin())
  with check (candidate.is_authorized_user() and candidate.is_admin());

-- ==== sql/41_pre_expiry_ladder.sql ====
-- ============================================================================
--  Day Webster — Candidate Pipeline · Pre-expiry reminder ladder
--  File: candidate-pipeline/sql/41_pre_expiry_ladder.sql
--  Run AFTER 22–25 and 40. Idempotent / additive.  STATUS: DRAFT — NOT YET APPLIED.
--
--  [DECISION E1] CANDIDATE_EXPERIENCE_DESIGN §2a — "nothing ever expires
--  unnoticed". Every time-bound item drives an escalating, expiry-anchored nudge
--  sequence off its own expires_at at T-90/60/30/14/7/1 days (configurable,
--  per-requirement override optional). Each rung fires ONCE per item per expiry
--  and RESETS automatically on renewal (the tracking key includes expires_at, so
--  a renewed item — a NEW expiry — starts a fresh ladder, and an unchanged item
--  is never double-sent).
--
--  Adds:
--    · pre_expiry_offsets            — the configurable ladder (seeded 90..1)
--    · expiry_reminders_sent         — per-(item,expiry,offset) once-only ledger
--    · compliance_requirements.candidate_label / candidate_help — candidate-facing
--    · messages.template             — comms template tag (multi-channel ready)
--    · due_expiry_reminders()        — the send worklist (nearest due rung/item)
--
--  The edge sweep (functions/early-warnings) reads due_expiry_reminders(), sends
--  the email, then records expiry_reminders_sent + a candidate.messages row.
-- ============================================================================

-- ── Candidate-facing renewal copy (optional; null => generic fallback) ──────
alter table candidate.compliance_requirements
  add column if not exists candidate_label text,   -- friendly name, e.g. "your DBS"
  add column if not exists candidate_help  text;    -- plain renewal advice

-- ── Comms template tag on the message log (future multi-channel engine) ─────
alter table candidate.messages
  add column if not exists template text;

-- ── Configurable ladder offsets (T-minus days before expiry) ────────────────
-- requirement_code NULL = applies to ALL requirements (global). A row WITH a
-- requirement_code is a per-requirement OVERRIDE: when any active override rows
-- exist for a requirement, ONLY those apply to it (the global ladder is ignored
-- for that requirement) — see due_expiry_reminders().
create table if not exists candidate.pre_expiry_offsets (
  id               uuid primary key default gen_random_uuid(),
  offset_days      int  not null check (offset_days > 0),
  requirement_code text,                          -- null = all requirements
  active           boolean not null default true,
  created_at       timestamptz not null default now()
);
-- Null-collapsing uniqueness so re-seeding is a true no-op (D5 pattern, file 13).
create unique index if not exists pre_expiry_offsets_key_uniq
  on candidate.pre_expiry_offsets (offset_days, coalesce(requirement_code, '*'));

insert into candidate.pre_expiry_offsets (offset_days, requirement_code)
values (90, null), (60, null), (30, null), (14, null), (7, null), (1, null)
on conflict (offset_days, coalesce(requirement_code, '*')) do nothing;

-- ── Once-only send ledger — resets on renewal via the expires_at in the key ─
create table if not exists candidate.expiry_reminders_sent (
  id           uuid primary key default gen_random_uuid(),
  item_id      uuid not null references candidate.compliance_items(id) on delete cascade,
  candidate_id uuid not null references candidate.candidates(id) on delete cascade,
  expires_at   timestamptz not null,             -- the expiry this ladder anchors on
  offset_days  int not null,
  channel      text not null default 'email',    -- multi-channel ready (email now)
  message_id   uuid references candidate.messages(id) on delete set null,
  sent_at      timestamptz not null default now(),
  unique (item_id, expires_at, offset_days)
);
create index if not exists expiry_reminders_sent_item_idx
  on candidate.expiry_reminders_sent (item_id);
create index if not exists expiry_reminders_sent_candidate_idx
  on candidate.expiry_reminders_sent (candidate_id);

-- ── The send worklist: the NEAREST due, unsent rung per current item ────────
-- For each candidate's CURRENT (latest) verified blocking/standard item on an
-- active set with a FUTURE expiry, pick the tightest ladder rung whose window is
-- open (offset_days >= days_left) and that has not yet been sent for this exact
-- expiry. Sending only the nearest due rung (rather than every passed rung)
-- keeps each rung firing exactly once on its day and prevents a burst when an
-- item is added late. A renewed item (new expiry) or a superseded old instance
-- simply no longer matches, so no chase goes out for a renewed item.
create or replace function candidate.due_expiry_reminders(
  p_now timestamptz default now(), p_limit int default 1000)
returns table(
  item_id          uuid,
  candidate_id     uuid,
  requirement_id   uuid,
  requirement_code text,
  requirement_name text,
  candidate_label  text,
  candidate_help   text,
  expires_at       timestamptz,
  days_left        int,
  offset_days      int,
  first_name       text,
  email            text,
  buffer_days      int)
language sql stable security definer
set search_path = candidate, public as $$
  with current_item as (
    -- latest item per (candidate, requirement) within active sets, blocking/standard.
    select distinct on (ci.candidate_id, ci.requirement_id)
      ci.id            as item_id,
      ci.candidate_id,
      ci.requirement_id,
      ci.status,
      ci.expires_at,
      cr.code          as requirement_code,
      cr.name          as requirement_name,
      cr.candidate_label,
      cr.candidate_help
    from candidate.compliance_items ci
    join candidate.candidate_requirement_sets crs
      on crs.candidate_id = ci.candidate_id and crs.active
    join candidate.requirement_set_items rsi
      on rsi.set_id = crs.set_id and rsi.requirement_id = ci.requirement_id
    join candidate.compliance_requirements cr on cr.id = ci.requirement_id
    where coalesce(rsi.criticality, cr.criticality) in ('blocking','standard')
      and coalesce(rsi.required_override, cr.required)   -- only chase REQUIRED items (an optional doc never blocks the gate)
    order by ci.candidate_id, ci.requirement_id,
             (ci.status = 'verified') desc, ci.updated_at desc
  ),
  live as (
    select ci.*,
           c.first_name, c.email,
           greatest(0, ceil(extract(epoch from (ci.expires_at - p_now)) / 86400.0))::int as days_left
    from current_item ci
    join candidate.candidates c on c.id = ci.candidate_id
    where ci.status = 'verified'                 -- only a live, verified doc has a ladder
      and ci.expires_at is not null
      and ci.expires_at > p_now                  -- future expiry (expired => early-warnings path)
  ),
  rung as (
    select l.*,
      -- the tightest applicable rung whose window is open. Per-requirement
      -- overrides win: if the requirement has its own rows, ignore the global set.
      (select min(o.offset_days)
         from candidate.pre_expiry_offsets o
         where o.active
           and o.offset_days >= l.days_left
           and case
                 when exists (select 1 from candidate.pre_expiry_offsets o2
                              where o2.active and o2.requirement_code = l.requirement_code)
                   then o.requirement_code = l.requirement_code
                 else o.requirement_code is null
               end
      ) as offset_days
    from live l
  )
  select r.item_id, r.candidate_id, r.requirement_id, r.requirement_code,
         r.requirement_name, r.candidate_label, r.candidate_help,
         r.expires_at, r.days_left, r.offset_days, r.first_name, r.email,
         candidate.booking_buffer_days()
  from rung r
  where r.offset_days is not null
    and not exists (
      select 1 from candidate.expiry_reminders_sent s
      where s.item_id     = r.item_id
        and s.expires_at  = r.expires_at
        and s.offset_days = r.offset_days
    )
  order by r.expires_at
  limit greatest(coalesce(p_limit, 1000), 0);
$$;
revoke all on function candidate.due_expiry_reminders(timestamptz, int) from public;
grant execute on function candidate.due_expiry_reminders(timestamptz, int) to authenticated, service_role;

-- ── RLS ─────────────────────────────────────────────────────────────────────
alter table candidate.pre_expiry_offsets      enable row level security;
alter table candidate.expiry_reminders_sent   enable row level security;

-- Ladder config: authorised staff read; admins write.
drop policy if exists "auth read offsets"  on candidate.pre_expiry_offsets;
drop policy if exists "admin write offsets" on candidate.pre_expiry_offsets;
create policy "auth read offsets" on candidate.pre_expiry_offsets
  for select to authenticated using (candidate.is_authorized_user());
create policy "admin write offsets" on candidate.pre_expiry_offsets
  for all to authenticated
  using (candidate.is_authorized_user() and candidate.is_admin())
  with check (candidate.is_authorized_user() and candidate.is_admin());

-- Send ledger: authorised staff read. No client write policy — the sweep writes
-- it via service_role (bypasses RLS); no logged-in user forges a "sent" row.
drop policy if exists "auth read reminders_sent" on candidate.expiry_reminders_sent;
create policy "auth read reminders_sent" on candidate.expiry_reminders_sent
  for select to authenticated using (candidate.is_authorized_user());

-- ==== sql/42_compliance_breach.sql ====
-- ============================================================================
--  Day Webster — Candidate Pipeline · Compliance BREACH: record + alert + report
--  File: candidate-pipeline/sql/42_compliance_breach.sql
--  Run AFTER 34-40 (needs the sets/items/status spine, the shift-date gate +
--  overrides, the officer/overseer routing, and the reporting rollup patterns).
--  Idempotent / additive.  STATUS: DRAFT — NOT YET APPLIED.
--
--  A COMPLIANCE BREACH is what happens when a worker is BOOKED for a shift on a
--  date they are NOT compliant for — the shift-date gate (sql/40) said either
--  'red' (blocked) OR ready-only-via a manager OVERRIDE. Placing that worker
--  means a required document is elapsed/unsatisfied on the day of work. This file
--  makes that event first-class:
--
--    1. noncompliant_items_on()  — the single source of "which docs are the
--       problem" as-of a date+buffer (mirrors work_ready_status_on's math); used
--       by the booking gate to WARN and by the breach snapshot to RECORD.
--    2. compliance_breaches       — one immutable-core row per (candidate,set,
--       shift,booking) breach, with a JSONB snapshot of the elapsed docs.
--    3. record_booking_breach()   — officer/service RPC: verify a breach really
--       exists (never log a spurious one), snapshot it, log it (idempotent), and
--       append a 'breach_logged' audit event. The alert email is sent by the
--       booking-breach edge function that wraps this RPC.
--    4. acknowledge/resolve RPCs  — officer lifecycle, append-only audited.
--    5. open_breaches view + two REPORT RPCs — the officer queue + the exec
--       headline "N candidates working with elapsed documents".
--
--  Security: every function is SECURITY DEFINER + `set search_path = candidate,
--  public`, revokes public. compliance_breaches has an officer-only SELECT policy
--  and NO insert/update/delete policy — the ONLY writers are the SECURITY DEFINER
--  RPCs below (which run as owner). The verification_events spine stays
--  append-only; breach lifecycle rows are written only via RPC INSERT.
-- ============================================================================

-- ── noncompliant_items_on: the elapsed/unsatisfied REQUIRED docs as-of a date ─
-- Returns the required (coalesce(rsi.required_override, cr.required)) blocking OR
-- standard items in the set whose LATEST item (same verified-first/updated_at
-- tiebreak as work_ready_status_on) is NOT satisfied as-of the cut-off:
--   cut-off = greatest(now(), shift_date + buffer)   -- clamp like sql/40
--   satisfied = 'waived' OR ('verified' AND (expires_at is null OR > cut-off))
-- This is the single source of "which docs block the booking" — the gate WARNS
-- with it and the breach snapshot RECORDS it, so the two can never disagree.
create or replace function candidate.noncompliant_items_on(
    p_candidate_id uuid, p_set_id uuid, p_as_of date, p_buffer_days int default null)
returns table(requirement_id uuid, code text, name text, status text, expires_at timestamptz)
language sql stable security definer
set search_path = candidate, public as $$
  with params as (
    select greatest(coalesce(p_buffer_days, candidate.booking_buffer_days()), 0) as buffer
  ),
  cut as (
    select greatest(now(),
                    (p_as_of + make_interval(days => (select buffer from params)))::timestamptz) as v_cut
  ),
  reqs as (
    select rsi.requirement_id,
           coalesce(rsi.criticality, cr.criticality)   as criticality,
           coalesce(rsi.required_override, cr.required) as required,
           cr.code, cr.name
    from candidate.requirement_set_items rsi
    join candidate.compliance_requirements cr on cr.id = rsi.requirement_id
    where rsi.set_id = p_set_id
  ),
  held as (
    -- Fail-closed like work_ready_status_on(): the candidate must ACTIVELY hold the
    -- set. If not, the gate is 'red' for that reason alone (no doc is at fault), so
    -- the snapshot must still be non-empty — otherwise a fail-closed red would log a
    -- breach with an empty snapshot. We surface that as an explicit SET_NOT_HELD row.
    select exists (
      select 1 from candidate.candidate_requirement_sets crs
      where crs.candidate_id = p_candidate_id and crs.set_id = p_set_id and crs.active
    ) as h
  ),
  item_state as (
    select r.requirement_id, r.criticality, r.required, r.code, r.name,
           ci.status, ci.expires_at
    from reqs r
    left join lateral (
      select ci.status, ci.expires_at
      from candidate.compliance_items ci
      where ci.candidate_id = p_candidate_id
        and ci.requirement_id = r.requirement_id
      order by (ci.status = 'verified') desc, ci.updated_at desc
      limit 1
    ) ci on true
  ),
  rows as (
    -- The whole set is not applicable to a candidate who doesn't hold it.
    select null::uuid as requirement_id, 'SET_NOT_HELD' as code,
           'Candidate is not actively assigned to this requirement set' as name,
           'not_assigned' as status, null::timestamptz as expires_at, 0 as sort_key
    from held where not held.h
    union all
    -- The elapsed/unsatisfied REQUIRED docs (only when the set IS held).
    select i.requirement_id, i.code, i.name,
           coalesce(i.status, 'missing') as status,   -- null latest item => no doc at all
           i.expires_at,
           case when i.criticality = 'blocking' then 1 else 2 end as sort_key
    from item_state i, cut, held
    where held.h
      and i.required
      and i.criticality in ('blocking','standard')
      and i.status is distinct from 'waived'
      and (i.status is distinct from 'verified'
           or (i.expires_at is not null and i.expires_at <= cut.v_cut))
  )
  select requirement_id, code, name, status, expires_at
  from rows
  order by sort_key, code;
$$;
revoke all on function candidate.noncompliant_items_on(uuid, uuid, date, int) from public;
grant execute on function candidate.noncompliant_items_on(uuid, uuid, date, int) to authenticated, service_role;

-- ── Extend the append-only audit vocabulary with the breach lifecycle ────────
-- Drop-then-add keeps this idempotent; the new list is a strict SUPERSET (keeps
-- everything through sql/40's override_granted/override_revoked) so no existing
-- verification_events row is ever invalidated.
alter table candidate.verification_events
  drop constraint if exists verification_events_event_type_check;
alter table candidate.verification_events
  add constraint verification_events_event_type_check
  check (event_type in ('verified','rejected','unsuitable','expired','waived',
         'reinstated','evidence_received','recheck_requested','status_recomputed',
         'override_granted','override_revoked',
         'breach_logged','breach_acknowledged','breach_resolved'));

-- ── compliance_settings: the central compliance mailbox (configurable) ───────
alter table candidate.compliance_settings
  add column if not exists compliance_alert_email text;

-- ── compliance_breaches: one row per booked-non-compliant placement ──────────
-- Core fields (candidate/set/shift/snapshot/via_override) are written ONCE at
-- log time and never rewritten; only the lifecycle columns move. RLS below makes
-- this officer-read-only and NOT client-writable — writes go through the RPCs.
create table if not exists candidate.compliance_breaches (
  id              uuid primary key default gen_random_uuid(),
  candidate_id    uuid not null references candidate.candidates(id) on delete cascade,
  set_id          uuid references candidate.requirement_sets(id) on delete set null,
  shift_date      date not null,
  booking_ref     text,
  reason          text,
  via_override    boolean not null default false,   -- true = only bookable via a manager override
  override_id     uuid references candidate.compliance_overrides(id) on delete set null,
  expired_items   jsonb not null default '[]',      -- snapshot: [{code,name,expires_at,status}]
  status          text not null default 'open'
                  check (status in ('open','acknowledged','resolved')),
  booked_by       uuid references auth.users(id) on delete set null,
  booked_by_email text,
  booked_at       timestamptz not null default now(),
  acknowledged_by uuid references auth.users(id) on delete set null,
  acknowledged_at timestamptz,
  resolved_by     uuid references auth.users(id) on delete set null,
  resolved_at     timestamptz,
  notes           text
);

-- Idempotency guard: the same booking can't double-log. coalesce(booking_ref,'')
-- so a null ref still collapses repeat calls for the same candidate/set/shift.
create unique index if not exists compliance_breaches_booking_uq
  on candidate.compliance_breaches (candidate_id, set_id, shift_date, coalesce(booking_ref, ''));
create index if not exists compliance_breaches_open_idx
  on candidate.compliance_breaches (status) where status <> 'resolved';
create index if not exists compliance_breaches_candidate_idx
  on candidate.compliance_breaches (candidate_id);
create index if not exists compliance_breaches_shift_idx
  on candidate.compliance_breaches (shift_date);

-- ── RLS: compliance officers may READ; NO write policy => not client-writable ─
alter table candidate.compliance_breaches enable row level security;
drop policy if exists "officer read breaches" on candidate.compliance_breaches;
create policy "officer read breaches" on candidate.compliance_breaches
  for select to authenticated
  using (candidate.is_authorized_user() and candidate.is_compliance_officer());
-- SELECT only at the grant level too: the RPCs (SECURITY DEFINER) do every write.
grant select on candidate.compliance_breaches to authenticated;

-- ── record_booking_breach: verify → snapshot → log (idempotent) → audit ──────
-- Gate mirrors sql/38's service-or-officer pattern: an officer (UI) OR the
-- service_role edge function (booking system) may call. NEVER logs a spurious
-- breach — if the candidate is genuinely compliant (green/amber and NOT relying
-- on an override) it RAISES instead. Idempotent on the booking guard: a repeat
-- call returns the same id and appends no second audit row.
create or replace function candidate.record_booking_breach(
    p_candidate_id    uuid,
    p_set_id          uuid,
    p_shift_date      date,
    p_booking_ref     text default null,
    p_reason          text default null,
    p_booked_by_email text default null,
    p_buffer_days     int  default null)
returns uuid language plpgsql security definer
set search_path = candidate, public as $$
declare
  v_is_service boolean := candidate.is_service_role();
  v_actor      uuid    := auth.uid();
  v_status     text;
  v_overridden boolean;
  v_items      jsonb;
  v_override_id uuid;
  v_count      int;
  v_id         uuid;
  v_inserted   boolean;
begin
  if not (candidate.is_compliance_officer() or v_is_service) then
    raise exception 'not authorized';
  end if;
  if p_shift_date is null then
    raise exception 'shift_date is required';
  end if;
  -- set_id is mandatory: a breach is always against a specific requirement set, and
  -- a NULL set_id would defeat the idempotency guard (NULLs compare as distinct, so
  -- ON CONFLICT never matches) — letting the same booking log duplicate rows/audit.
  if p_set_id is null then
    raise exception 'set_id is required';
  end if;

  v_status     := candidate.work_ready_status_on(p_candidate_id, p_set_id, p_shift_date, p_buffer_days);
  v_overridden := candidate.has_active_override(p_candidate_id, p_set_id, p_shift_date);

  -- A breach is STRICTLY a RED light (a genuinely elapsed/unsatisfied blocking doc,
  -- or the fail-closed reds: set not held). green/amber = compliant/placeable, so
  -- there is NO breach — even if a stale/blanket override happens to be active
  -- (a compliant worker never "relies" on an override). The override only sets the
  -- via_override flag on a red breach; it never creates one.
  if v_status <> 'red' then
    raise exception 'no breach: candidate is compliant for %', p_shift_date;
  end if;

  -- Snapshot the elapsed/unsatisfied required docs as-of the shift date+buffer.
  select coalesce(jsonb_agg(jsonb_build_object(
           'code', code, 'name', name, 'expires_at', expires_at, 'status', status)), '[]'::jsonb)
    into v_items
  from candidate.noncompliant_items_on(p_candidate_id, p_set_id, p_shift_date, p_buffer_days);
  v_count := jsonb_array_length(v_items);

  -- The live override row rescuing this booking (if any).
  if v_overridden then
    select o.id into v_override_id
    from candidate.compliance_overrides o
    where o.candidate_id = p_candidate_id
      and o.revoked_at is null
      and (o.set_id is null or o.set_id = p_set_id)
      and o.valid_from  <= p_shift_date
      and o.valid_until >= p_shift_date
    order by o.valid_until desc
    limit 1;
  end if;

  -- Log it. ON CONFLICT (the booking guard) makes a repeat call idempotent — it
  -- returns the SAME id. `xmax = 0` in RETURNING is true only on a genuine INSERT,
  -- so the audit event is appended exactly once per real breach.
  insert into candidate.compliance_breaches
    (candidate_id, set_id, shift_date, booking_ref, reason, via_override, override_id,
     expired_items, status, booked_by, booked_by_email)
  values
    (p_candidate_id, p_set_id, p_shift_date, p_booking_ref, p_reason, v_overridden, v_override_id,
     v_items, 'open', v_actor, p_booked_by_email)
  -- Idempotent: a repeat call for the same booking returns the SAME id and does NOT
  -- rewrite the original (immutable) breach — the no-op `set` keeps the first-logged
  -- reason intact while still yielding a RETURNING row. `xmax = 0` is true only on a
  -- genuine INSERT, so the audit event is appended exactly once per real breach.
  on conflict (candidate_id, set_id, shift_date, coalesce(booking_ref, ''))
  do update set reason = candidate.compliance_breaches.reason
  returning id, (xmax = 0) into v_id, v_inserted;

  if v_inserted then
    insert into candidate.verification_events
      (candidate_id, set_id, event_type, method, source_ref, notes, actor, actor_kind)
    values
      (p_candidate_id, p_set_id, 'breach_logged',
       case when v_actor is not null then 'human' else 'system' end,
       v_id::text,
       format('booking breach LOGGED for shift %s — %s required document(s) elapsed/unsatisfied%s',
              p_shift_date, v_count,
              case when v_overridden then ' (permitted only by a manager override)' else '' end),
       v_actor,
       case when v_actor is not null then 'human' else 'system' end);
  end if;

  return v_id;
end;
$$;
revoke all on function candidate.record_booking_breach(uuid, uuid, date, text, text, text, int) from public;
grant execute on function candidate.record_booking_breach(uuid, uuid, date, text, text, text, int) to authenticated, service_role;

-- ── acknowledge_breach: officer flips open => acknowledged (idempotent) ──────
create or replace function candidate.acknowledge_breach(p_id uuid, p_note text default null)
returns void language plpgsql security definer
set search_path = candidate, public as $$
declare v_b candidate.compliance_breaches;
begin
  if not (candidate.is_authorized_user() and candidate.is_compliance_officer()) then
    raise exception 'not authorized';
  end if;
  select * into v_b from candidate.compliance_breaches where id = p_id for update;
  if not found then
    raise exception 'breach % not found', p_id;
  end if;
  if v_b.status <> 'open' then
    return;                                        -- already acknowledged/resolved: no-op
  end if;

  update candidate.compliance_breaches
    set status = 'acknowledged', acknowledged_by = auth.uid(), acknowledged_at = now(),
        notes = coalesce(nullif(btrim(p_note), ''), notes)
    where id = p_id;

  insert into candidate.verification_events
    (candidate_id, set_id, event_type, method, source_ref, notes, actor, actor_kind)
  values
    (v_b.candidate_id, v_b.set_id, 'breach_acknowledged', 'human', p_id::text,
     coalesce(nullif(btrim(p_note), ''), 'breach acknowledged'), auth.uid(), 'human');
end;
$$;
revoke all on function candidate.acknowledge_breach(uuid, text) from public;
grant execute on function candidate.acknowledge_breach(uuid, text) to authenticated;

-- ── resolve_breach: officer flips open/acknowledged => resolved (idempotent) ─
create or replace function candidate.resolve_breach(p_id uuid, p_note text default null)
returns void language plpgsql security definer
set search_path = candidate, public as $$
declare v_b candidate.compliance_breaches;
begin
  if not (candidate.is_authorized_user() and candidate.is_compliance_officer()) then
    raise exception 'not authorized';
  end if;
  select * into v_b from candidate.compliance_breaches where id = p_id for update;
  if not found then
    raise exception 'breach % not found', p_id;
  end if;
  if v_b.status = 'resolved' then
    return;                                        -- already resolved: no-op
  end if;

  update candidate.compliance_breaches
    set status = 'resolved', resolved_by = auth.uid(), resolved_at = now(),
        notes = coalesce(nullif(btrim(p_note), ''), notes)
    where id = p_id;

  insert into candidate.verification_events
    (candidate_id, set_id, event_type, method, source_ref, notes, actor, actor_kind)
  values
    (v_b.candidate_id, v_b.set_id, 'breach_resolved', 'human', p_id::text,
     coalesce(nullif(btrim(p_note), ''), 'breach resolved'), auth.uid(), 'human');
end;
$$;
revoke all on function candidate.resolve_breach(uuid, text) from public;
grant execute on function candidate.resolve_breach(uuid, text) to authenticated;

-- ── open_breaches: the officer queue (security_invoker => officer-only RLS) ──
create or replace view candidate.open_breaches
with (security_invoker = true) as
select
  b.id,
  b.candidate_id,
  c.first_name,
  c.last_name,
  (c.first_name || ' ' || c.last_name) as candidate_name,
  c.email                              as candidate_email,
  c.compliance_officer,
  coalesce(st.full_name, au.email)     as officer_name,
  c.discipline_id,
  di.name                              as discipline_name,
  di.division_id,
  dv.name                              as division_name,
  b.set_id,
  b.shift_date,
  b.booking_ref,
  b.reason,
  b.via_override,
  b.override_id,
  b.expired_items,
  b.status,
  b.booked_by_email,
  b.booked_at,
  b.acknowledged_at,
  b.notes
from candidate.compliance_breaches b
join candidate.candidates  c  on c.id = b.candidate_id
left join candidate.staff      st on st.user_id = c.compliance_officer
left join candidate.app_users  au on au.user_id = c.compliance_officer
left join candidate.disciplines di on di.id = c.discipline_id
left join candidate.divisions  dv on dv.id = di.division_id
where b.status <> 'resolved';

grant select on candidate.open_breaches to authenticated;

-- ── compliance_breach_report: officer × division × discipline queue counts ───
-- open_breaches            = count of NON-RESOLVED breach rows (any shift date)
-- candidates_working_...   = COUNT(DISTINCT candidate) among non-resolved breaches
--                            whose shift_date >= p_as_of (currently/future working
--                            non-compliant). rollup((all dims)) adds a grand total;
--                            is_total=1 marks it (grouping() like sql/36).
create or replace function candidate.compliance_breach_report(
    p_as_of    date default current_date,
    p_division uuid default null,
    p_officer  uuid default null)
returns table(
    division_id                     uuid,
    division_name                   text,
    discipline_id                   uuid,
    discipline_name                 text,
    compliance_officer              uuid,
    officer_name                    text,
    open_breaches                   bigint,
    candidates_working_noncompliant bigint,
    is_total                        int)
language plpgsql stable security definer
set search_path = candidate, public as $$
begin
  if not (candidate.is_authorized_user() and candidate.is_compliance_officer()) then
    raise exception 'not authorized';
  end if;

  return query
  with base as (
    select
      dv.id   as division_id,   dv.name as division_name,
      di.id   as discipline_id, di.name as discipline_name,
      c.compliance_officer,
      coalesce(st.full_name, au.email) as officer_name,
      b.id as breach_id, b.candidate_id, b.shift_date
    from candidate.compliance_breaches b
    join candidate.candidates  c  on c.id = b.candidate_id
    left join candidate.disciplines di on di.id = c.discipline_id
    left join candidate.divisions  dv on dv.id = di.division_id
    left join candidate.staff      st on st.user_id = c.compliance_officer
    left join candidate.app_users  au on au.user_id = c.compliance_officer
    where b.status <> 'resolved'
      and (p_division is null or dv.id = p_division)
      and (p_officer  is null or c.compliance_officer = p_officer)
  )
  select
    base.division_id, base.division_name, base.discipline_id, base.discipline_name,
    base.compliance_officer, base.officer_name,
    count(base.breach_id) as open_breaches,
    count(distinct base.candidate_id) filter (where base.shift_date >= p_as_of)
      as candidates_working_noncompliant,
    grouping(base.division_id) as is_total
  from base
  group by rollup((base.division_id, base.division_name, base.discipline_id,
                   base.discipline_name, base.compliance_officer, base.officer_name));
end;
$$;
revoke all on function candidate.compliance_breach_report(date, uuid, uuid) from public;
grant execute on function candidate.compliance_breach_report(date, uuid, uuid) to authenticated;

-- ── breach_exec_summary: division rollup for the exec headline ───────────────
-- "N candidates working with elapsed documents" = the grand-total row's
-- candidates_working_noncompliant (is_total=1).
create or replace function candidate.breach_exec_summary(p_as_of date default current_date)
returns table(
    division_id                     uuid,
    division_name                   text,
    candidates_working_noncompliant bigint,
    open_breaches                   bigint,
    is_total                        int)
language plpgsql stable security definer
set search_path = candidate, public as $$
begin
  if not (candidate.is_authorized_user() and candidate.is_compliance_officer()) then
    raise exception 'not authorized';
  end if;

  return query
  with base as (
    select dv.id as division_id, dv.name as division_name,
           b.id as breach_id, b.candidate_id, b.shift_date
    from candidate.compliance_breaches b
    join candidate.candidates  c  on c.id = b.candidate_id
    left join candidate.disciplines di on di.id = c.discipline_id
    left join candidate.divisions  dv on dv.id = di.division_id
    where b.status <> 'resolved'
  )
  select
    base.division_id, base.division_name,
    count(distinct base.candidate_id) filter (where base.shift_date >= p_as_of)
      as candidates_working_noncompliant,
    count(base.breach_id) as open_breaches,
    grouping(base.division_id) as is_total
  from base
  group by rollup((base.division_id, base.division_name));
end;
$$;
revoke all on function candidate.breach_exec_summary(date) from public;
grant execute on function candidate.breach_exec_summary(date) to authenticated;

-- ==== sql/43_candidate_attributes.sql ====
-- ============================================================================
--  Day Webster — Candidate Pipeline · Client Checklist Auto-Fill (Phase 1)
--  File: candidate-pipeline/sql/43_candidate_attributes.sql
--  Run AFTER 10-42. Idempotent / additive.  STATUS: DRAFT — NOT YET APPLIED.
--
--  Two jobs, both prerequisites for the Compliance Passport (sql/43b):
--
--    (a) FIX THE UI-AHEAD-OF-SCHEMA SILENT-DROP BUG.  candidates.html already
--        renders + WRITES `c.address`, `c.ni_number`, `c.compliance_status`,
--        `c.audited_by`, `c.audited_at`, and `compliance_items.ai_review`, but no
--        migration ever added those columns — so every one of those writes today
--        silently no-ops (PostgREST drops unknown keys). We add the exact column
--        names the page references so the existing writes start persisting, plus
--        the design's identity columns the passport needs (nationality, gender,
--        place_of_birth). `add column if not exists` => additive + re-runnable.
--
--    (b) THE LONG-TAIL KV TABLE `candidate_attributes` — the overlay the passport
--        reads for any vocabulary key (dbs.number, rtw.share_code,
--        training.bls.expiry, …) that no first-class column/compliance_item
--        satisfies. A new client form can introduce a new data point (map once,
--        capture once) with NO further migration.
--
--  Security: officer-only. `candidate_attributes` holds special-category-adjacent
--  identifiers (DBS number, RTW share code) — officer RLS read + officer upsert,
--  no anon, never returned to a non-officer. NI number is a first-class column on
--  `candidates`, already behind the candidates officer/staff RLS.
-- ============================================================================

-- ── (a) Identity + audit columns on candidates (fixes the silent-drop bug) ───
-- Names MATCH candidates.html exactly so its existing writes stop no-oping:
--   f_address -> address · f_ni -> ni_number · f_compstatus -> compliance_status
--   signOff() -> audited_by / audited_at.
alter table candidate.candidates
  add column if not exists address          text;          -- single-line address (f_address)
alter table candidate.candidates
  add column if not exists ni_number        text;          -- National Insurance no. (f_ni)
alter table candidate.candidates
  add column if not exists compliance_status text
    default 'not_started'
    check (compliance_status is null or compliance_status in
      ('not_started','processing','maintenance','requires_update','on_hold'));
alter table candidate.candidates
  add column if not exists audited_by        uuid references auth.users(id) on delete set null;
alter table candidate.candidates
  add column if not exists audited_at        timestamptz;

-- Design identity columns the passport / client forms need.
alter table candidate.candidates
  add column if not exists nationality       text;
alter table candidate.candidates
  add column if not exists gender            text;
alter table candidate.candidates
  add column if not exists place_of_birth    text;

-- ── (a) ai_review on compliance_items (the AI pre-check block the UI renders) ─
-- candidates.html reads it as an OBJECT (it.ai_review.confidence / .issues /
-- .candidate_feedback / .note) and the review-document function writes it — jsonb.
alter table candidate.compliance_items
  add column if not exists ai_review         jsonb;

-- ── (b) candidate_attributes — the long-tail KV overlay (design §1b) ─────────
create table if not exists candidate.candidate_attributes (
  candidate_id uuid not null references candidate.candidates(id) on delete cascade,
  key          text not null,                 -- vocabulary key, e.g. 'dbs.number'
  value        text,
  provenance   text not null default 'self_declared'
               check (provenance in ('verified','self_declared','derived')),
  as_at        date,
  source_ref   text,
  updated_by   uuid references auth.users(id) on delete set null,
  updated_at   timestamptz not null default now(),
  primary key (candidate_id, key)
);
create index if not exists candidate_attributes_key_idx
  on candidate.candidate_attributes (key);

-- (c) Reuse the schema's existing candidate.set_updated_at() (sql/10) — do NOT
-- redefine it. Just attach it so an upsert refreshes updated_at.
drop trigger if exists candidate_attributes_set_updated_at on candidate.candidate_attributes;
create trigger candidate_attributes_set_updated_at
  before update on candidate.candidate_attributes
  for each row execute function candidate.set_updated_at();

-- ── RLS: officer read + officer upsert; no anon ─────────────────────────────
alter table candidate.candidate_attributes enable row level security;

drop policy if exists "officer read attributes"   on candidate.candidate_attributes;
drop policy if exists "officer insert attributes" on candidate.candidate_attributes;
drop policy if exists "officer update attributes" on candidate.candidate_attributes;

create policy "officer read attributes" on candidate.candidate_attributes
  for select to authenticated
  using (candidate.is_authorized_user() and candidate.is_compliance_officer());
create policy "officer insert attributes" on candidate.candidate_attributes
  for insert to authenticated
  with check (candidate.is_authorized_user() and candidate.is_compliance_officer());
create policy "officer update attributes" on candidate.candidate_attributes
  for update to authenticated
  using (candidate.is_authorized_user() and candidate.is_compliance_officer())
  with check (candidate.is_authorized_user() and candidate.is_compliance_officer());
-- (No DELETE policy: attributes are corrected in place by upsert, not deleted.)

grant select, insert, update on candidate.candidate_attributes to authenticated;

-- ==== sql/43b_compliance_passport.sql ====
-- ============================================================================
--  Day Webster — Candidate Pipeline · Client Checklist Auto-Fill (Phase 1)
--  File: candidate-pipeline/sql/43b_compliance_passport.sql
--  Run AFTER 43. Idempotent / additive.  STATUS: DRAFT — NOT YET APPLIED.
--
--  THE COMPLIANCE PASSPORT — the canonical, live-resolved answer to "everything a
--  client checklist could ask about this candidate", built ONCE and reused by
--  every client template's token->field map (design §1). Officer/service-gated
--  SECURITY DEFINER, so the token vocabulary is resolved with full read of the
--  candidate file but never leaks to a non-officer.
--
--  Every field is an OBJECT — never a bare scalar — carrying:
--     { value, provenance ∈ {verified,self_declared,derived,missing}, as_at, source_ref }
--  A field with no data is returned EXPLICITLY as provenance 'missing' with a null
--  value — NEVER omitted — so a checklist can state provenance ("DBS verified
--  01/06/2026") and a missing answer-blank is surfaced, never silently blank (§3).
--
--  Resolution order per field:
--    1. first-class `candidates` columns (identity)          -> self_declared
--    2. role joins (division/discipline/specialty)           -> derived
--    3. latest compliance_item per requirement `code`, picked verified-wins
--       (order by (status='verified') desc, updated_at desc) -> verified/derived
--    4. overlay `candidate_attributes` for any vocabulary key not yet satisfied
--       (dbs.number, rtw.share_code, training.<module>.expiry, …).
--  Plus a generic `item.<code>.{status,expires_at,verified_at,source_ref}` block
--  for EVERY seeded requirement code (sql/13 + sql/27).
-- ============================================================================

-- ── pp_field: the field-object constructor (auto-marks empty => 'missing') ───
-- Pure/immutable helper. If the value is null/blank the provenance is forced to
-- 'missing' regardless of the caller's guess, so "missing is explicit" is a table
-- stake, not a per-call responsibility.
create or replace function candidate.pp_field(
    p_value      text,
    p_provenance text default 'self_declared',
    p_as_at      date default null,
    p_source_ref text default null)
returns jsonb language sql immutable
set search_path = candidate, public as $$
  select jsonb_build_object(
    'value',      case when p_value is null or btrim(p_value) = '' then null else p_value end,
    'provenance', case when p_value is null or btrim(p_value) = '' then 'missing' else p_provenance end,
    'as_at',      p_as_at,
    'source_ref', p_source_ref);
$$;
revoke all on function candidate.pp_field(text, text, date, text) from public;
grant execute on function candidate.pp_field(text, text, date, text) to authenticated, service_role;

-- ── compliance_passport: resolve the whole vocabulary for one candidate ──────
create or replace function candidate.compliance_passport(p_candidate_id uuid)
returns jsonb language plpgsql stable security definer
set search_path = candidate, public as $$
declare
  v_c      candidate.candidates;
  v_div    text;
  v_disc   text;
  v_spec   text;
  v_items  jsonb := '{}'::jsonb;   -- code -> {status,expires_at,received_at,updated_at,source_ref,number}
  v_reg    jsonb;                  -- the registration item (nmc/gmc/hcpc), verified-wins
  v_dbs    jsonb;                  -- the DBS item (enhanced/adults/children), verified-wins
  v_rtw    jsonb;                  -- the right_to_work item
  v_oh     jsonb;
  v_immun  jsonb;
  v_train  jsonb;
  v_qual   jsonb;
  v_refs   jsonb;
  v_fields jsonb := '{}'::jsonb;
  v_code   text;
  r        record;
  v_seeded text[] := array[
    'cv','right_to_work','proof_of_address','references_3yr','overseas_police_check',
    'nmc_registration','gmc_registration','hcpc_registration','qualification_cert',
    'indemnity','dbs_enhanced','dbs_enhanced_adults','dbs_enhanced_children',
    'occupational_health','immunisations','mandatory_training','care_certificate',
    'cii_qualification','financial_reference','level5_diploma','fit_person_declaration'];
begin
  -- Fail-closed gate: officer (UI) OR the service_role (edge function). Never anon.
  if not ((candidate.is_authorized_user() and candidate.is_compliance_officer())
          or candidate.is_service_role()) then
    raise exception 'not authorized';
  end if;

  select * into v_c from candidate.candidates where id = p_candidate_id;
  if not found then
    raise exception 'candidate % not found', p_candidate_id;
  end if;

  -- Role via the division -> discipline -> specialty taxonomy.
  select di.name, dv.name, sp.name
    into v_disc, v_div, v_spec
  from candidate.candidates c
  left join candidate.disciplines di on di.id = c.discipline_id
  left join candidate.divisions   dv on dv.id = di.division_id
  left join candidate.specialties  sp on sp.id = c.primary_specialty_id
  where c.id = p_candidate_id;

  -- Latest compliance_item per requirement CODE, verified-wins (regardless of
  -- discipline — a code seeded per-discipline resolves to the candidate's actual
  -- held item). Same lateral tiebreak as recompute_candidate_status.
  for r in
    select distinct on (cr.code)
           cr.code   as code,
           ci.status as status,
           ci.expires_at,
           ci.received_at,
           ci.updated_at,
           ci.extracted
    from candidate.compliance_items ci
    join candidate.compliance_requirements cr on cr.id = ci.requirement_id
    where ci.candidate_id = p_candidate_id
    order by cr.code, (ci.status = 'verified') desc, ci.updated_at desc
  loop
    v_items := v_items || jsonb_build_object(r.code, jsonb_build_object(
      'status',      r.status,
      'expires_at',  r.expires_at,
      'received_at', r.received_at,
      'updated_at',  r.updated_at,
      'source_ref',  r.extracted->>'source_ref',
      'number',      r.extracted->>'registration_number'));
  end loop;

  -- Composite pickers: the verified one wins if more than one code is present.
  v_reg := (select e from (values (v_items->'nmc_registration'),
                                  (v_items->'gmc_registration'),
                                  (v_items->'hcpc_registration')) t(e)
            where e is not null order by (e->>'status' = 'verified') desc limit 1);
  v_dbs := (select e from (values (v_items->'dbs_enhanced'),
                                  (v_items->'dbs_enhanced_adults'),
                                  (v_items->'dbs_enhanced_children')) t(e)
            where e is not null order by (e->>'status' = 'verified') desc limit 1);
  v_rtw   := v_items->'right_to_work';
  v_oh    := v_items->'occupational_health';
  v_immun := v_items->'immunisations';
  v_train := v_items->'mandatory_training';
  v_qual  := v_items->'qualification_cert';
  v_refs  := v_items->'references_3yr';

  -- ── identity.* (first-class columns; candidate-provided => self_declared) ──
  v_fields := v_fields
    || jsonb_build_object('identity.first_name',     candidate.pp_field(v_c.first_name))
    || jsonb_build_object('identity.last_name',      candidate.pp_field(v_c.last_name))
    || jsonb_build_object('identity.full_name',      candidate.pp_field(
         nullif(btrim(concat_ws(' ', v_c.first_name, v_c.last_name)), ''), 'derived'))
    || jsonb_build_object('identity.known_as',       candidate.pp_field(v_c.known_as))
    || jsonb_build_object('identity.dob',            candidate.pp_field(v_c.dob::text))
    || jsonb_build_object('identity.email',          candidate.pp_field(v_c.email))
    || jsonb_build_object('identity.phone',          candidate.pp_field(v_c.phone))
    || jsonb_build_object('identity.town',           candidate.pp_field(v_c.town))
    || jsonb_build_object('identity.postcode',       candidate.pp_field(v_c.postcode))
    || jsonb_build_object('identity.region',         candidate.pp_field(v_c.region))
    || jsonb_build_object('identity.country',        candidate.pp_field(v_c.country))
    || jsonb_build_object('identity.address',        candidate.pp_field(v_c.address))
    || jsonb_build_object('identity.ni_number',      candidate.pp_field(v_c.ni_number))
    || jsonb_build_object('identity.nationality',    candidate.pp_field(v_c.nationality))
    || jsonb_build_object('identity.gender',         candidate.pp_field(v_c.gender))
    || jsonb_build_object('identity.place_of_birth', candidate.pp_field(v_c.place_of_birth));

  -- ── role.* (taxonomy joins => derived) ──
  v_fields := v_fields
    || jsonb_build_object('role.division',   candidate.pp_field(v_div,  'derived'))
    || jsonb_build_object('role.discipline', candidate.pp_field(v_disc, 'derived'))
    || jsonb_build_object('role.specialty',  candidate.pp_field(v_spec, 'derived'))
    -- no dedicated job_title column: seed from specialty (derived), overlay may refine.
    || jsonb_build_object('role.job_title',  candidate.pp_field(v_spec, 'derived'));

  -- ── reg.* (verified registration item wins over the self-declared column) ──
  v_fields := v_fields
    || jsonb_build_object('reg.body',
         candidate.pp_field(v_c.registration_body))
    || jsonb_build_object('reg.number',
         case when v_reg is not null and (v_reg->>'status') = 'verified' and (v_reg->>'number') is not null
              then candidate.pp_field(v_reg->>'number', 'verified',
                     (v_reg->>'received_at')::timestamptz::date, v_reg->>'source_ref')
              else candidate.pp_field(v_c.registration_number) end)
    || jsonb_build_object('reg.expiry',
         candidate.pp_field(nullif(v_reg->>'expires_at','')::timestamptz::date::text,
           case when (v_reg->>'status') = 'verified' then 'verified' else 'derived' end,
           null, v_reg->>'source_ref'))
    || jsonb_build_object('reg.verified',
         candidate.pp_field(case when (v_reg->>'status') = 'verified' then 'Yes' else 'No' end,
           'derived', (v_reg->>'received_at')::timestamptz::date, v_reg->>'source_ref'))
    || jsonb_build_object('reg.checked_at',
         candidate.pp_field((v_reg->>'received_at')::timestamptz::date::text, 'derived'))
    || jsonb_build_object('reg.source_ref',
         candidate.pp_field(v_reg->>'source_ref', 'verified'));

  -- ── dbs.* (number/level/issue_date come from candidate_attributes overlay) ──
  v_fields := v_fields
    || jsonb_build_object('dbs.number',         candidate.pp_field(null))  -- overlay fills
    || jsonb_build_object('dbs.level',          candidate.pp_field(null))
    || jsonb_build_object('dbs.issue_date',     candidate.pp_field(null))
    || jsonb_build_object('dbs.update_service', candidate.pp_field(null))
    || jsonb_build_object('dbs.verified',
         candidate.pp_field(case when (v_dbs->>'status') = 'verified' then 'Yes' else 'No' end,
           'derived', (v_dbs->>'received_at')::timestamptz::date, v_dbs->>'source_ref'));

  -- ── rtw.* (status self-declared, upgraded to verified when the item passes) ──
  v_fields := v_fields
    || jsonb_build_object('rtw.status',
         candidate.pp_field(v_c.right_to_work_status,
           case when (v_rtw->>'status') = 'verified' then 'verified' else 'self_declared' end,
           (v_rtw->>'received_at')::timestamptz::date, v_rtw->>'source_ref'))
    || jsonb_build_object('rtw.share_code', candidate.pp_field(null))  -- overlay fills
    || jsonb_build_object('rtw.method',     candidate.pp_field(null))
    || jsonb_build_object('rtw.expiry',
         candidate.pp_field(nullif(v_rtw->>'expires_at','')::timestamptz::date::text,
           case when (v_rtw->>'status') = 'verified' then 'verified' else 'derived' end))
    || jsonb_build_object('rtw.verified',
         candidate.pp_field(case when (v_rtw->>'status') = 'verified' then 'Yes' else 'No' end,
           'derived', (v_rtw->>'received_at')::timestamptz::date, v_rtw->>'source_ref'));

  -- ── refs.* / oh.* / immun.* / training.* / qual.* (item-derived) ──
  v_fields := v_fields
    || jsonb_build_object('refs.covered',
         candidate.pp_field(case when (v_refs->>'status') = 'verified' then 'Yes' else 'No' end, 'derived'))
    || jsonb_build_object('refs.years',  candidate.pp_field(null))   -- overlay fills
    || jsonb_build_object('refs.count',  candidate.pp_field(null))
    || jsonb_build_object('oh.status',
         candidate.pp_field(nullif(v_oh->>'status','not_started'),
           case when (v_oh->>'status') = 'verified' then 'verified' else 'derived' end))
    || jsonb_build_object('oh.date',
         candidate.pp_field((v_oh->>'received_at')::timestamptz::date::text, 'derived'))
    || jsonb_build_object('immun.status',
         candidate.pp_field(nullif(v_immun->>'status','not_started'),
           case when (v_immun->>'status') = 'verified' then 'verified' else 'derived' end))
    || jsonb_build_object('immun.date',
         candidate.pp_field((v_immun->>'received_at')::timestamptz::date::text, 'derived'))
    || jsonb_build_object('training.status',
         candidate.pp_field(nullif(v_train->>'status','not_started'),
           case when (v_train->>'status') = 'verified' then 'verified' else 'derived' end))
    || jsonb_build_object('training.expiry',
         candidate.pp_field(nullif(v_train->>'expires_at','')::timestamptz::date::text,
           case when (v_train->>'status') = 'verified' then 'verified' else 'derived' end))
    || jsonb_build_object('qual.name',   candidate.pp_field(null))   -- overlay fills
    || jsonb_build_object('qual.status',
         candidate.pp_field(nullif(v_qual->>'status','not_started'),
           case when (v_qual->>'status') = 'verified' then 'verified' else 'derived' end))
    || jsonb_build_object('qual.cert_date',
         candidate.pp_field((v_qual->>'received_at')::timestamptz::date::text, 'derived'));

  -- ── generic item.<code>.* block for EVERY seeded requirement code ──
  foreach v_code in array v_seeded loop
    v_fields := v_fields
      || jsonb_build_object('item.'||v_code||'.status',
           candidate.pp_field(nullif((v_items->v_code)->>'status','not_started'),
             case when ((v_items->v_code)->>'status') = 'verified' then 'verified' else 'derived' end,
             ((v_items->v_code)->>'updated_at')::timestamptz::date,
             (v_items->v_code)->>'source_ref'))
      || jsonb_build_object('item.'||v_code||'.expires_at',
           candidate.pp_field(nullif((v_items->v_code)->>'expires_at','')::timestamptz::date::text,
             case when ((v_items->v_code)->>'status') = 'verified' then 'verified' else 'derived' end,
             null, (v_items->v_code)->>'source_ref'))
      || jsonb_build_object('item.'||v_code||'.verified_at',
           candidate.pp_field(
             case when ((v_items->v_code)->>'status') = 'verified'
                  then ((v_items->v_code)->>'received_at')::timestamptz::date::text end,
             'verified', null, (v_items->v_code)->>'source_ref'))
      || jsonb_build_object('item.'||v_code||'.source_ref',
           candidate.pp_field((v_items->v_code)->>'source_ref', 'verified'));
  end loop;

  -- ── Overlay candidate_attributes for any key not satisfied by a column/item ─
  -- Fills a still-missing named field (dbs.number, rtw.share_code, qual.name, …)
  -- AND introduces brand-new long-tail keys (training.bls.expiry, …) with NO
  -- migration. Never overwrites an already-resolved (non-null) value.
  for r in
    select key, value, provenance, as_at, source_ref
    from candidate.candidate_attributes
    where candidate_id = p_candidate_id
  loop
    if (v_fields->r.key) is null or (v_fields->r.key->>'value') is null then
      v_fields := v_fields || jsonb_build_object(
        r.key, candidate.pp_field(r.value, r.provenance, r.as_at, r.source_ref));
    end if;
  end loop;

  return jsonb_build_object(
    'passport_version', 1,
    'candidate_id',     p_candidate_id,
    'generated_at',     now(),
    'fields',           v_fields);
end;
$$;
revoke all on function candidate.compliance_passport(uuid) from public;
grant execute on function candidate.compliance_passport(uuid) to authenticated, service_role;

-- ==== sql/44_checklist_templates.sql ====
-- ============================================================================
--  Day Webster — Candidate Pipeline · Client Checklist Auto-Fill (Phase 1)
--  File: candidate-pipeline/sql/44_checklist_templates.sql
--  Run AFTER 43b. Idempotent / additive.  STATUS: DRAFT — NOT YET APPLIED.
--
--  The reusable client-form library + the append-only fill audit (design §2).
--
--    · checklist_templates — one row per client form VERSION: the tokenized .docx
--      path + the token->passport-field map + per-template missing_policy. A form
--      is NEVER mutated in place — an edit makes a new `version` (existing fills
--      froze their template_version). Officers create/edit; only admins retire
--      (status='retired') / delete — enforced via RLS (the update WITH CHECK
--      blocks a non-admin flipping to 'retired'; DELETE is admin-only).
--
--    · checklist_fills — the immutable "we sent client X this exact file for
--      candidate Y on date Z" record. Has NO client INSERT/UPDATE/DELETE policy:
--      the ONLY writers are the SECURITY DEFINER RPCs below (which run as owner),
--      so a fill can never be forged or back-dated — the same un-forgeable pattern
--      as verification_events / compliance_breaches (sql/37/38/42).
--
--    · record_checklist_fill / mark_checklist_sent — service-or-officer gated
--      writers; the SENT transition is cross-linked into the verification_events
--      audit timeline (event_type='checklist_sent', widened below).
--
--  Storage: two PRIVATE buckets (checklist-templates, checklist-outputs). Buckets
--  are created at deploy time (see DEPLOY.md) — like `candidate-docs`, Supabase
--  bucket creation is an API/dashboard action, not SQL. The officer-read object
--  policies are added here but GUARDED so the migration still applies clean in a
--  bare Postgres harness that has no `storage` schema.
-- ============================================================================

-- ── Extend the append-only audit vocabulary with 'checklist_sent' ────────────
-- Drop-then-add keeps this idempotent; the new list is a strict SUPERSET of
-- sql/42's (keeps every override_*/breach_* verb) so no existing
-- verification_events row is ever invalidated.
alter table candidate.verification_events
  drop constraint if exists verification_events_event_type_check;
alter table candidate.verification_events
  add constraint verification_events_event_type_check
  check (event_type in ('verified','rejected','unsuitable','expired','waived',
         'reinstated','evidence_received','recheck_requested','status_recomputed',
         'override_granted','override_revoked',
         'breach_logged','breach_acknowledged','breach_resolved',
         'checklist_sent'));

-- ── checklist_templates: the reusable client form + token map ────────────────
create table if not exists candidate.checklist_templates (
  id             uuid primary key default gen_random_uuid(),
  client_name    text not null,
  client_ref     text,
  name           text not null,                          -- 'St Elsewhere NHS — Agency Worker Checklist'
  version        int  not null default 1,
  status         text not null default 'draft'
                 check (status in ('draft','active','retired')),
  bucket         text not null default 'checklist-templates',
  template_path  text not null,                          -- tokenized .docx in Storage
  original_path  text,                                   -- untouched original (audit / re-tokenize)
  field_map      jsonb not null default '[]'::jsonb,     -- [{token, field|static, required, transform}]
  static_answers jsonb not null default '{}'::jsonb,     -- constant answers (agency name, PAYE ref…)
  missing_policy text not null default 'block'
                 check (missing_policy in ('block','annotate')),
  discipline_id  uuid references candidate.disciplines(id) on delete set null,
  created_by     uuid references auth.users(id) on delete set null,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (client_name, name, version)
);
create index if not exists checklist_templates_status_idx
  on candidate.checklist_templates (status);
create index if not exists checklist_templates_client_idx
  on candidate.checklist_templates (client_name);

drop trigger if exists checklist_templates_set_updated_at on candidate.checklist_templates;
create trigger checklist_templates_set_updated_at
  before update on candidate.checklist_templates
  for each row execute function candidate.set_updated_at();

-- ── checklist_fills: the append-only fill/send audit record ──────────────────
create table if not exists candidate.checklist_fills (
  id               uuid primary key default gen_random_uuid(),
  candidate_id     uuid not null references candidate.candidates(id) on delete cascade,
  template_id      uuid not null references candidate.checklist_templates(id) on delete restrict,
  template_version int  not null,                        -- frozen: which version was used
  bucket           text not null default 'checklist-outputs',
  output_path      text not null,                        -- generated .docx
  values_snapshot  jsonb not null,                       -- frozen passport values actually merged
  missing_fields   jsonb not null default '[]'::jsonb,   -- fields empty/needs-attention at fill time
  status           text not null default 'generated'
                   check (status in ('generated','needs_attention','sent')),
  generated_by     uuid references auth.users(id) on delete set null,
  generated_at     timestamptz not null default now(),
  sent_at          timestamptz,
  sent_by          uuid references auth.users(id) on delete set null
);
create index if not exists checklist_fills_candidate_idx
  on candidate.checklist_fills (candidate_id, generated_at desc);
create index if not exists checklist_fills_template_idx
  on candidate.checklist_fills (template_id);
create index if not exists checklist_fills_status_idx
  on candidate.checklist_fills (status);

-- ── RLS ─────────────────────────────────────────────────────────────────────
alter table candidate.checklist_templates enable row level security;
alter table candidate.checklist_fills     enable row level security;

-- Templates: officers read/create/edit; only admins retire (status='retired') or
-- delete. is_compliance_officer() already folds in is_admin, so admins are
-- covered by the officer policies for read/create/edit.
drop policy if exists "officer read templates"   on candidate.checklist_templates;
drop policy if exists "officer insert templates" on candidate.checklist_templates;
drop policy if exists "officer update templates" on candidate.checklist_templates;
drop policy if exists "admin delete templates"   on candidate.checklist_templates;

create policy "officer read templates" on candidate.checklist_templates
  for select to authenticated
  using (candidate.is_authorized_user() and candidate.is_compliance_officer());
create policy "officer insert templates" on candidate.checklist_templates
  for insert to authenticated
  with check (candidate.is_authorized_user() and candidate.is_compliance_officer());
-- Officers may edit drafts/active forms and activate them, but ONLY an admin may
-- flip a form to 'retired' (the WITH CHECK blocks a non-admin doing so).
create policy "officer update templates" on candidate.checklist_templates
  for update to authenticated
  using (candidate.is_authorized_user() and candidate.is_compliance_officer())
  with check (candidate.is_authorized_user() and candidate.is_compliance_officer()
              and (status <> 'retired' or candidate.is_admin()));
create policy "admin delete templates" on candidate.checklist_templates
  for delete to authenticated
  using (candidate.is_authorized_user() and candidate.is_admin());

-- Fills: officers READ only. NO insert/update/delete policy => not client-writable;
-- every write is via the SECURITY DEFINER RPCs below (un-forgeable audit).
drop policy if exists "officer read fills" on candidate.checklist_fills;
create policy "officer read fills" on candidate.checklist_fills
  for select to authenticated
  using (candidate.is_authorized_user() and candidate.is_compliance_officer());

grant select, insert, update, delete on candidate.checklist_templates to authenticated;
grant select on candidate.checklist_fills to authenticated;   -- writes are RPC-only

-- ── Storage object policies (officer read; service writes bypass RLS) ────────
-- Guarded: only run where the Supabase `storage.objects` table exists, so a bare
-- Postgres migration harness (no storage schema) applies this file clean. Bucket
-- CREATION is a deploy-time API action (see DEPLOY.md).
do $$
begin
  if to_regclass('storage.objects') is not null then
    execute $p$drop policy if exists "officer read checklist objects" on storage.objects$p$;
    execute $p$
      create policy "officer read checklist objects" on storage.objects
        for select to authenticated
        using (bucket_id in ('checklist-templates','checklist-outputs')
               and candidate.is_authorized_user() and candidate.is_compliance_officer())
    $p$;
    -- No INSERT/UPDATE/DELETE policy for authenticated: writes are performed by
    -- the service_role edge function, which bypasses storage RLS entirely.
  end if;
end $$;

-- ── record_checklist_fill: the ONLY writer of a fill row (service-or-officer) ─
-- Freezes template_version from the template, inserts the immutable fill record,
-- and — when the fill is created already 'sent' — stamps sent_at/sent_by and
-- cross-links a 'checklist_sent' audit event (so a SENT checklist is ALWAYS
-- audited exactly once, whichever path created it). A 'generated'/'needs_attention'
-- fill writes no audit verb; the send is audited later in mark_checklist_sent.
create or replace function candidate.record_checklist_fill(
    p_candidate_id    uuid,
    p_template_id     uuid,
    p_output_path     text,
    p_values_snapshot jsonb,
    p_missing_fields  jsonb default '[]'::jsonb,
    p_status          text  default 'generated')
returns uuid language plpgsql security definer
set search_path = candidate, public as $$
declare
  v_is_service boolean := candidate.is_service_role();
  v_actor      uuid    := auth.uid();
  v_tv         int;
  v_id         uuid;
begin
  if not ((candidate.is_authorized_user() and candidate.is_compliance_officer()) or v_is_service) then
    raise exception 'not authorized';
  end if;
  if p_status not in ('generated','needs_attention','sent') then
    raise exception 'invalid status: %', p_status;
  end if;
  if p_output_path is null or btrim(p_output_path) = '' then
    raise exception 'output_path is required';
  end if;

  select version into v_tv
  from candidate.checklist_templates where id = p_template_id;
  if not found then
    raise exception 'checklist template % not found', p_template_id;
  end if;

  insert into candidate.checklist_fills
    (candidate_id, template_id, template_version, output_path, values_snapshot,
     missing_fields, status, generated_by, sent_at, sent_by)
  values
    (p_candidate_id, p_template_id, v_tv, p_output_path, p_values_snapshot,
     coalesce(p_missing_fields, '[]'::jsonb), p_status, v_actor,
     case when p_status = 'sent' then now() end,
     case when p_status = 'sent' then v_actor end)
  returning id into v_id;

  -- A checklist created directly as 'sent' must still hit the audit timeline.
  if p_status = 'sent' then
    insert into candidate.verification_events
      (candidate_id, event_type, method, source_ref, notes, actor, actor_kind)
    values
      (p_candidate_id, 'checklist_sent',
       case when v_is_service then 'system' else 'human' end,
       v_id::text,
       format('client checklist sent (template v%s)', v_tv),
       v_actor, case when v_is_service then 'service' else 'human' end);
  end if;

  return v_id;
end;
$$;
revoke all on function candidate.record_checklist_fill(uuid, uuid, text, jsonb, jsonb, text) from public;
grant execute on function candidate.record_checklist_fill(uuid, uuid, text, jsonb, jsonb, text) to authenticated, service_role;

-- ── mark_checklist_sent: officer flips a fill to 'sent' + audits it ──────────
-- Refuses to send a 'needs_attention' fill (a compliance answer-blank is never
-- silently empty) UNLESS an admin explicitly overrides. Idempotent: a second call
-- on an already-sent fill is a no-op (no duplicate audit row).
create or replace function candidate.mark_checklist_sent(
    p_fill_id  uuid,
    p_override boolean default false)
returns void language plpgsql security definer
set search_path = candidate, public as $$
declare
  v_f candidate.checklist_fills;
begin
  if not (candidate.is_authorized_user() and candidate.is_compliance_officer()) then
    raise exception 'not authorized';
  end if;

  select * into v_f from candidate.checklist_fills where id = p_fill_id for update;
  if not found then
    raise exception 'checklist fill % not found', p_fill_id;
  end if;
  if v_f.status = 'sent' then
    return;                                    -- already sent: idempotent no-op
  end if;
  if v_f.status = 'needs_attention' and not (p_override and candidate.is_admin()) then
    raise exception 'checklist % needs attention — an admin override is required to send it', p_fill_id;
  end if;

  update candidate.checklist_fills
    set status = 'sent', sent_at = now(), sent_by = auth.uid()
    where id = p_fill_id;

  insert into candidate.verification_events
    (candidate_id, event_type, method, source_ref, notes, actor, actor_kind)
  values
    (v_f.candidate_id, 'checklist_sent', 'human', p_fill_id::text,
     format('client checklist marked sent%s',
            case when v_f.status = 'needs_attention' then ' (admin override — was needs_attention)' else '' end),
     auth.uid(), 'human');
end;
$$;
revoke all on function candidate.mark_checklist_sent(uuid, boolean) from public;
grant execute on function candidate.mark_checklist_sent(uuid, boolean) to authenticated;

-- ==== sql/45_compliance_manager_role.sql ====
-- ============================================================================
--  Day Webster — Candidate Pipeline · Compliance Manager role
--  File: candidate-pipeline/sql/45_compliance_manager_role.sql
--  Run AFTER 18 (staff/is_admin) and 22 (is_compliance/is_compliance_officer).
--  Idempotent / additive.  STATUS: DRAFT — NOT YET APPLIED.
--
--  Introduces the THIRD compliance tier. Until now staff carried two capability
--  flags: is_compliance (an OFFICER — owns their own candidates) and is_admin
--  (everything). This adds is_manager (a COMPLIANCE MANAGER — sees ALL compliance
--  data holistically + manager-only actions), sitting between officer and admin.
--
--  Tiers (for the Role-Scoped Compliance Chat, see 46):
--    · Compliance Officer  (is_compliance)         -> own candidates only
--    · Compliance Manager  (is_manager)            -> ALL compliance data
--    · Admin               (is_admin)              -> everything (a manager too)
--
--  There is deliberately NO team/overseer tier for chat scope: a manager sees
--  the WHOLE bench, not just direct reports.
--
--  This role is reusable (training engine etc. will lean on is_manager() too), so
--  it lives in its own additive migration rather than inside the chat file.
-- ============================================================================

-- ── Manager capability flag (mirrors staff.is_admin from 18, is_compliance from 22)
alter table candidate.staff
  add column if not exists is_manager boolean not null default false;

-- ── is_manager(): is the caller a compliance manager (or admin)? ─────────────
-- Mirrors is_admin()'s shape exactly, including the same bootstrap-allow posture
-- (no staff rows yet => treat as manager so the first sign-in isn't locked out).
-- Admins are managers too (is_manager OR is_admin).
create or replace function candidate.is_manager()
returns boolean language sql stable security definer
set search_path = candidate, public as $$
  select coalesce(
    (select (s.is_manager or s.is_admin)
       from candidate.staff s where s.user_id = auth.uid()),
    not exists (select 1 from candidate.staff)   -- bootstrap: no staff yet => allow
  );
$$;
revoke all on function candidate.is_manager() from public;
grant execute on function candidate.is_manager() to authenticated;

-- ── Widen is_compliance_officer() to include managers ────────────────────────
-- A compliance manager can do everything an officer can, so they must satisfy the
-- officer capability gate that governs the existing RLS/RPCs. Same signature as
-- 22; create-or-replace so this file can re-run. Widening is safe: it only ever
-- ADDS managers/admins to the set of officers (they already were, via is_admin).
create or replace function candidate.is_compliance_officer()
returns boolean language sql stable security definer
set search_path = candidate, public as $$
  select coalesce(
    (select (s.is_compliance or s.is_manager or s.is_admin)
       from candidate.staff s where s.user_id = auth.uid()),
    not exists (select 1 from candidate.staff)   -- bootstrap: no staff yet => allow
  );
$$;
grant execute on function candidate.is_compliance_officer() to authenticated;

-- ==== sql/46_compliance_chat.sql ====
-- ============================================================================
--  Day Webster — Candidate Pipeline · Role-Scoped Compliance AI Chat (v1)
--  File: candidate-pipeline/sql/46_compliance_chat.sql
--  Run AFTER 34/36/41/42 (officer col + reporting views + ladder + breaches) and
--  45 (is_manager/is_compliance_officer). Idempotent / additive.
--  STATUS: DRAFT — NOT YET APPLIED.
--
--  See candidate-pipeline/COMPLIANCE_CHAT_DESIGN.md §2–3. The chat AI answers ONLY
--  from a fixed set of read-only, SCOPE-SAFE tools. The entire security model
--  rests on one property: the officer-id set a query filters on is computed
--  SERVER-SIDE from auth.uid() (chat_scope()), never from a model-supplied arg.
--
--  Scope (two tiers for chat — see 45):
--    · officer (is_compliance)             -> strictly their OWN candidates
--    · manager/admin (is_manager/is_admin) -> ALL candidates (all_access)
--  Unassigned candidates (compliance_officer is null) match no officer id, so
--  ONLY all_access callers ever see them.  [DECISION S3]
--
--  Why NEW thin wrappers instead of the existing reporting RPCs: the existing
--  compliance_officer_report / compliance_breach_report / compliance_dashboard
--  accept an ARBITRARY officer id and are gated only by is_compliance_officer() —
--  i.e. any officer can read the whole bench through them. They are leak vectors
--  and are NEVER called by the chat. These wrappers add a scope WHERE clause
--  derived from auth.uid() over the SAME underlying views (no new business logic).
--
--  Every RPC below: SECURITY DEFINER (runs as owner => RLS bypassed => it reads
--  the whole bench, then RE-APPLIES scope by hand) + the is_authorized_user() and
--  is_compliance_officer() gate + revoke-from-public + grant-to-authenticated.
-- ============================================================================

-- ── The scope resolver: no args, reads auth.uid() internally => unspoofable ───
-- all_access = manager/admin.  Otherwise officer_ids = {auth.uid()} (self only).
-- A model can NEVER influence this; it takes no parameters.
create or replace function candidate.chat_scope()
returns table(all_access boolean, officer_ids uuid[])
language sql stable security definer
set search_path = candidate, public as $$
  select
    candidate.is_manager(),
    case when candidate.is_manager() then null::uuid[]
         else array[auth.uid()] end;
$$;
revoke all on function candidate.chat_scope() from public;
grant execute on function candidate.chat_scope() to authenticated;

-- ── 1. chat_stats_in_scope(): pipeline RAG counts ───────────────────────────
create or replace function candidate.chat_stats_in_scope()
returns table(in_pipeline int, red int, amber int, green int)
language plpgsql stable security definer
set search_path = candidate, public as $$
declare v_all boolean; v_ids uuid[];
begin
  if not (candidate.is_authorized_user() and candidate.is_compliance_officer()) then
    raise exception 'not authorized';
  end if;
  select s.all_access, s.officer_ids into v_all, v_ids from candidate.chat_scope() s;

  return query
    select count(*)::int,
           count(*) filter (where os.overall_rag = 'red')::int,
           count(*) filter (where os.overall_rag = 'amber')::int,
           count(*) filter (where os.overall_rag = 'green')::int
    from candidate.candidate_overall_status os
    where (v_all or os.compliance_officer = any(v_ids));
end;
$$;
revoke all on function candidate.chat_stats_in_scope() from public;
grant execute on function candidate.chat_stats_in_scope() to authenticated;

-- ── 2. chat_urgent_in_scope(p_limit): the attention queue ────────────────────
-- Union of open breaches (rank 1), red/blocking incl. EXPIRED blocking items
-- (rank 2), and needs-human review (rank 3). p_limit clamped 1..50. Expired
-- blocking items surface as 'red' (recompute counts an expired verified doc as a
-- blocking gap), so there is no separate "expired" source to double-count.
create or replace function candidate.chat_urgent_in_scope(p_limit int default 25)
returns table(candidate_id uuid, candidate_name text, discipline text,
              reason text, severity text, detail text, rank int)
language plpgsql stable security definer
set search_path = candidate, public as $$
declare v_all boolean; v_ids uuid[]; v_limit int;
begin
  if not (candidate.is_authorized_user() and candidate.is_compliance_officer()) then
    raise exception 'not authorized';
  end if;
  select s.all_access, s.officer_ids into v_all, v_ids from candidate.chat_scope() s;
  v_limit := least(greatest(coalesce(p_limit, 25), 1), 50);

  return query
  with scoped_wl as (
    select w.candidate_id,
           (w.first_name || ' ' || w.last_name) as candidate_name,
           w.discipline_name,
           max(w.blocking_open)          as blocking_open,
           coalesce(sum(w.needs_human_count), 0) as needs_human,
           bool_or(w.status = 'red')     as any_red,
           min(w.next_expiry)            as next_expiry
    from candidate.compliance_worklist w
    where (v_all or w.compliance_officer = any(v_ids))
    group by w.candidate_id, candidate_name, w.discipline_name
  ),
  scoped_breach as (
    select b.candidate_id, b.candidate_name, b.discipline_name, count(*) as n
    from candidate.open_breaches b
    where (v_all or b.compliance_officer = any(v_ids))
    group by b.candidate_id, b.candidate_name, b.discipline_name
  ),
  urgent as (
    select b.candidate_id, b.candidate_name, b.discipline_name as discipline,
           'open_breach'::text as reason, 'critical'::text as severity,
           (b.n || ' open breach(es)')::text as detail, 1 as rnk,
           null::timestamptz as ord_expiry
    from scoped_breach b
    union all
    select w.candidate_id, w.candidate_name, w.discipline_name,
           'blocking', 'red',
           (coalesce(w.blocking_open, 0) || ' blocking item(s) unmet or expired'),
           2, w.next_expiry
    from scoped_wl w where w.any_red
    union all
    select w.candidate_id, w.candidate_name, w.discipline_name,
           'needs_human', 'amber',
           (w.needs_human || ' item(s) awaiting human review'),
           3, w.next_expiry
    from scoped_wl w where w.needs_human > 0 and not w.any_red
  )
  select u.candidate_id, u.candidate_name, u.discipline, u.reason, u.severity, u.detail, u.rnk
  from urgent u
  order by u.rnk, u.ord_expiry nulls last
  limit v_limit;
end;
$$;
revoke all on function candidate.chat_urgent_in_scope(int) from public;
grant execute on function candidate.chat_urgent_in_scope(int) to authenticated;

-- ── 3. chat_expiring_in_scope(p_days): documents expiring in a window ────────
-- The due_expiry_reminders "latest verified item per (candidate,requirement)"
-- pattern, restricted to a future window (p_days clamped 1..180) + officer scope.
create or replace function candidate.chat_expiring_in_scope(p_days int default 30)
returns table(candidate_id uuid, candidate_name text, requirement_code text,
              requirement_name text, expires_at timestamptz, days_left int)
language plpgsql stable security definer
set search_path = candidate, public as $$
declare v_all boolean; v_ids uuid[]; v_days int;
begin
  if not (candidate.is_authorized_user() and candidate.is_compliance_officer()) then
    raise exception 'not authorized';
  end if;
  select s.all_access, s.officer_ids into v_all, v_ids from candidate.chat_scope() s;
  v_days := least(greatest(coalesce(p_days, 30), 1), 180);

  return query
  with current_item as (
    select distinct on (ci.candidate_id, ci.requirement_id)
      ci.candidate_id, ci.requirement_id, ci.status, ci.expires_at,
      cr.code as requirement_code, cr.name as requirement_name
    from candidate.compliance_items ci
    join candidate.candidate_requirement_sets crs
      on crs.candidate_id = ci.candidate_id and crs.active
    join candidate.requirement_set_items rsi
      on rsi.set_id = crs.set_id and rsi.requirement_id = ci.requirement_id
    join candidate.compliance_requirements cr on cr.id = ci.requirement_id
    where coalesce(rsi.criticality, cr.criticality) in ('blocking','standard')
      and coalesce(rsi.required_override, cr.required)
    order by ci.candidate_id, ci.requirement_id,
             (ci.status = 'verified') desc, ci.updated_at desc
  )
  select c.id,
         (c.first_name || ' ' || c.last_name),
         ci.requirement_code, ci.requirement_name, ci.expires_at,
         greatest(0, ceil(extract(epoch from (ci.expires_at - now())) / 86400.0))::int
  from current_item ci
  join candidate.candidates c on c.id = ci.candidate_id
  where ci.status = 'verified'
    and ci.expires_at is not null
    and ci.expires_at > now()
    and ci.expires_at <= now() + make_interval(days => v_days)
    and (v_all or c.compliance_officer = any(v_ids))
  order by ci.expires_at
  limit 200;
end;
$$;
revoke all on function candidate.chat_expiring_in_scope(int) from public;
grant execute on function candidate.chat_expiring_in_scope(int) to authenticated;

-- ── 4. chat_breach_summary_in_scope(): the breach headline ───────────────────
create or replace function candidate.chat_breach_summary_in_scope()
returns table(open_breaches int, candidates_working_noncompliant int)
language plpgsql stable security definer
set search_path = candidate, public as $$
declare v_all boolean; v_ids uuid[];
begin
  if not (candidate.is_authorized_user() and candidate.is_compliance_officer()) then
    raise exception 'not authorized';
  end if;
  select s.all_access, s.officer_ids into v_all, v_ids from candidate.chat_scope() s;

  return query
    select count(*)::int,
           count(distinct b.candidate_id)
             filter (where b.shift_date >= current_date)::int
    from candidate.open_breaches b
    where (v_all or b.compliance_officer = any(v_ids));
end;
$$;
revoke all on function candidate.chat_breach_summary_in_scope() from public;
grant execute on function candidate.chat_breach_summary_in_scope() to authenticated;

-- ── 5. chat_workready_in_scope(): both senses, so "work-ready" is unambiguous ─
-- fully_compliant = green only (per compliance_exec_overview's "green = ready");
-- placeable       = green+amber (matches the booking gate is_work_ready(), which
--                   treats amber as placeable-with-caveat / bookable);
-- not_ready       = red (blocked, not bookable).
create or replace function candidate.chat_workready_in_scope()
returns table(fully_compliant int, placeable int, not_ready int)
language plpgsql stable security definer
set search_path = candidate, public as $$
declare v_all boolean; v_ids uuid[];
begin
  if not (candidate.is_authorized_user() and candidate.is_compliance_officer()) then
    raise exception 'not authorized';
  end if;
  select s.all_access, s.officer_ids into v_all, v_ids from candidate.chat_scope() s;

  return query
    select count(*) filter (where os.overall_rag = 'green')::int,
           count(*) filter (where os.overall_rag in ('green','amber'))::int,
           count(*) filter (where os.overall_rag = 'red')::int
    from candidate.candidate_overall_status os
    where (v_all or os.compliance_officer = any(v_ids));
end;
$$;
revoke all on function candidate.chat_workready_in_scope() from public;
grant execute on function candidate.chat_workready_in_scope() to authenticated;

-- ── 6. chat_candidate_lookup_in_scope(p_query): 0-or-1 row, no existence leak ─
-- Out-of-scope OR unknown => ZERO rows, identically (the scope WHERE clause makes
-- an out-of-scope candidate indistinguishable from a non-existent one). An empty
-- query also returns nothing.
create or replace function candidate.chat_candidate_lookup_in_scope(p_query text)
returns table(candidate_id uuid, candidate_name text, discipline text,
              overall_rag text, active_sets int, open_breaches int,
              next_expiry timestamptz)
language plpgsql stable security definer
set search_path = candidate, public as $$
declare v_all boolean; v_ids uuid[]; v_q text;
begin
  if not (candidate.is_authorized_user() and candidate.is_compliance_officer()) then
    raise exception 'not authorized';
  end if;
  v_q := btrim(coalesce(p_query, ''));
  if v_q = '' then
    return;                                   -- empty query => zero rows
  end if;
  select s.all_access, s.officer_ids into v_all, v_ids from candidate.chat_scope() s;

  return query
    select os.candidate_id,
           (c.first_name || ' ' || c.last_name),
           d.name,
           os.overall_rag,
           os.active_set_count::int,
           (select count(*)::int from candidate.open_breaches b
             where b.candidate_id = os.candidate_id),
           (select min(st.next_expiry) from candidate.candidate_compliance_status st
             where st.candidate_id = os.candidate_id)
    from candidate.candidate_overall_status os
    join candidate.candidates c on c.id = os.candidate_id
    left join candidate.disciplines d on d.id = os.discipline_id
    where (v_all or os.compliance_officer = any(v_ids))
      and ((c.first_name || ' ' || c.last_name) ilike '%' || v_q || '%'
           or c.email ilike '%' || v_q || '%')
    order by (lower(c.first_name || ' ' || c.last_name) = lower(v_q)) desc,
             c.last_name, c.first_name
    limit 1;
end;
$$;
revoke all on function candidate.chat_candidate_lookup_in_scope(text) from public;
grant execute on function candidate.chat_candidate_lookup_in_scope(text) to authenticated;

-- ── 7. chat_officer_breakdown_in_scope(p_division): per-officer RAG — managers ─
-- MANAGER-ONLY (raises for a plain officer). Officer names are STAFF data, not
-- candidate PII, so this is allowed even in aggregate PII mode. p_division only
-- NARROWS within the already-full-bench manager scope; it can never widen.
create or replace function candidate.chat_officer_breakdown_in_scope(p_division uuid default null)
returns table(officer uuid, officer_name text, red int, amber int, green int)
language plpgsql stable security definer
set search_path = candidate, public as $$
declare v_all boolean; v_ids uuid[];
begin
  if not (candidate.is_authorized_user() and candidate.is_compliance_officer()) then
    raise exception 'not authorized';
  end if;
  if not candidate.is_manager() then
    raise exception 'not authorized: officer breakdown is manager-only';
  end if;
  select s.all_access, s.officer_ids into v_all, v_ids from candidate.chat_scope() s;

  return query
    select os.compliance_officer,
           coalesce(st.full_name, au.email, os.compliance_officer::text),
           count(*) filter (where os.overall_rag = 'red')::int,
           count(*) filter (where os.overall_rag = 'amber')::int,
           count(*) filter (where os.overall_rag = 'green')::int
    from candidate.candidate_overall_status os
    left join candidate.staff     st on st.user_id = os.compliance_officer
    left join candidate.app_users au on au.user_id = os.compliance_officer
    where (v_all or os.compliance_officer = any(v_ids))
      and (p_division is null or os.division_id = p_division)
    group by os.compliance_officer,
             coalesce(st.full_name, au.email, os.compliance_officer::text);
end;
$$;
revoke all on function candidate.chat_officer_breakdown_in_scope(uuid) from public;
grant execute on function candidate.chat_officer_breakdown_in_scope(uuid) to authenticated;

-- ============================================================================
--  Audit — every question is logged (append-only). The log stores tool NAMES +
--  INPUTS + ROW-COUNTS only, never candidate rows, so it is not a second copy of
--  confidential data.
-- ============================================================================
create table if not exists candidate.compliance_chat_log (
  id            uuid primary key default gen_random_uuid(),
  actor         uuid references auth.users(id) on delete set null,
  actor_email   text,
  role_scope    text not null,                         -- 'officer' | 'manager' | 'admin'
  pii_mode      text not null,                         -- 'identifying' | 'aggregate'
  question      text not null,
  tools_called  jsonb not null default '[]',           -- [{name, input, row_count}] — NO rows
  answer        text,
  input_tokens  int,
  output_tokens int,
  model         text,
  created_at    timestamptz not null default now()
);
create index if not exists compliance_chat_log_actor_idx
  on candidate.compliance_chat_log (actor, created_at desc);

-- ── RLS: officer reads OWN rows; manager/admin reads all; no client write ────
alter table candidate.compliance_chat_log enable row level security;
drop policy if exists "chat_log read own or manager" on candidate.compliance_chat_log;
create policy "chat_log read own or manager" on candidate.compliance_chat_log
  for select to authenticated
  using (candidate.is_authorized_user()
         and (actor = auth.uid() or candidate.is_manager()));
-- No INSERT/UPDATE/DELETE policy: append-only; the SECURITY DEFINER writer below
-- (owned by the schema owner => RLS-exempt) is the SOLE writer. No write grant.
grant select on candidate.compliance_chat_log to authenticated;

-- ── log_compliance_chat(): the sole writer ───────────────────────────────────
create or replace function candidate.log_compliance_chat(
    p_role_scope    text,
    p_pii_mode      text,
    p_question      text,
    p_tools_called  jsonb default '[]',
    p_answer        text default null,
    p_input_tokens  int  default null,
    p_output_tokens int  default null,
    p_model         text default null)
returns uuid language plpgsql security definer
set search_path = candidate, public as $$
declare v_id uuid;
begin
  if not (candidate.is_authorized_user() and candidate.is_compliance_officer()) then
    raise exception 'not authorized';
  end if;

  insert into candidate.compliance_chat_log
    (actor, actor_email, role_scope, pii_mode, question, tools_called,
     answer, input_tokens, output_tokens, model)
  values
    (auth.uid(), lower(auth.jwt() ->> 'email'), p_role_scope, p_pii_mode, p_question,
     coalesce(p_tools_called, '[]'::jsonb), p_answer, p_input_tokens, p_output_tokens, p_model)
  returning id into v_id;

  return v_id;
end;
$$;
revoke all on function candidate.log_compliance_chat(text, text, text, jsonb, text, int, int, text) from public;
grant execute on function candidate.log_compliance_chat(text, text, text, jsonb, text, int, int, text) to authenticated;

-- ==== sql/47_training_catalogue.sql ====
-- ============================================================================
--  Day Webster — Candidate Pipeline · Mandatory Training: module catalogue
--  File: candidate-pipeline/sql/47_training_catalogue.sql
--  Run AFTER 10–46 (needs 13/24/27 requirement sets, 22 verification_events,
--  23/25 recompute gate, 45 is_manager()).  Idempotent / additive.
--  STATUS: DRAFT — NOT YET APPLIED.
--
--  Round 1 of the Mandatory-Training engine (SQL backbone). This file is the
--  CATALOGUE: the module table + the 1:1 mapping into compliance_requirements
--  that lets a completion produce a verified, expiring compliance_item the gate
--  (23/25) and the pre-expiry ladder (41) already know how to consume.
--
--  Framework decision (confirmed): WFA RM6281 "Clinical & Healthcare Staffing".
--  The 11 core CSTF subjects seed at their CLINICAL levels (IPC L2, Moving &
--  Handling L2, Adult BLS L2, Safeguarding Adults/Children) and are wired
--  BLOCKING into the clinical requirement sets; the statutory/optional extras
--  (Oliver McGowan Tier 2, MCA & DoLS, Sepsis) wire in non-blocking.
--
--  ── ACCREDITATION HONESTY NOTE (read before touching sfh_accreditation_ref) ──
--  `sfh_accreditation_ref` is a value we STORE and RENDER (on certificates and in
--  the catalogue). Storing it does NOT make the content accredited. Skills for
--  Health accreditation of any Day Webster module is the agency's own business /
--  legal fact, obtained out-of-band. The system RECORDS and DISPLAYS it; it never
--  fabricates accreditation it was not given. It seeds NULL; a manager populates
--  it once real accreditation is confirmed. Likewise every validity_months /
--  level here is an EDITABLE DEFAULT reconstructed from CSTF norms
--  (TRAINING_CSTF_RESEARCH.md) that a named SME confirms before it is treated as
--  authoritative.
--
--  CI1 (load-bearing): recompute_candidate_status (25) and due_expiry_reminders
--  (41) both resolve ONE latest item per requirement. So each module maps 1:1 to
--  its OWN compliance_requirement (training_modules.requirement_code) — never
--  many sub-items under the one legacy `mandatory_training` requirement, which
--  the gate would silently collapse to one. The legacy monolith is demoted to
--  advisory below so it cannot double-count.
-- ============================================================================

-- ── The module catalogue ────────────────────────────────────────────────────
create table if not exists candidate.training_modules (
  id                 uuid primary key default gen_random_uuid(),
  code               text not null unique,           -- 'moving_handling_l2','ipc_l2','bls_adult_l2'
  title              text not null,
  framework          text,                           -- 'CSTF'
  framework_subject  text,                           -- 'Moving and Handling (Level 2)'
  sfh_accreditation_ref text,                        -- Skills for Health ref — stored, NOT asserted (see header)
  validity_months    int  not null default 12 check (validity_months > 0),
  pass_threshold     numeric not null default 75 check (pass_threshold between 0 and 100),
  question_count     int  not null default 10 check (question_count > 0),
  delivery_mode      text not null default 'elearning'
                     check (delivery_mode in ('elearning','blended','face_to_face')),
  face_to_face       boolean not null default false, -- future-proofs HTE's annual face-to-face rule
  requirement_code   text not null unique,           -- 1:1 into compliance_requirements (CI1)
  -- How this module wires into the clinical requirement sets (SME-tunable via
  -- requirement_set_items override): core CSTF = blocking, extras = standard.
  set_criticality    text not null default 'blocking'
                     check (set_criticality in ('blocking','standard','advisory')),
  is_core            boolean not null default true,  -- true = one of the 11 core CSTF subjects
  current_version_id uuid,                            -- the PUBLISHED version; null until first publish (FK added in 48)
  status             text not null default 'active' check (status in ('active','retired')),
  created_by         uuid references auth.users(id) on delete set null,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
create index if not exists training_modules_status_idx on candidate.training_modules (status);

drop trigger if exists training_modules_set_updated_at on candidate.training_modules;
create trigger training_modules_set_updated_at
  before update on candidate.training_modules
  for each row execute function candidate.set_updated_at();

-- ── CI1 mirror: every module owns exactly one compliance_requirement ─────────
-- A training_module row is the source of truth; its requirement is kept in sync
-- by this trigger (global scope: discipline_id/specialty_id NULL). This is what
-- makes "one requirement per subject" automatic — seeding a module (52) creates
-- its requirement; retiring a module deactivates it. The null-collapsing unique
-- index from 13 is the conflict target so re-runs are true no-ops.
create or replace function candidate.trg_training_module_requirement()
returns trigger language plpgsql security definer
set search_path = candidate, public as $$
begin
  insert into candidate.compliance_requirements
    (discipline_id, specialty_id, code, name, tier, required, expiry_rule,
     needs_human, notes, sort_order, active, criticality)
  values
    (null, null, new.requirement_code, new.title, 'A', true, null,
     false, 'Mandatory training module (see candidate.training_modules)', 100,
     new.status = 'active', new.set_criticality)
  on conflict (coalesce(discipline_id, '00000000-0000-0000-0000-000000000000'::uuid),
               coalesce(specialty_id,  '00000000-0000-0000-0000-000000000000'::uuid),
               code)
  do update set name        = excluded.name,
                active       = excluded.active,
                criticality  = excluded.criticality;
  return new;
end $$;

drop trigger if exists training_modules_requirement on candidate.training_modules;
create trigger training_modules_requirement
  after insert or update of requirement_code, title, status, set_criticality
  on candidate.training_modules
  for each row execute function candidate.trg_training_module_requirement();

-- ── sync_training_requirements(): wire modules into the clinical sets ────────
-- Adds each ACTIVE module's requirement to every clinical requirement set at the
-- module's set_criticality (blocking for the 11 core, standard for extras). The
-- non-clinical INSURANCE set and the registered-manager add-on sets are excluded
-- by omission. Idempotent: unique(set_id, requirement_id) collapses re-runs.
-- Returns the number of set-item rows inserted this call.
create or replace function candidate.sync_training_requirements()
returns int language plpgsql security definer
set search_path = candidate, public as $$
declare
  v_inserted int;
begin
  if not (candidate.is_manager() or candidate.is_service_role()) then
    raise exception 'not authorized';
  end if;

  with clinical_sets as (
    select id from candidate.requirement_sets
    where status = 'active'
      and code in ('NHS_RN','NHS_HCA','NHS_DOCTOR','AHP_HCPC',
                   'COMPLEX_CARE','CARE_HOME','CHILDRENS')
  ),
  ins as (
    insert into candidate.requirement_set_items
      (set_id, requirement_id, criticality, sort_order)
    select cs.id, cr.id, tm.set_criticality, 300
    from candidate.training_modules tm
    join candidate.compliance_requirements cr on cr.code = tm.requirement_code
                                             and cr.discipline_id is null
                                             and cr.specialty_id is null
    cross join clinical_sets cs
    where tm.status = 'active'
    on conflict (set_id, requirement_id) do nothing
    returning 1
  )
  select count(*) into v_inserted from ins;

  return coalesce(v_inserted, 0);
end $$;
revoke all on function candidate.sync_training_requirements() from public;
grant execute on function candidate.sync_training_requirements() to authenticated, service_role;

-- ── CI3: demote the legacy monolithic `mandatory_training` to advisory ───────
-- The per-subject train_* requirements now carry the gate; the legacy monolith
-- must not double-count. Overriding the SET ITEM to advisory (recompute uses
-- coalesce(rsi.criticality, cr.criticality)) neutralises it wherever it was
-- wired (24/27 seeded it 'standard'). Idempotent.
update candidate.requirement_set_items rsi
set criticality = 'advisory'
from candidate.compliance_requirements cr
where rsi.requirement_id = cr.id
  and cr.code = 'mandatory_training'
  and rsi.criticality is distinct from 'advisory';

-- ── RLS ──────────────────────────────────────────────────────────────────────
-- Managers curate the catalogue; all authorised staff read.
alter table candidate.training_modules enable row level security;
drop policy if exists "auth read training_modules"     on candidate.training_modules;
drop policy if exists "manager write training_modules"  on candidate.training_modules;
create policy "auth read training_modules" on candidate.training_modules
  for select to authenticated using (candidate.is_authorized_user());
create policy "manager write training_modules" on candidate.training_modules
  for all to authenticated
  using (candidate.is_authorized_user() and candidate.is_manager())
  with check (candidate.is_authorized_user() and candidate.is_manager());

-- Table privileges (RLS still gates rows; SECURITY DEFINER RPCs run as owner).
grant select, insert, update, delete on candidate.training_modules to authenticated;

-- ==== sql/48_training_versions.sql ====
-- ============================================================================
--  Day Webster — Candidate Pipeline · Mandatory Training: versioned content
--  File: candidate-pipeline/sql/48_training_versions.sql
--  Run AFTER 47.  Idempotent / additive.  STATUS: DRAFT — NOT YET APPLIED.
--
--  Accreditation-bearing content, so: AI may DRAFT but a HUMAN approval gate is
--  mandatory before publish, and a published version is IMMUTABLE and versioned
--  (a training record freezes the module_version it was assessed against).
--
--  Role gates (confirmed): author/draft/edit-draft = is_compliance_officer();
--  approve + publish = is_manager() (managers/admins — the accreditation gate).
--
--  Every workflow transition appends an attributable verification_events row.
--  Those rows are CATALOGUE-level (no candidate), so candidate_id is made
--  nullable below; the event_type CHECK is widened to add the training verbs,
--  keeping the FULL prior superset (checklist_sent/override_*/breach_* etc).
-- ============================================================================

-- ── Allow catalogue-level (candidate-less) audit rows on the spine ───────────
-- Training publish/approve/submit are catalogue events, not candidate events, so
-- the append-only audit spine must accept a NULL candidate_id. Widening only
-- (existing candidate-scoped inserts are unaffected). Idempotent.
alter table candidate.verification_events alter column candidate_id drop not null;

-- ── Widen the event_type CHECK: add training verbs, keep the full superset ────
-- Drop-then-add keeps this idempotent; the list is a strict SUPERSET of sql/44's
-- (every prior verb retained) so no existing row is ever invalidated.
alter table candidate.verification_events
  drop constraint if exists verification_events_event_type_check;
alter table candidate.verification_events
  add constraint verification_events_event_type_check
  check (event_type in ('verified','rejected','unsuitable','expired','waived',
         'reinstated','evidence_received','recheck_requested','status_recomputed',
         'override_granted','override_revoked',
         'breach_logged','breach_acknowledged','breach_resolved',
         'checklist_sent',
         'training_submitted','training_approved','training_published'));

-- ── Widen the method CHECK: add 'assessment' (a pass through the LMS engine) ──
-- Keeps the full prior superset; drop-then-add is idempotent. issue_training_record
-- (50) stamps method='assessment' for an assessed pass, 'human' for a manual entry.
alter table candidate.verification_events
  drop constraint if exists verification_events_method_check;
alter table candidate.verification_events
  add constraint verification_events_method_check
  check (method in ('human','idvt','rtw','dbs_update','register_check',
         'ocr','import','system','assessment'));

-- ── module_versions: versioned KB content + workflow status ──────────────────
create table if not exists candidate.module_versions (
  id            uuid primary key default gen_random_uuid(),
  module_id     uuid not null references candidate.training_modules(id) on delete cascade,
  version       int  not null,
  status        text not null default 'draft'
                check (status in ('draft','in_review','approved','published','retired')),
  content       jsonb not null default '{}'::jsonb,   -- KB: [{heading, body_md}, ...]
  ai_generated  boolean not null default false,
  ai_model      text,
  authored_by   uuid references auth.users(id) on delete set null,
  reviewed_by   uuid references auth.users(id) on delete set null,
  approved_by   uuid references auth.users(id) on delete set null,  -- the human approval-gate signer (manager)
  approved_at   timestamptz,
  published_at  timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (module_id, version)
);
create index if not exists module_versions_module_idx on candidate.module_versions (module_id, status);

drop trigger if exists module_versions_set_updated_at on candidate.module_versions;
create trigger module_versions_set_updated_at
  before update on candidate.module_versions
  for each row execute function candidate.set_updated_at();

-- ── training_questions: the per-version MCQ bank (answer keys server-side) ────
create table if not exists candidate.training_questions (
  id                uuid primary key default gen_random_uuid(),
  module_version_id uuid not null references candidate.module_versions(id) on delete cascade,
  stem              text not null,
  options           jsonb not null,        -- [{key:'a', text:'...'}, ...]
  correct_keys      jsonb not null,        -- ['a'] or ['a','c'] — NEVER served to candidates
  explanation       text,
  sort_order        int not null default 100,
  created_at        timestamptz not null default now()
);
create index if not exists training_questions_version_idx on candidate.training_questions (module_version_id, sort_order);

-- ── current_version_id FK (now that module_versions exists) ──────────────────
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'training_modules_current_version_fk') then
    alter table candidate.training_modules
      add constraint training_modules_current_version_fk
      foreign key (current_version_id) references candidate.module_versions(id) on delete set null;
  end if;
end $$;

-- ── Immutability trigger: a PUBLISHED version is frozen ──────────────────────
-- Once status='published', content cannot mutate and status can only move
-- forward to 'retired' (on republish of a successor). Editing a published module
-- means a NEW module_versions row (version+1, draft), never an in-place edit.
create or replace function candidate.trg_module_version_immutable()
returns trigger language plpgsql
set search_path = candidate, public as $$
declare
  v_order  jsonb := '{"draft":0,"in_review":1,"approved":2,"published":3,"retired":4}'::jsonb;
begin
  -- A version is immutable once it has been published OR retired: content is
  -- frozen and status can only move forward (published -> retired is allowed;
  -- retired is terminal, so every move from it is backward and rejected).
  if old.status in ('published','retired') then
    if new.content is distinct from old.content then
      raise exception 'module version % is immutable (content cannot change once %)', old.id, old.status;
    end if;
    if (v_order->>new.status)::int < (v_order->>old.status)::int then
      raise exception 'module version % cannot move backward from % to %', old.id, old.status, new.status;
    end if;
  end if;
  return new;
end $$;

drop trigger if exists module_versions_immutable on candidate.module_versions;
create trigger module_versions_immutable
  before update on candidate.module_versions
  for each row execute function candidate.trg_module_version_immutable();

-- Questions of a published version are immutable too (no insert/update/delete).
create or replace function candidate.trg_training_question_immutable()
returns trigger language plpgsql
set search_path = candidate, public as $$
declare v_status text;
begin
  select status into v_status from candidate.module_versions
   where id = coalesce(new.module_version_id, old.module_version_id);
  if v_status = 'published' then
    raise exception 'questions of a published module version are immutable';
  end if;
  return coalesce(new, old);
end $$;

drop trigger if exists training_questions_immutable on candidate.training_questions;
create trigger training_questions_immutable
  before insert or update or delete on candidate.training_questions
  for each row execute function candidate.trg_training_question_immutable();

-- ── Internal helper: append a catalogue-level workflow audit row ─────────────
create or replace function candidate.trg_training_version_event(
    p_version_id uuid, p_event_type text, p_notes text)
returns void language plpgsql security definer
set search_path = candidate, public as $$
declare v_req uuid; v_code text; v_ver int;
begin
  select cr.id, tm.code, mv.version
    into v_req, v_code, v_ver
  from candidate.module_versions mv
  join candidate.training_modules tm on tm.id = mv.module_id
  left join candidate.compliance_requirements cr
    on cr.code = tm.requirement_code and cr.discipline_id is null and cr.specialty_id is null
  where mv.id = p_version_id;

  insert into candidate.verification_events
    (candidate_id, requirement_id, event_type, method, source_ref, notes, actor, actor_kind)
  values
    (null, v_req, p_event_type, 'human',
     format('%s v%s', v_code, v_ver), p_notes, auth.uid(), 'human');
end $$;
revoke all on function candidate.trg_training_version_event(uuid, text, text) from public;

-- ── save_module_version: create/update a DRAFT (officer) ─────────────────────
-- p_version_id null => create the next draft version for the module. Otherwise
-- overwrite an existing DRAFT's content. Draft/in_review content is freely
-- editable; published content is frozen by the immutability trigger.
create or replace function candidate.save_module_version(
    p_module_id    uuid,
    p_content      jsonb,
    p_version_id   uuid    default null,
    p_ai_generated boolean default false,
    p_ai_model     text    default null)
returns uuid language plpgsql security definer
set search_path = candidate, public as $$
declare v_id uuid; v_status text; v_next int;
begin
  if not candidate.is_compliance_officer() then
    raise exception 'not authorized';
  end if;

  if p_version_id is null then
    select coalesce(max(version), 0) + 1 into v_next
      from candidate.module_versions where module_id = p_module_id;
    insert into candidate.module_versions
      (module_id, version, status, content, ai_generated, ai_model, authored_by)
    values (p_module_id, v_next, 'draft', coalesce(p_content, '{}'::jsonb),
            p_ai_generated, p_ai_model, auth.uid())
    returning id into v_id;
    return v_id;
  end if;

  select status into v_status from candidate.module_versions where id = p_version_id;
  if not found then raise exception 'module version % not found', p_version_id; end if;
  if v_status <> 'draft' then
    raise exception 'only a draft version can be edited (version is %)', v_status;
  end if;
  update candidate.module_versions
    set content = coalesce(p_content, content),
        ai_generated = p_ai_generated, ai_model = p_ai_model, updated_at = now()
  where id = p_version_id;
  return p_version_id;
end $$;
revoke all on function candidate.save_module_version(uuid, jsonb, uuid, boolean, text) from public;
grant execute on function candidate.save_module_version(uuid, jsonb, uuid, boolean, text) to authenticated, service_role;

-- ── add_training_question: append an MCQ to a DRAFT version (officer) ────────
-- Questions are edited THROUGH this RPC (the table has no direct write policy),
-- so a staff-token leak can neither dump nor forge the answer bank.
create or replace function candidate.add_training_question(
    p_version_id   uuid,
    p_stem         text,
    p_options      jsonb,
    p_correct_keys jsonb,
    p_explanation  text default null,
    p_sort_order   int  default 100)
returns uuid language plpgsql security definer
set search_path = candidate, public as $$
declare v_status text; v_id uuid;
begin
  if not candidate.is_compliance_officer() then
    raise exception 'not authorized';
  end if;
  select status into v_status from candidate.module_versions where id = p_version_id;
  if not found then raise exception 'module version % not found', p_version_id; end if;
  if v_status not in ('draft','in_review') then
    raise exception 'questions can only be edited on a draft/in_review version (is %)', v_status;
  end if;
  if jsonb_typeof(p_correct_keys) <> 'array' or jsonb_array_length(p_correct_keys) = 0 then
    raise exception 'correct_keys must be a non-empty array';
  end if;
  insert into candidate.training_questions
    (module_version_id, stem, options, correct_keys, explanation, sort_order)
  values (p_version_id, p_stem, p_options, p_correct_keys, p_explanation, p_sort_order)
  returning id into v_id;
  return v_id;
end $$;
revoke all on function candidate.add_training_question(uuid, text, jsonb, jsonb, text, int) from public;
grant execute on function candidate.add_training_question(uuid, text, jsonb, jsonb, text, int) to authenticated, service_role;

-- ── submit_module_for_review: draft -> in_review (officer) ───────────────────
create or replace function candidate.submit_module_for_review(p_version_id uuid)
returns void language plpgsql security definer
set search_path = candidate, public as $$
declare v_status text;
begin
  if not candidate.is_compliance_officer() then
    raise exception 'not authorized';
  end if;
  select status into v_status from candidate.module_versions where id = p_version_id;
  if not found then raise exception 'module version % not found', p_version_id; end if;
  if v_status <> 'draft' then
    raise exception 'only a draft can be submitted for review (is %)', v_status;
  end if;
  update candidate.module_versions
    set status = 'in_review', reviewed_by = auth.uid(), updated_at = now()
  where id = p_version_id;
  perform candidate.trg_training_version_event(p_version_id, 'training_submitted',
    'module version submitted for review');
end $$;
revoke all on function candidate.submit_module_for_review(uuid) from public;
grant execute on function candidate.submit_module_for_review(uuid) to authenticated, service_role;

-- ── approve_module_version: in_review -> approved (MANAGER — accreditation) ──
-- Refuses if the bank has fewer than the module's question_count questions.
create or replace function candidate.approve_module_version(p_version_id uuid)
returns void language plpgsql security definer
set search_path = candidate, public as $$
declare v_status text; v_module uuid; v_need int; v_have int;
begin
  if not candidate.is_manager() then
    raise exception 'not authorized';
  end if;
  select mv.status, mv.module_id, tm.question_count
    into v_status, v_module, v_need
  from candidate.module_versions mv
  join candidate.training_modules tm on tm.id = mv.module_id
  where mv.id = p_version_id;
  if not found then raise exception 'module version % not found', p_version_id; end if;
  if v_status <> 'in_review' then
    raise exception 'only an in_review version can be approved (is %)', v_status;
  end if;
  select count(*) into v_have from candidate.training_questions where module_version_id = p_version_id;
  if v_have < v_need then
    raise exception 'cannot approve: % questions authored, module requires at least %', v_have, v_need;
  end if;
  update candidate.module_versions
    set status = 'approved', approved_by = auth.uid(), approved_at = now(), updated_at = now()
  where id = p_version_id;
  perform candidate.trg_training_version_event(p_version_id, 'training_approved',
    format('module version approved (%s questions in bank)', v_have));
end $$;
revoke all on function candidate.approve_module_version(uuid) from public;
grant execute on function candidate.approve_module_version(uuid) to authenticated, service_role;

-- ── publish_module_version: approved -> published (MANAGER) ──────────────────
-- Sets training_modules.current_version_id and retires the prior published
-- version. Appends the training_published audit row.
create or replace function candidate.publish_module_version(p_version_id uuid)
returns void language plpgsql security definer
set search_path = candidate, public as $$
declare v_status text; v_module uuid; v_prior uuid;
begin
  if not candidate.is_manager() then
    raise exception 'not authorized';
  end if;
  select status, module_id into v_status, v_module
    from candidate.module_versions where id = p_version_id;
  if not found then raise exception 'module version % not found', p_version_id; end if;
  if v_status <> 'approved' then
    raise exception 'only an approved version can be published (is %)', v_status;
  end if;

  -- Retire the prior published version (if any) for this module.
  select current_version_id into v_prior from candidate.training_modules where id = v_module;
  if v_prior is not null and v_prior <> p_version_id then
    update candidate.module_versions set status = 'retired', updated_at = now()
      where id = v_prior and status = 'published';
  end if;

  update candidate.module_versions
    set status = 'published', published_at = now(), updated_at = now()
  where id = p_version_id;

  update candidate.training_modules
    set current_version_id = p_version_id, updated_at = now()
  where id = v_module;

  perform candidate.trg_training_version_event(p_version_id, 'training_published',
    'module version published (current version set; prior retired)');
end $$;
revoke all on function candidate.publish_module_version(uuid) from public;
grant execute on function candidate.publish_module_version(uuid) to authenticated, service_role;

-- ── RLS ──────────────────────────────────────────────────────────────────────
alter table candidate.module_versions   enable row level security;
alter table candidate.training_questions enable row level security;

-- module_versions: authorised staff READ; all writes go through the RPCs above
-- (SECURITY DEFINER), so there is NO direct write policy.
drop policy if exists "auth read module_versions" on candidate.module_versions;
create policy "auth read module_versions" on candidate.module_versions
  for select to authenticated using (candidate.is_authorized_user());

-- training_questions: SELECT is MANAGER-ONLY (raw correct_keys are the answer
-- bank — a staff-token leak must not be able to dump them). No write policy:
-- questions are authored only via add_training_question (SECURITY DEFINER).
drop policy if exists "manager read training_questions" on candidate.training_questions;
create policy "manager read training_questions" on candidate.training_questions
  for select to authenticated
  using (candidate.is_authorized_user() and candidate.is_manager());

-- Table privileges. Writes to both tables are RPC-only (SECURITY DEFINER), so no
-- insert/update/delete grant here; RLS above still restricts question SELECT to
-- managers even though the grant is table-wide.
grant select on candidate.module_versions   to authenticated;
grant select on candidate.training_questions to authenticated;

-- ==== sql/49_training_delivery.sql ====
-- ============================================================================
--  Day Webster — Candidate Pipeline · Mandatory Training: delivery + assessment
--  File: candidate-pipeline/sql/49_training_delivery.sql
--  Run AFTER 48 (and before/with 50 — submit_training_attempt calls
--  issue_training_record at runtime).  Idempotent / additive.
--  STATUS: DRAFT — NOT YET APPLIED.
--
--  Passwordless magic-link delivery (no candidate account) + the integrity-first
--  assessment core. Mirrors the function-as-trust-boundary model: the candidate
--  holds only an opaque, hashed, single-use, short-TTL token and talks solely to
--  SECURITY DEFINER RPCs; the tables are default-deny to non-staff.
--
--  THE ASSESSMENT INVARIANT: the correct-answer key NEVER reaches the browser and
--  grading happens server-side. start_training_attempt serves questions with
--  correct_keys + explanation stripped; submit_training_attempt fetches the keys
--  itself and grades. No RPC in this file ever returns correct_keys.
--
--  In Round 2 the `training-portal` edge function (service role) calls these,
--  hashing the raw magic-link/session tokens before they reach the DB. Round 1
--  keeps the same gates so a compliance officer can also drive them in tests.
-- ============================================================================

-- ── training_assignments: a candidate owes a module at a pinned version ──────
create table if not exists candidate.training_assignments (
  id                uuid primary key default gen_random_uuid(),
  candidate_id      uuid not null references candidate.candidates(id) on delete cascade,
  module_id         uuid not null references candidate.training_modules(id) on delete restrict,
  module_version_id uuid not null references candidate.module_versions(id) on delete restrict,
  status            text not null default 'assigned'
                    check (status in ('assigned','in_progress','passed','failed','expired','cancelled')),
  assigned_by       uuid references auth.users(id) on delete set null,
  assigned_at       timestamptz not null default now(),
  completed_at      timestamptz,
  unique (candidate_id, module_id, module_version_id)
);
create index if not exists training_assignments_candidate_idx on candidate.training_assignments (candidate_id);

-- ── training_magic_links: hashed, short-TTL, single-use ──────────────────────
create table if not exists candidate.training_magic_links (
  token_hash    text primary key,               -- sha256(raw); raw emailed, NEVER stored
  assignment_id uuid not null references candidate.training_assignments(id) on delete cascade,
  candidate_id  uuid not null references candidate.candidates(id) on delete cascade,
  expires_at    timestamptz not null,
  consumed_at   timestamptz,
  created_at    timestamptz not null default now()
);

-- ── training_sessions: short-lived post-consume session (~60 min) ────────────
create table if not exists candidate.training_sessions (
  token_hash    text primary key,
  assignment_id uuid not null references candidate.training_assignments(id) on delete cascade,
  candidate_id  uuid not null references candidate.candidates(id) on delete cascade,
  expires_at    timestamptz not null,
  created_at    timestamptz not null default now()
);

-- ── training_attempts: one row per assessment attempt (audit trail) ──────────
create table if not exists candidate.training_attempts (
  id                  uuid primary key default gen_random_uuid(),
  assignment_id       uuid not null references candidate.training_assignments(id) on delete cascade,
  candidate_id        uuid not null references candidate.candidates(id) on delete cascade,
  module_version_id   uuid not null references candidate.module_versions(id) on delete restrict,
  served_question_ids jsonb not null,            -- exact set + order served (integrity)
  answers             jsonb,
  score               numeric,                   -- % computed server-side
  passed              boolean,
  started_at          timestamptz not null default now(),
  submitted_at        timestamptz
);
create index if not exists training_attempts_assignment_idx on candidate.training_attempts (assignment_id);

-- ── assign_training: create assignment + magic link, return RAW token ONCE ───
-- Officer/service gated. Pins the module's CURRENT PUBLISHED version (raises if
-- there is none). Stores only sha256(token); returns the raw token to the caller
-- (who emails it). Re-assigning the same candidate+module+version reuses the
-- assignment and issues a fresh link.
create or replace function candidate.assign_training(
    p_candidate_id uuid,
    p_module_id    uuid,
    p_ttl          interval default interval '7 days')
returns text language plpgsql security definer
set search_path = candidate, public as $$
declare
  v_version uuid; v_assignment uuid; v_raw text; v_hash text;
begin
  if not (candidate.is_compliance_officer() or candidate.is_service_role()) then
    raise exception 'not authorized';
  end if;

  select current_version_id into v_version from candidate.training_modules where id = p_module_id;
  if v_version is null then
    raise exception 'module % has no published version — cannot assign', p_module_id;
  end if;

  insert into candidate.training_assignments
    (candidate_id, module_id, module_version_id, status, assigned_by)
  values (p_candidate_id, p_module_id, v_version, 'assigned', auth.uid())
  on conflict (candidate_id, module_id, module_version_id)
  do update set status = case when candidate.training_assignments.status in ('passed')
                             then candidate.training_assignments.status else 'assigned' end
  returning id into v_assignment;

  v_raw  := encode(gen_random_bytes(32), 'hex');
  v_hash := encode(digest(v_raw, 'sha256'), 'hex');
  insert into candidate.training_magic_links (token_hash, assignment_id, candidate_id, expires_at)
  values (v_hash, v_assignment, p_candidate_id, now() + coalesce(p_ttl, interval '7 days'));

  return v_raw;
end $$;
revoke all on function candidate.assign_training(uuid, uuid, interval) from public;
grant execute on function candidate.assign_training(uuid, uuid, interval) to authenticated, service_role;

-- ── consume_training_link: single-use link -> session + KB content ───────────
-- p_token_hash = sha256(raw) (the edge function hashes the raw token before the
-- call). Validates unconsumed + unexpired, marks it consumed (single-use), mints
-- a session, flips the assignment to in_progress, and returns the KB content.
-- Generic error on any failure (no enumeration).
create or replace function candidate.consume_training_link(p_token_hash text)
returns jsonb language plpgsql security definer
set search_path = candidate, public as $$
declare
  v_assignment uuid; v_candidate uuid; v_version uuid; v_session text;
  v_module record;
begin
  if not (candidate.is_service_role() or candidate.is_compliance_officer()) then
    raise exception 'not authorized';
  end if;

  -- Atomic single-use consume (race-safe): only the first caller wins the row.
  update candidate.training_magic_links
    set consumed_at = now()
  where token_hash = p_token_hash and consumed_at is null and expires_at > now()
  returning assignment_id, candidate_id into v_assignment, v_candidate;
  if v_assignment is null then
    raise exception 'invalid or expired link';
  end if;

  select module_version_id into v_version from candidate.training_assignments where id = v_assignment;

  update candidate.training_assignments
    set status = 'in_progress'
  where id = v_assignment and status in ('assigned','failed');

  -- Session token is hashed AT REST (symmetric with the magic link): we mint a raw
  -- token, store only sha256(raw), and return the raw to the edge function — which
  -- hashes it again on each start/submit/status call. A DB-read compromise cannot
  -- replay an in-flight session.
  v_session := encode(gen_random_bytes(32), 'hex');
  insert into candidate.training_sessions (token_hash, assignment_id, candidate_id, expires_at)
  values (encode(digest(v_session, 'sha256'), 'hex'), v_assignment, v_candidate, now() + interval '60 minutes');

  select tm.id, tm.code, tm.title, tm.framework, tm.framework_subject,
         tm.question_count, tm.pass_threshold, mv.content
    into v_module
  from candidate.module_versions mv
  join candidate.training_modules tm on tm.id = mv.module_id
  where mv.id = v_version;

  return jsonb_build_object(
    'session_token', v_session,          -- RAW token; the DB stores only its sha256
    'assignment_id', v_assignment,
    'module', jsonb_build_object(
        'code', v_module.code, 'title', v_module.title,
        'framework', v_module.framework, 'framework_subject', v_module.framework_subject,
        'question_count', v_module.question_count, 'pass_threshold', v_module.pass_threshold),
    'content', v_module.content);
end $$;
revoke all on function candidate.consume_training_link(text) from public;
grant execute on function candidate.consume_training_link(text) to authenticated, service_role;

-- ── start_training_attempt: THE INTEGRITY CORE ───────────────────────────────
-- Validates the session, randomly selects N=question_count questions from the
-- PINNED version, records an attempt storing the exact served ids, and returns
-- the questions WITH correct_keys + explanation STRIPPED. This RPC must never
-- return an answer key.
create or replace function candidate.start_training_attempt(p_session_hash text)
returns jsonb language plpgsql security definer
set search_path = candidate, public as $$
declare
  v_assignment uuid; v_candidate uuid; v_version uuid; v_n int;
  v_ids jsonb; v_attempt uuid; v_questions jsonb;
begin
  if not (candidate.is_service_role() or candidate.is_compliance_officer()) then
    raise exception 'not authorized';
  end if;

  select assignment_id, candidate_id into v_assignment, v_candidate
  from candidate.training_sessions
  where token_hash = p_session_hash and expires_at > now();
  if v_assignment is null then
    raise exception 'invalid or expired session';
  end if;

  -- Idempotent per assignment: once passed, no further attempts (a crafted client
  -- must not be able to start a new attempt and mint a second certificate).
  if (select status from candidate.training_assignments where id = v_assignment) = 'passed' then
    raise exception 'assessment already completed for this assignment';
  end if;

  select ta.module_version_id, tm.question_count
    into v_version, v_n
  from candidate.training_assignments ta
  join candidate.training_modules tm on tm.id = ta.module_id
  where ta.id = v_assignment;

  -- Random N-of-bank selection (re-randomised on every attempt / retake).
  with picked as (
    select id, stem, options, row_number() over () as rn
    from (
      select id, stem, options
      from candidate.training_questions
      where module_version_id = v_version
      order by random()
      limit v_n
    ) q
  )
  select jsonb_agg(id order by rn),
         jsonb_agg(jsonb_build_object('id', id, 'stem', stem, 'options', options) order by rn)
    into v_ids, v_questions
  from picked;

  if v_ids is null or jsonb_array_length(v_ids) < v_n then
    raise exception 'module version % has too few questions to serve an attempt', v_version;
  end if;

  insert into candidate.training_attempts
    (assignment_id, candidate_id, module_version_id, served_question_ids)
  values (v_assignment, v_candidate, v_version, v_ids)
  returning id into v_attempt;

  -- NOTE: v_questions was built from id/stem/options ONLY — no correct_keys,
  -- no explanation. This is the object the browser receives.
  return jsonb_build_object('attempt_id', v_attempt, 'questions', v_questions);
end $$;
revoke all on function candidate.start_training_attempt(text) from public;
grant execute on function candidate.start_training_attempt(text) to authenticated, service_role;

-- ── submit_training_attempt: server-side grading ─────────────────────────────
-- Fetches the served questions' correct_keys INSIDE the function; a question is
-- correct iff the submitted key set == the correct_keys set. Computes score %,
-- passed = score >= module.pass_threshold. On pass issues the training record
-- (+cert +compliance hook, 50); on fail marks the assignment failed (retake
-- allowed, re-randomised next start). Never returns correct_keys.
-- p_answers shape: { "<question_id>": ["a","c"], ... }
create or replace function candidate.submit_training_attempt(
    p_session_hash text,
    p_attempt_id   uuid,
    p_answers      jsonb)
returns jsonb language plpgsql security definer
set search_path = candidate, public as $$
declare
  v_assignment uuid; v_candidate uuid; v_version uuid; v_module uuid;
  v_threshold numeric; v_ids jsonb; v_n int; v_correct int := 0;
  v_qid text; v_score numeric; v_passed boolean; v_cert text; v_rec uuid;
begin
  if not (candidate.is_service_role() or candidate.is_compliance_officer()) then
    raise exception 'not authorized';
  end if;

  select assignment_id, candidate_id into v_assignment, v_candidate
  from candidate.training_sessions
  where token_hash = p_session_hash and expires_at > now();
  if v_assignment is null then
    raise exception 'invalid or expired session';
  end if;

  select served_question_ids into v_ids
  from candidate.training_attempts
  where id = p_attempt_id and assignment_id = v_assignment
    and candidate_id = v_candidate and submitted_at is null;
  if v_ids is null then
    raise exception 'invalid or already-submitted attempt';
  end if;

  select ta.module_version_id, ta.module_id into v_version, v_module
  from candidate.training_assignments ta where ta.id = v_assignment;
  select pass_threshold into v_threshold from candidate.training_modules where id = v_module;

  v_n := jsonb_array_length(v_ids);

  -- Grade each SERVED question against its server-side correct_keys (set equality).
  for v_qid in select jsonb_array_elements_text(v_ids) loop
    if exists (
      select 1 from candidate.training_questions q
      where q.id = v_qid::uuid
        and (select array_agg(x order by x)
               from jsonb_array_elements_text(q.correct_keys) x)
          = (select array_agg(x order by x)
               from jsonb_array_elements_text(coalesce(p_answers->v_qid, '[]'::jsonb)) x)
    ) then
      v_correct := v_correct + 1;
    end if;
  end loop;

  v_score  := round((v_correct::numeric / greatest(v_n, 1)) * 100, 2);
  v_passed := v_score >= v_threshold;

  update candidate.training_attempts
    set answers = p_answers, score = v_score, passed = v_passed, submitted_at = now()
  where id = p_attempt_id;

  if v_passed then
    -- issue_training_record (50) writes the record + cert + compliance hook.
    select cert_id, rec_id into v_cert, v_rec
    from candidate.issue_training_record(
           v_candidate, v_module, 'assessment', v_score, current_date,
           p_attempt_id, null, null);
    update candidate.training_assignments
      set status = 'passed', completed_at = now() where id = v_assignment;
  else
    update candidate.training_assignments
      set status = 'failed' where id = v_assignment;
  end if;

  return jsonb_build_object('passed', v_passed, 'score', v_score,
    'certificate_id', v_cert);   -- correct_keys are NEVER included
end $$;
revoke all on function candidate.submit_training_attempt(text, uuid, jsonb) from public;
grant execute on function candidate.submit_training_attempt(text, uuid, jsonb) to authenticated, service_role;

-- ── RLS ──────────────────────────────────────────────────────────────────────
alter table candidate.training_assignments enable row level security;
alter table candidate.training_magic_links enable row level security;   -- no policy: service only
alter table candidate.training_sessions    enable row level security;   -- no policy: service only
alter table candidate.training_attempts    enable row level security;

-- assignments: authorised staff READ + officer INSERT; status transitions via
-- RPC only (no UPDATE policy); managers may DELETE.
drop policy if exists "auth read training_assignments"     on candidate.training_assignments;
drop policy if exists "officer insert training_assignments" on candidate.training_assignments;
drop policy if exists "manager delete training_assignments" on candidate.training_assignments;
create policy "auth read training_assignments" on candidate.training_assignments
  for select to authenticated using (candidate.is_authorized_user());
create policy "officer insert training_assignments" on candidate.training_assignments
  for insert to authenticated
  with check (candidate.is_authorized_user() and candidate.is_compliance_officer());
create policy "manager delete training_assignments" on candidate.training_assignments
  for delete to authenticated
  using (candidate.is_authorized_user() and candidate.is_manager());

-- attempts: authorised staff READ; no client write (RPC only) => un-forgeable.
drop policy if exists "auth read training_attempts" on candidate.training_attempts;
create policy "auth read training_attempts" on candidate.training_attempts
  for select to authenticated using (candidate.is_authorized_user());

-- Table privileges. magic_links/sessions get NONE (service-only). Assignment
-- status transitions + attempt writes are RPC-only, so no update/insert grant on
-- attempts; assignments allow officer INSERT + manager DELETE per policy.
grant select, insert, delete on candidate.training_assignments to authenticated;
grant select on candidate.training_attempts to authenticated;

-- ==== sql/50_training_records.sql ====
-- ============================================================================
--  Day Webster — Candidate Pipeline · Mandatory Training: records + certs + hook
--  File: candidate-pipeline/sql/50_training_records.sql
--  Run AFTER 49.  Idempotent / additive.  STATUS: DRAFT — NOT YET APPLIED.
--
--  The producer of compliance_items. issue_training_record() is the single choke
--  point that mints a certificate, writes an immutable training_records row, and
--  writes the COMPLIANCE HOOK: a verified, expiring compliance_item under the
--  module's OWN requirement_code (CI1). The existing item trigger (23/25) then
--  recomputes the work-ready gate and the pre-expiry ladder (41) chases each
--  subject on its own clock — zero changes to the gate/ladder/passport.
--
--  Certificates are HTML in Phase 1 (PDF later). sfh_accreditation_ref is carried
--  onto the cert as STORED-not-asserted (see 47 header).
-- ============================================================================

-- ── training_records: one immutable record per completion (+ its certificate) ─
create table if not exists candidate.training_records (
  id                 uuid primary key default gen_random_uuid(),
  candidate_id       uuid not null references candidate.candidates(id) on delete cascade,
  module_id          uuid not null references candidate.training_modules(id) on delete restrict,
  -- FROZEN version assessed against. NULL only for a manual/elsewhere completion
  -- of a module that has no published version (nothing of ours to freeze).
  module_version_id  uuid references candidate.module_versions(id) on delete restrict,
  source             text not null check (source in ('assessment','manual')),
  score              numeric,
  attempt_id         uuid references candidate.training_attempts(id) on delete set null,
  provider           text,                          -- manual: where it was done elsewhere
  completion_date    date not null,
  expiry_date        date not null,                 -- completion + validity_months
  certificate_id     text not null unique,          -- 'DW-TRN-2026-3F9K2A'
  certificate_path   text,                          -- private bucket 'training-certs' (Round 2)
  compliance_item_id uuid references candidate.compliance_items(id) on delete set null,
  recorded_by        uuid references auth.users(id) on delete set null,  -- manual: the manager
  created_at         timestamptz not null default now()
);
create index if not exists training_records_candidate_idx on candidate.training_records (candidate_id);
create index if not exists training_records_module_idx    on candidate.training_records (module_id);

-- ── issue_training_record: mint cert, write record, write the compliance hook ─
-- The ONLY way a training_records row + compliance_item is produced. Reachable
-- only via submit_training_attempt (49, assessment) and record_manual_training
-- (51, manual) — both SECURITY DEFINER — plus direct service_role. NOT granted to
-- authenticated, so a plain officer cannot forge a record by calling it directly.
create or replace function candidate.issue_training_record(
    p_candidate_id   uuid,
    p_module_id      uuid,
    p_source         text,
    p_score          numeric,
    p_completion_date date,
    p_attempt_id     uuid default null,
    p_provider       text default null,
    p_evidence_path  text default null)
returns table(rec_id uuid, cert_id text)   -- named to avoid collision with table `id` columns
language plpgsql security definer
set search_path = candidate, public as $$
declare
  v_req_code text; v_validity int; v_req uuid; v_version uuid;
  v_expiry date; v_cert text; v_channel text; v_item uuid; v_rec uuid;
begin
  if not (candidate.is_service_role() or candidate.is_compliance_officer()) then
    raise exception 'not authorized';
  end if;
  if p_source not in ('assessment','manual') then
    raise exception 'invalid source: %', p_source;
  end if;

  select requirement_code, validity_months, current_version_id
    into v_req_code, v_validity, v_version
  from candidate.training_modules where id = p_module_id;
  if not found then raise exception 'module % not found', p_module_id; end if;

  -- Freeze the assessed version on the assessment path; else the current version.
  if p_source = 'assessment' and p_attempt_id is not null then
    select module_version_id into v_version from candidate.training_attempts where id = p_attempt_id;
  end if;

  v_expiry  := (p_completion_date + make_interval(months => v_validity))::date;
  -- 48 bits of entropy (per-year namespaced) so a certificate_id collision — which
  -- would otherwise fail the pass submission on the unique index — is negligible.
  v_cert    := 'DW-TRN-' || to_char(p_completion_date, 'YYYY') || '-' ||
               upper(encode(gen_random_bytes(6), 'hex'));
  v_channel := case when p_source = 'assessment' then 'assessment' else 'manual' end;

  -- Resolve the module's OWN (global) requirement (CI1).
  select cr.id into v_req from candidate.compliance_requirements cr
   where cr.code = v_req_code and cr.discipline_id is null and cr.specialty_id is null;

  -- ── COMPLIANCE HOOK: upsert the latest item for (candidate, requirement) ────
  if v_req is not null then
    select id into v_item from candidate.compliance_items
     where candidate_id = p_candidate_id and requirement_id = v_req
     order by (status = 'verified') desc, updated_at desc limit 1;

    if v_item is not null then
      update candidate.compliance_items
        set status = 'verified',
            expires_at = v_expiry,
            channel = v_channel,
            source_confidence = 'high',
            received_at = p_completion_date,
            needs_human = false,
            extracted = coalesce(extracted, '{}'::jsonb) || jsonb_build_object(
                          'source_ref', v_cert, 'certificate_id', v_cert,
                          'provider', p_provider, 'training_source', p_source,
                          'completion_date', p_completion_date, 'applied_outcome', 'verified'),
            updated_at = now()
      where id = v_item;
    else
      insert into candidate.compliance_items
        (candidate_id, requirement_id, status, channel, source_confidence,
         received_at, expires_at, needs_human, extracted)
      values
        (p_candidate_id, v_req, 'verified', v_channel, 'high',
         p_completion_date, v_expiry, false, jsonb_build_object(
           'source_ref', v_cert, 'certificate_id', v_cert, 'provider', p_provider,
           'training_source', p_source, 'completion_date', p_completion_date,
           'applied_outcome', 'verified'))
      returning id into v_item;
    end if;
  end if;
  -- (If v_req is null the item isn't written but the record/cert still issue —
  --  feeds the passport once wired; never errors. In practice 47's mirror
  --  trigger guarantees the requirement exists.)

  insert into candidate.training_records
    (candidate_id, module_id, module_version_id, source, score, attempt_id,
     provider, completion_date, expiry_date, certificate_id, compliance_item_id, recorded_by)
  values
    (p_candidate_id, p_module_id, v_version, p_source, p_score, p_attempt_id,
     p_provider, p_completion_date, v_expiry, v_cert, v_item,
     case when p_source = 'manual' then auth.uid() else null end)
  returning candidate.training_records.id into v_rec;

  -- Attributable audit row (append-only spine). Assessment => method='assessment'
  -- (actor null/service); manual => method='human' (actor = the manager).
  insert into candidate.verification_events
    (candidate_id, item_id, requirement_id, event_type, new_status, method,
     source_ref, notes, actor, actor_kind)
  values
    (p_candidate_id, v_item, v_req, 'verified', 'verified',
     case when p_source = 'assessment' then 'assessment' else 'human' end,
     v_cert,
     case when p_source = 'assessment'
          then format('training passed via assessment (score %s%%) — cert %s', p_score, v_cert)
          else format('training recorded manually (provider %s, evidence %s) — cert %s',
                      coalesce(p_provider,'?'), coalesce(p_evidence_path,'-'), v_cert) end,
     case when p_source = 'manual' then auth.uid() else null end,
     case when p_source = 'manual' then 'human' else 'service' end);

  return query select v_rec, v_cert;
end $$;
revoke all on function candidate.issue_training_record(uuid, uuid, text, numeric, date, uuid, text, text) from public;
grant execute on function candidate.issue_training_record(uuid, uuid, text, numeric, date, uuid, text, text) to service_role;

-- ── verify_certificate: MINIMAL public validity check ────────────────────────
-- Returns only what a client/auditor legitimately needs to confirm a cert —
-- NEVER full name / DOB / score. Unknown id => {valid:false}. SECURITY DEFINER so
-- it reads past training_records RLS while exposing only the whitelist below.
-- The PUBLIC verify page (Round 2) reaches this via a rate-limited
-- `certificate-verify` edge function running as service_role — we deliberately do
-- NOT grant anon direct DB access (no `grant usage on schema candidate to anon`),
-- so the public never touches Postgres directly.
create or replace function candidate.verify_certificate(p_certificate_id text)
returns jsonb language plpgsql stable security definer
set search_path = candidate, public as $$
declare v jsonb;
begin
  select jsonb_build_object(
    'valid',                 true,
    'module_title',          tm.title,
    'framework_subject',     tm.framework_subject,
    'sfh_accreditation_ref', tm.sfh_accreditation_ref,
    'completion_date',       tr.completion_date,
    'expiry_date',           tr.expiry_date,
    'status',                case when tr.expiry_date >= current_date then 'valid' else 'expired' end,
    'candidate_initials',    upper(coalesce(left(c.first_name,1),'') || coalesce(left(c.last_name,1),''))
  ) into v
  from candidate.training_records tr
  join candidate.training_modules tm on tm.id = tr.module_id
  join candidate.candidates c on c.id = tr.candidate_id
  where tr.certificate_id = p_certificate_id;

  return coalesce(v, jsonb_build_object('valid', false));
end $$;
revoke all on function candidate.verify_certificate(text) from public;
grant execute on function candidate.verify_certificate(text) to authenticated, service_role;

-- ── RLS ──────────────────────────────────────────────────────────────────────
alter table candidate.training_records enable row level security;
-- authorised staff READ; NO client write (append-only, RPC only); manager DELETE.
drop policy if exists "auth read training_records"    on candidate.training_records;
drop policy if exists "manager delete training_records" on candidate.training_records;
create policy "auth read training_records" on candidate.training_records
  for select to authenticated using (candidate.is_authorized_user());
create policy "manager delete training_records" on candidate.training_records
  for delete to authenticated
  using (candidate.is_authorized_user() and candidate.is_manager());

-- Table privileges. Writes are RPC-only (append-only); manager DELETE per policy.
grant select, delete on candidate.training_records to authenticated;

-- ==== sql/51_training_manual_entry.sql ====
-- ============================================================================
--  Day Webster — Candidate Pipeline · Mandatory Training: manager manual entry
--  File: candidate-pipeline/sql/51_training_manual_entry.sql
--  Run AFTER 50.  Idempotent / additive.  STATUS: DRAFT — NOT YET APPLIED.
--
--  "Managers only can manually enter training dates." record_manual_training is
--  SECURITY DEFINER and hard-guarded on is_manager(): an ordinary compliance
--  officer cannot manual-enter (guard + no client write path). It records the
--  external evidence (when a path is supplied) and calls issue_training_record
--  (50) with source='manual' — issuing the DW cert + record + compliance hook and
--  an attributable, human-method verification_events row naming the manager,
--  the external provider and the evidence reference.
-- ============================================================================

create or replace function candidate.record_manual_training(
    p_candidate_id    uuid,
    p_module_id       uuid,
    p_completion_date date,
    p_score           numeric default null,
    p_provider        text    default null,
    p_evidence_path   text    default null)
returns table(id uuid, certificate_id text)
language plpgsql security definer
set search_path = candidate, public as $$
declare v_id uuid; v_cert text; v_req uuid; v_req_code text; v_item uuid;
begin
  -- Manager-only (managers include admins). Ordinary officers are refused.
  if not candidate.is_manager() then
    raise exception 'not authorized';
  end if;

  select r.rec_id, r.cert_id into v_id, v_cert
  from candidate.issue_training_record(
         p_candidate_id, p_module_id, 'manual', p_score, p_completion_date,
         null, p_provider, p_evidence_path) r;

  -- Link the uploaded external certificate (Round 2 UI uploads to candidate-docs
  -- and passes the path) to the module's requirement + the freshly-written item.
  if p_evidence_path is not null then
    select cr.id, cr.code into v_req, v_req_code
    from candidate.training_modules tm
    join candidate.compliance_requirements cr
      on cr.code = tm.requirement_code and cr.discipline_id is null and cr.specialty_id is null
    where tm.id = p_module_id;

    select tr.compliance_item_id into v_item
    from candidate.training_records tr where tr.id = v_id;

    insert into candidate.candidate_evidence
      (candidate_id, item_id, requirement_id, bucket, path, filename, uploaded_by)
    values
      (p_candidate_id, v_item, v_req, 'candidate-docs', p_evidence_path,
       'manual training evidence (' || coalesce(p_provider,'external') || ')', auth.uid());
  end if;

  return query select v_id, v_cert;
end $$;
revoke all on function candidate.record_manual_training(uuid, uuid, date, numeric, text, text) from public;
grant execute on function candidate.record_manual_training(uuid, uuid, date, numeric, text, text) to authenticated, service_role;

-- ==== sql/52_training_seed.sql ====
-- ============================================================================
--  Day Webster — Candidate Pipeline · Mandatory Training: catalogue seed
--  File: candidate-pipeline/sql/52_training_seed.sql
--  Run AFTER 47–51.  Idempotent.  STATUS: DRAFT — NOT YET APPLIED.
--
--  Seeds the full clinical catalogue (WFA RM6281): the 11 core CSTF subjects at
--  their clinical levels (blocking) + the 3 statutory/optional extras
--  (non-blocking), then wires them into the clinical requirement sets via
--  sync_training_requirements(). Two modules (Moving & Handling L2 and IPC L2)
--  are then FULLY AUTHORED end-to-end and published, so the
--  assign -> KB -> assess -> pass -> cert -> gate path is provable.
--
--  Every validity_months / level / question here is an EDITABLE DEFAULT pending
--  named-SME sign-off (see 47 header + TRAINING_CSTF_RESEARCH.md). The authored
--  KB is genuine but marked DRAFT-for-SME; sfh_accreditation_ref seeds NULL.
--  The other 12 modules stay catalogue-only (no published version) until authored.
-- ============================================================================

-- ── 1. The catalogue (14 modules). ON CONFLICT keeps re-runs a no-op; the 47
--       mirror trigger creates each module's compliance_requirement on insert. ─
insert into candidate.training_modules
  (code, title, framework, framework_subject, validity_months,
   requirement_code, set_criticality, is_core, delivery_mode)
values
  -- ── 11 core CSTF (clinical levels) — BLOCKING ──
  ('equality_diversity_hr',    'Equality, Diversity & Human Rights',            'CSTF',
     'Equality, Diversity and Human Rights',            36, 'train_equality_diversity_hr',    'blocking', true, 'elearning'),
  ('health_safety_welfare',    'Health, Safety & Welfare',                      'CSTF',
     'Health, Safety and Welfare',                      36, 'train_health_safety_welfare',    'blocking', true, 'elearning'),
  ('conflict_resolution',      'Conflict Resolution',                           'CSTF',
     'Conflict Resolution',                             36, 'train_conflict_resolution',      'blocking', true, 'elearning'),
  ('fire_safety',              'Fire Safety',                                   'CSTF',
     'Fire Safety',                                     12, 'train_fire_safety',              'blocking', true, 'elearning'),
  ('ipc_l2',                   'Infection Prevention & Control (Level 2)',      'CSTF',
     'Infection Prevention and Control (Level 2)',      12, 'train_ipc_l2',                   'blocking', true, 'elearning'),
  ('moving_handling_l2',       'Moving & Handling (Level 2)',                   'CSTF',
     'Moving and Handling (Level 2)',                   12, 'train_moving_handling_l2',       'blocking', true, 'elearning'),
  ('safeguarding_adults_l2',   'Safeguarding Adults (Level 2)',                 'CSTF',
     'Safeguarding Adults (Level 2)',                   36, 'train_safeguarding_adults_l2',   'blocking', true, 'elearning'),
  ('safeguarding_children_l2', 'Safeguarding Children (Level 2)',               'CSTF',
     'Safeguarding Children and Young People (Level 2)',36, 'train_safeguarding_children_l2', 'blocking', true, 'elearning'),
  ('information_governance',   'Information Governance / Data Security',        'CSTF',
     'Information Governance and Data Security',        12, 'train_information_governance',   'blocking', true, 'elearning'),
  ('prevent_radicalisation',   'Preventing Radicalisation (Prevent)',           'CSTF',
     'Preventing Radicalisation',                       36, 'train_prevent_radicalisation',   'blocking', true, 'elearning'),
  ('bls_adult_l2',             'Resuscitation - Adult Basic Life Support (Level 2)', 'CSTF',
     'Resuscitation - Adult Basic Life Support (Level 2)',12, 'train_bls_adult_l2',          'blocking', true, 'elearning'),
  -- ── extras (statutory / trust) — non-blocking (standard) ──
  ('oliver_mcgowan_t2',        'Oliver McGowan Mandatory Training (LD & Autism) Tier 2', 'Statutory (Health & Care Act 2022)',
     'Learning Disability and Autism (Tier 2)',         36, 'train_oliver_mcgowan_t2',        'standard', false, 'blended'),
  ('mca_dols',                 'Mental Capacity Act & DoLS',                    'Statutory',
     'Mental Capacity Act and Deprivation of Liberty Safeguards', 36, 'train_mca_dols',       'standard', false, 'elearning'),
  ('sepsis',                   'Sepsis Awareness & Recognition',                'Trust',
     'Sepsis',                                          12, 'train_sepsis',                   'standard', false, 'elearning')
on conflict (code) do nothing;

-- ── 2. Wire the active modules into the clinical requirement sets ────────────
select candidate.sync_training_requirements();

-- ── 3. Fully author + publish two seed modules (idempotent) ──────────────────
-- Moving & Handling L2.
do $$
declare v_module uuid; v_version uuid; q jsonb;
begin
  select id into v_module from candidate.training_modules where code = 'moving_handling_l2';
  if v_module is not null and (select current_version_id from candidate.training_modules where id = v_module) is null then
    v_version := candidate.save_module_version(v_module, $c$[
      {"heading":"About this module","body_md":"Moving and Handling Level 2 (people handling) for clinical and care staff. This is an EDITABLE DRAFT reconstructed from CSTF norms and is pending named-SME sign-off before it is treated as authoritative or accredited."},
      {"heading":"The law","body_md":"The Manual Handling Operations Regulations 1992 (as amended) require employers to avoid hazardous manual handling so far as is reasonably practicable, assess what cannot be avoided, and reduce the risk. The Health and Safety at Work etc. Act 1974 sets the overarching duty of care."},
      {"heading":"Assess before you move","body_md":"Use the TILE framework - Task, Individual, Load, Environment - and always check the person's own moving and handling risk assessment and care plan. Reassess dynamically as the situation changes."},
      {"heading":"Safe technique","body_md":"Keep the load close to your body, maintain the natural curve of your spine, bend at the knees and hips rather than the back, keep a stable base with feet shoulder-width apart, and never twist while carrying a load. Explain the move and gain the person's cooperation and consent."},
      {"heading":"Equipment","body_md":"Hoists transfer fully dependent people; slide sheets reduce friction when repositioning in bed. Always check the sling size and condition, ensure the sling and hoist are compatible, and never exceed the Safe Working Load. A faulty hoist must be removed from use and reported."},
      {"heading":"Never do this","body_md":"Discredited techniques such as the drag lift and the underarm (orthodox) lift are unsafe and must not be used. If a person begins to fall, do not try to catch them - guide them to the floor while protecting their head."}
    ]$c$::jsonb, null, false, null);

    for q in select value from jsonb_array_elements($qq$[
      {"stem":"Which UK regulations specifically govern manual handling at work?","options":[{"key":"a","text":"Manual Handling Operations Regulations 1992"},{"key":"b","text":"Data Protection Act 2018"},{"key":"c","text":"Regulatory Reform (Fire Safety) Order 2005"},{"key":"d","text":"Equality Act 2010"}],"correct_keys":["a"],"explanation":"MHOR 1992 (as amended) is the specific manual handling law.","sort_order":10},
      {"stem":"In the hierarchy of control for manual handling, what comes first?","options":[{"key":"a","text":"Provide back-support belts"},{"key":"b","text":"Avoid hazardous manual handling so far as is reasonably practicable"},{"key":"c","text":"Train staff to lift heavier loads"},{"key":"d","text":"Speed the task up"}],"correct_keys":["b"],"explanation":"Avoid first, then assess what cannot be avoided, then reduce the risk.","sort_order":20},
      {"stem":"What does the TILE assessment framework stand for?","options":[{"key":"a","text":"Task, Individual, Load, Environment"},{"key":"b","text":"Time, Injury, Lifting, Effort"},{"key":"c","text":"Technique, Instruction, Load, Equipment"},{"key":"d","text":"Task, Injury, Location, Equipment"}],"correct_keys":["a"],"explanation":"Task, Individual, Load, Environment.","sort_order":30},
      {"stem":"Before assisting a patient to move you should first:","options":[{"key":"a","text":"Ask a colleague to guess the weight"},{"key":"b","text":"Check the patient moving and handling risk assessment and care plan"},{"key":"c","text":"Lift quickly to minimise strain"},{"key":"d","text":"Remove any equipment from the area"}],"correct_keys":["b"],"explanation":"The individual risk assessment / care plan directs the safe method.","sort_order":40},
      {"stem":"Which is correct posture when handling a load?","options":[{"key":"a","text":"Keep the load at arm's length"},{"key":"b","text":"Keep the load close to your body"},{"key":"c","text":"Hold the load above your head"},{"key":"d","text":"Keep your knees locked straight"}],"correct_keys":["b"],"explanation":"Keeping the load close reduces the load on the spine.","sort_order":50},
      {"stem":"When lifting a light object from the floor you should:","options":[{"key":"a","text":"Bend from the waist with straight legs"},{"key":"b","text":"Bend the knees and hips and keep the back's natural curve"},{"key":"c","text":"Twist as you lift to save time"},{"key":"d","text":"Hold your breath and jerk the load up"}],"correct_keys":["b"],"explanation":"Bend at the knees and hips, not the back.","sort_order":60},
      {"stem":"Which equipment transfers a fully dependent patient between bed and chair?","options":[{"key":"a","text":"Slide sheet"},{"key":"b","text":"Hoist"},{"key":"c","text":"Handling belt"},{"key":"d","text":"Transfer board only"}],"correct_keys":["b"],"explanation":"A hoist is used for fully dependent transfers.","sort_order":70},
      {"stem":"Before using a hoist you must check that:","options":[{"key":"a","text":"The sling size and condition are correct and compatible with the hoist"},{"key":"b","text":"The battery is fully discharged"},{"key":"c","text":"Only one person is present"},{"key":"d","text":"The Safe Working Label has been removed"}],"correct_keys":["a"],"explanation":"Sling compatibility, size and condition are essential safety checks.","sort_order":80},
      {"stem":"What does Safe Working Load (SWL) mean?","options":[{"key":"a","text":"The average weight lifted per shift"},{"key":"b","text":"The maximum weight the equipment is rated to lift"},{"key":"c","text":"The weight of the hoist itself"},{"key":"d","text":"A guideline you may exceed briefly"}],"correct_keys":["b"],"explanation":"SWL is the maximum rated load and must never be exceeded.","sort_order":90},
      {"stem":"Which techniques are discredited and must NOT be used?","options":[{"key":"a","text":"The drag lift"},{"key":"b","text":"Using a slide sheet"},{"key":"c","text":"The underarm (orthodox) lift"},{"key":"d","text":"Using a hoist"}],"correct_keys":["a","c"],"explanation":"The drag lift and underarm/orthodox lift are unsafe and banned.","sort_order":100},
      {"stem":"If a patient starts to fall while you are assisting them, you should:","options":[{"key":"a","text":"Catch them to stop the fall"},{"key":"b","text":"Step away completely"},{"key":"c","text":"Guide them to the floor while protecting their head"},{"key":"d","text":"Lift them straight back up"}],"correct_keys":["c"],"explanation":"Do not try to catch a falling person; guide them down safely.","sort_order":110},
      {"stem":"Slide sheets are used to:","options":[{"key":"a","text":"Reduce friction when repositioning a patient in bed"},{"key":"b","text":"Lift a patient off the floor"},{"key":"c","text":"Replace a hoist sling"},{"key":"d","text":"Measure a patient's weight"}],"correct_keys":["a"],"explanation":"Slide sheets reduce friction and shear when repositioning.","sort_order":120},
      {"stem":"A mobile hoist is generally operated safely by:","options":[{"key":"a","text":"One member of staff"},{"key":"b","text":"Two trained members of staff"},{"key":"c","text":"The patient alone"},{"key":"d","text":"Any number, untrained"}],"correct_keys":["b"],"explanation":"Two trained staff are typically required for a mobile hoist transfer.","sort_order":130},
      {"stem":"You discover a hoist is faulty. You should:","options":[{"key":"a","text":"Keep using it carefully"},{"key":"b","text":"Remove it from use, label it and report it"},{"key":"c","text":"Repair it yourself"},{"key":"d","text":"Ignore it if it still moves"}],"correct_keys":["b"],"explanation":"Faulty equipment must be taken out of use and reported.","sort_order":140},
      {"stem":"The main injury risk to staff from poor manual handling is:","options":[{"key":"a","text":"Musculoskeletal injury, especially to the back"},{"key":"b","text":"Hearing loss"},{"key":"c","text":"Eye strain"},{"key":"d","text":"Skin infection"}],"correct_keys":["a"],"explanation":"Musculoskeletal (particularly back) injury is the primary risk.","sort_order":150},
      {"stem":"Dynamic risk assessment means:","options":[{"key":"a","text":"Assessing the risk once at the start of the day"},{"key":"b","text":"Continuously reassessing risk as the situation changes"},{"key":"c","text":"Letting the patient decide the method"},{"key":"d","text":"Only assessing after an incident"}],"correct_keys":["b"],"explanation":"Risk is reassessed continuously as conditions change.","sort_order":160},
      {"stem":"Good communication before a move includes:","options":[{"key":"a","text":"Moving without warning to avoid resistance"},{"key":"b","text":"Explaining the move and gaining consent and cooperation"},{"key":"c","text":"Talking only to your colleague"},{"key":"d","text":"Assuming the patient understands"}],"correct_keys":["b"],"explanation":"Explain and gain consent/cooperation from the person.","sort_order":170},
      {"stem":"Which individual factor increases manual handling risk?","options":[{"key":"a","text":"A pre-existing back injury or pregnancy"},{"key":"b","text":"Wearing flat shoes"},{"key":"c","text":"Having eaten breakfast"},{"key":"d","text":"Being right-handed"}],"correct_keys":["a"],"explanation":"Existing injury or pregnancy raises the individual's risk.","sort_order":180},
      {"stem":"A stable base for handling is achieved by:","options":[{"key":"a","text":"Keeping feet together"},{"key":"b","text":"Feet shoulder-width apart, one slightly forward"},{"key":"c","text":"Standing on tiptoe"},{"key":"d","text":"Crossing your legs"}],"correct_keys":["b"],"explanation":"Feet shoulder-width apart with one forward gives a stable base.","sort_order":190},
      {"stem":"Which of the following are good moving and handling practice? (select all)","options":[{"key":"a","text":"Keep the load close to your body"},{"key":"b","text":"Twist at the waist to turn with a load"},{"key":"c","text":"Assess the task before you move"},{"key":"d","text":"Hold your breath throughout the lift"}],"correct_keys":["a","c"],"explanation":"Keep the load close and assess first; never twist or hold your breath.","sort_order":200}
    ]$qq$::jsonb) loop
      perform candidate.add_training_question(v_version, q->>'stem', q->'options', q->'correct_keys', q->>'explanation', (q->>'sort_order')::int);
    end loop;

    perform candidate.submit_module_for_review(v_version);
    perform candidate.approve_module_version(v_version);
    perform candidate.publish_module_version(v_version);
  end if;
end $$;

-- Infection Prevention & Control L2.
do $$
declare v_module uuid; v_version uuid; q jsonb;
begin
  select id into v_module from candidate.training_modules where code = 'ipc_l2';
  if v_module is not null and (select current_version_id from candidate.training_modules where id = v_module) is null then
    v_version := candidate.save_module_version(v_module, $c$[
      {"heading":"About this module","body_md":"Infection Prevention and Control Level 2 for clinical and care staff. This is an EDITABLE DRAFT reconstructed from CSTF norms and is pending named-SME sign-off before it is treated as authoritative or accredited."},
      {"heading":"Standard precautions","body_md":"Standard (universal) precautions apply to the care of ALL patients at all times, regardless of known infection status: hand hygiene, appropriate PPE, safe handling and disposal of sharps, safe waste management, and cleaning/decontamination of equipment and the environment."},
      {"heading":"Hand hygiene","body_md":"Hand hygiene is the single most important measure to prevent healthcare-associated infection. Follow the WHO 5 Moments. Use alcohol hand rub on visibly clean hands; wash with soap and water when hands are visibly soiled and for organisms not killed by alcohol, such as Clostridioides difficile spores and norovirus. Be bare below the elbows."},
      {"heading":"PPE","body_md":"Select PPE by risk assessment. A common donning order is apron, then mask, then eye protection, then gloves; remove and dispose in reverse order performing hand hygiene before donning and after removing gloves. PPE is the last line of defence in the hierarchy of controls."},
      {"heading":"Sharps and waste","body_md":"Dispose of sharps immediately at the point of use into a sharps bin; never re-sheath needles. Infectious clinical waste goes into orange bags. After a sharps injury, encourage bleeding, wash under running water, cover, and report and seek occupational health advice immediately."},
      {"heading":"The chain of infection","body_md":"Infection requires an infectious agent, a reservoir, a portal of exit, a mode of transmission (contact, droplet or airborne), a portal of entry, and a susceptible host. Breaking any single link - most readily transmission, via hand hygiene - prevents infection. Aseptic Non Touch Technique (ANTT) protects key parts and key sites during procedures."}
    ]$c$::jsonb, null, false, null);

    for q in select value from jsonb_array_elements($qq$[
      {"stem":"What is the single most important measure to prevent healthcare-associated infection?","options":[{"key":"a","text":"Wearing gloves at all times"},{"key":"b","text":"Hand hygiene"},{"key":"c","text":"Giving antibiotics"},{"key":"d","text":"Isolating every patient"}],"correct_keys":["b"],"explanation":"Hand hygiene is the most important single IPC measure.","sort_order":10},
      {"stem":"Standard precautions apply to:","options":[{"key":"a","text":"Only patients with a known infection"},{"key":"b","text":"All patients regardless of known infection status"},{"key":"c","text":"Only patients in isolation"},{"key":"d","text":"Only surgical patients"}],"correct_keys":["b"],"explanation":"Standard precautions apply to the care of all patients at all times.","sort_order":20},
      {"stem":"When hands are visibly soiled you should use:","options":[{"key":"a","text":"Alcohol hand rub only"},{"key":"b","text":"Soap and water"},{"key":"c","text":"A dry paper towel"},{"key":"d","text":"Gloves without washing"}],"correct_keys":["b"],"explanation":"Visibly soiled hands must be washed with soap and water.","sort_order":30},
      {"stem":"Alcohol hand rub is NOT reliably effective against:","options":[{"key":"a","text":"Clostridioides difficile spores and norovirus"},{"key":"b","text":"Transient hand flora"},{"key":"c","text":"Most bacteria on clean hands"},{"key":"d","text":"Influenza virus on clean hands"}],"correct_keys":["a"],"explanation":"Spores (C. difficile) and norovirus require soap and water.","sort_order":40},
      {"stem":"How many WHO Moments for Hand Hygiene are there?","options":[{"key":"a","text":"Three"},{"key":"b","text":"Five"},{"key":"c","text":"Seven"},{"key":"d","text":"Ten"}],"correct_keys":["b"],"explanation":"The WHO 5 Moments for Hand Hygiene.","sort_order":50},
      {"stem":"Sharps should be disposed of:","options":[{"key":"a","text":"By re-sheathing then binning later"},{"key":"b","text":"Immediately at the point of use into a sharps bin"},{"key":"c","text":"In an orange clinical waste bag"},{"key":"d","text":"In general domestic waste"}],"correct_keys":["b"],"explanation":"Dispose immediately at point of use; never re-sheath.","sort_order":60},
      {"stem":"Your first action after a needlestick injury is to:","options":[{"key":"a","text":"Ignore it if the skin is unbroken"},{"key":"b","text":"Encourage bleeding and wash under running water"},{"key":"c","text":"Apply a plaster and continue"},{"key":"d","text":"Squeeze the wound tightly closed"}],"correct_keys":["b"],"explanation":"Encourage bleeding, wash, cover, then report and seek OH advice.","sort_order":70},
      {"stem":"Infectious (clinical) waste is placed in:","options":[{"key":"a","text":"Black bags"},{"key":"b","text":"Orange bags"},{"key":"c","text":"Clear bags"},{"key":"d","text":"A sharps bin"}],"correct_keys":["b"],"explanation":"Orange bags are for infectious clinical waste.","sort_order":80},
      {"stem":"Gloves should be changed:","options":[{"key":"a","text":"Once per shift"},{"key":"b","text":"Between patients and between tasks or body sites"},{"key":"c","text":"Only when torn"},{"key":"d","text":"Never, if washed"}],"correct_keys":["b"],"explanation":"Change gloves between patients and between tasks/body sites.","sort_order":90},
      {"stem":"When should hand hygiene be performed in relation to gloves?","options":[{"key":"a","text":"Only after removing gloves"},{"key":"b","text":"Only before donning gloves"},{"key":"c","text":"Both before donning and after removing gloves"},{"key":"d","text":"Gloves replace the need for hand hygiene"}],"correct_keys":["c"],"explanation":"Perform hand hygiene both before donning and after removing gloves.","sort_order":100},
      {"stem":"Aseptic Non Touch Technique (ANTT) aims to:","options":[{"key":"a","text":"Speed up procedures"},{"key":"b","text":"Prevent contamination of key parts and key sites"},{"key":"c","text":"Avoid the need for gloves"},{"key":"d","text":"Sterilise the whole room"}],"correct_keys":["b"],"explanation":"ANTT protects key parts/sites from contamination.","sort_order":110},
      {"stem":"A patient with suspected infectious diarrhoea should ideally be:","options":[{"key":"a","text":"Nursed in an open bay"},{"key":"b","text":"Isolated in a single room where possible"},{"key":"c","text":"Discharged immediately"},{"key":"d","text":"Moved between wards"}],"correct_keys":["b"],"explanation":"Isolate in a single room to reduce transmission.","sort_order":120},
      {"stem":"Bare below the elbows means:","options":[{"key":"a","text":"No wristwatch, no rings except a plain band, sleeves rolled up"},{"key":"b","text":"Wearing a long-sleeved gown at all times"},{"key":"c","text":"Rolling sleeves down for warmth"},{"key":"d","text":"Wearing a wristwatch to time tasks"}],"correct_keys":["a"],"explanation":"Bare below the elbows supports effective hand hygiene.","sort_order":130},
      {"stem":"The correct contact time and dilution for a disinfectant are found:","options":[{"key":"a","text":"By personal preference"},{"key":"b","text":"On the manufacturer's instructions and local policy"},{"key":"c","text":"By smell"},{"key":"d","text":"They do not matter"}],"correct_keys":["b"],"explanation":"Follow manufacturer instructions and local policy.","sort_order":140},
      {"stem":"Which is a recognised route of transmission?","options":[{"key":"a","text":"Contact"},{"key":"b","text":"Emotional"},{"key":"c","text":"Financial"},{"key":"d","text":"Legal"}],"correct_keys":["a"],"explanation":"Contact (also droplet and airborne) are transmission routes.","sort_order":150},
      {"stem":"In the hierarchy of controls, PPE is:","options":[{"key":"a","text":"The first and only control needed"},{"key":"b","text":"The last line of defence"},{"key":"c","text":"Never necessary"},{"key":"d","text":"A substitute for hand hygiene"}],"correct_keys":["b"],"explanation":"PPE is the last line of defence, not the first.","sort_order":160},
      {"stem":"Colonisation differs from infection because colonisation:","options":[{"key":"a","text":"Always causes severe illness"},{"key":"b","text":"Has no signs or symptoms of disease"},{"key":"c","text":"Cannot be transmitted"},{"key":"d","text":"Only occurs in children"}],"correct_keys":["b"],"explanation":"Colonisation is presence without signs/symptoms of disease.","sort_order":170},
      {"stem":"A common safe order for donning PPE is:","options":[{"key":"a","text":"Gloves, then apron, then mask"},{"key":"b","text":"Apron, then mask, then eye protection, then gloves"},{"key":"c","text":"Eye protection last, gloves first"},{"key":"d","text":"Any order is fine"}],"correct_keys":["b"],"explanation":"Apron, mask, eye protection, then gloves is a common safe sequence.","sort_order":180},
      {"stem":"The chain of infection is most readily broken at which link in daily practice?","options":[{"key":"a","text":"The susceptible host"},{"key":"b","text":"The infectious agent"},{"key":"c","text":"The mode of transmission, via hand hygiene"},{"key":"d","text":"The reservoir"}],"correct_keys":["c"],"explanation":"Breaking transmission (hand hygiene) is the most practical link.","sort_order":190},
      {"stem":"Which of the following are standard (universal) precautions? (select all)","options":[{"key":"a","text":"Hand hygiene"},{"key":"b","text":"Reusing single-use gloves between patients"},{"key":"c","text":"Safe sharps disposal"},{"key":"d","text":"Appropriate use of PPE"}],"correct_keys":["a","c","d"],"explanation":"Hand hygiene, safe sharps disposal and appropriate PPE are standard precautions; single-use gloves are never reused.","sort_order":200}
    ]$qq$::jsonb) loop
      perform candidate.add_training_question(v_version, q->>'stem', q->'options', q->'correct_keys', q->>'explanation', (q->>'sort_order')::int);
    end loop;

    perform candidate.submit_module_for_review(v_version);
    perform candidate.approve_module_version(v_version);
    perform candidate.publish_module_version(v_version);
  end if;
end $$;

