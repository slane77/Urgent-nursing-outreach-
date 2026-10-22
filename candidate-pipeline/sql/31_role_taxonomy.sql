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
