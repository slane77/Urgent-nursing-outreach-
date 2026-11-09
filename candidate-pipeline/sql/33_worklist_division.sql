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
