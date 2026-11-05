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
