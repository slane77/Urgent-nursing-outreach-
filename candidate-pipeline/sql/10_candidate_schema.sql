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
