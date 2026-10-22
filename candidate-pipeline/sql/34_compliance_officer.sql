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
