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
