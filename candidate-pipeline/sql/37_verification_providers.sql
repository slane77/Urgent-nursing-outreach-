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
