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
