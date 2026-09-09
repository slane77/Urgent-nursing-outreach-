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
