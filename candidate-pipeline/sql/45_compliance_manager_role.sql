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
