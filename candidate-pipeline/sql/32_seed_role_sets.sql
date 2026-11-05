-- ============================================================================
--  Day Webster — Candidate Pipeline · Seed: role requirement sets + map fix
--  File: candidate-pipeline/sql/32_seed_role_sets.sql
--  Run AFTER 13, 22-27, 30, 31. Idempotent.  STATUS: DRAFT — NOT YET APPLIED.
--
--  Composes three more versioned sets from the seeded catalogue codes and wires
--  the (discipline, specialty) -> set map, THEN fixes the Phase-1 map bug.
--
--  Locked decisions honoured:
--    · NHS_MIDWIFE is a distinct set with composition identical to NHS_RN
--      (file 24) for now — diverge later by publishing a v2, never by editing.
--    · NHS_ODP is nursing-scoped but REUSES the ahp-scoped `hcpc_registration`
--      catalogue row (DRY) for its registration item; its clinical checks
--      (quals/dbs/oh/immunisations/training) are nursing-scoped.
--    · NHS_GP = NHS_DOCTOR + the National Performers List (blocking).
--    · enp/anp/psychiatry are specialties that INHERIT their discipline's base
--      set (NHS_RN / NHS_DOCTOR) — no map row, so the base resolves.
--
--  THE PHASE-1 BUG (fixed in section (c)):
--    27_seed_requirement_sets.sql maps nursing/hca -> NHS_HCA via a LEFT JOIN to
--    candidate.specialties, but the `hca` specialty did not exist yet (it is
--    added in file 31). The left join therefore produced specialty_id = NULL, so
--    NHS_HCA landed as a DISCIPLINE-WIDE row at priority 200 — outranking the
--    nursing-wide NHS_RN (priority 100). Result: EVERY nurse resolved to
--    NHS_HCA. Now that file 31 has added the specialties, we delete that bogus
--    row and insert the correct specialty-scoped rows.
-- ============================================================================

-- ── (a) New catalogue requirement: National Performers List (doctors) ───────
-- NULL-safe idempotency (per 27): specialty_id is NULL and the catalogue unique
-- key treats NULLs as distinct, so ON CONFLICT never fires — guard with NOT
-- EXISTS instead. criticality defaults to 'blocking' (added in 22).
insert into candidate.compliance_requirements
  (discipline_id, code, name, tier, required, expiry_rule, coverage_rule, needs_human, sort_order)
select (select id from candidate.disciplines where code = 'doctors'),
       'performers_list', 'National Performers List (NHS England)', 'C', true, null, null, true, 45
where not exists (
  select 1 from candidate.compliance_requirements
  where code = 'performers_list'
    and discipline_id = (select id from candidate.disciplines where code = 'doctors')
    and specialty_id is null
);

-- ── (b) The sets (all version 1) ────────────────────────────────────────────
insert into candidate.requirement_sets (code, version, name, sector, discipline_id, status, notes)
select v.code, 1, v.name, v.sector,
       (select id from candidate.disciplines where code = v.disc),
       'active', v.notes
from (values
  ('NHS_MIDWIFE', 'NHS Midwife',                            'nhs', 'nursing', 'Phase 1: composition identical to NHS_RN pending midwifery divergence.'),
  ('NHS_ODP',     'NHS Operating Department Practitioner',  'nhs', 'nursing', 'Phase 1: HCPC-registered ODP; reuses ahp hcpc_registration, nursing-scoped clinical checks.'),
  ('NHS_GP',      'NHS General Practitioner',               'nhs', 'doctors', 'Phase 1: NHS doctor checks + National Performers List.')
) as v(code, name, sector, disc, notes)
on conflict (code, version) do nothing;

-- ── Compose set items from catalogue codes (27's is-not-distinct-from join) ──
-- Join key: (code, discipline, specialty). disc/spec NULL matches a global /
-- discipline-scoped catalogue row. `conditional` carried like file 24 so
-- NHS_MIDWIFE stays byte-for-byte identical to NHS_RN.
insert into candidate.requirement_set_items
  (set_id, requirement_id, criticality, required_override, conditional, sort_order)
select rs.id, cr.id, v.criticality, v.req_override, v.conditional, v.so
from (values
  -- set_code,       code,                    disc,           spec,        criticality, req_override,  conditional,                        sort
  -- NHS_MIDWIFE (identical composition to NHS_RN / file 24)
  ('NHS_MIDWIFE',   'right_to_work',          null::text,     null::text,  'blocking',  null::boolean, null::jsonb,                        10),
  ('NHS_MIDWIFE',   'proof_of_address',       null,           null,        'blocking',  null,          null,                               20),
  ('NHS_MIDWIFE',   'references_3yr',          null,           null,        'blocking',  null,          null,                               30),
  ('NHS_MIDWIFE',   'nmc_registration',        'nursing',      null,        'blocking',  null,          null,                               40),
  ('NHS_MIDWIFE',   'qualification_cert',      'nursing',      null,        'blocking',  null,          null,                               50),
  ('NHS_MIDWIFE',   'dbs_enhanced',            'nursing',      null,        'blocking',  null,          null,                               60),
  ('NHS_MIDWIFE',   'occupational_health',     'nursing',      null,        'blocking',  null,          null,                               70),
  ('NHS_MIDWIFE',   'immunisations',           'nursing',      null,        'blocking',  null,          null,                               80),
  ('NHS_MIDWIFE',   'mandatory_training',      'nursing',      null,        'standard',  null,          null,                               90),
  ('NHS_MIDWIFE',   'cv',                      null,           null,        'advisory',  null,          null,                              100),
  ('NHS_MIDWIFE',   'overseas_police_check',   null,           null,        'advisory',  false,         '{"if":"overseas_history"}'::jsonb,110),
  -- NHS_ODP (AHP_HCPC shape; registration DRY-reuses ahp hcpc_registration)
  ('NHS_ODP',       'right_to_work',           null,           null,        'blocking',  null,          null,                               10),
  ('NHS_ODP',       'proof_of_address',        null,           null,        'blocking',  null,          null,                               20),
  ('NHS_ODP',       'references_3yr',          null,           null,        'blocking',  null,          null,                               30),
  ('NHS_ODP',       'hcpc_registration',       'ahp',          null,        'blocking',  null,          null,                               40),
  ('NHS_ODP',       'qualification_cert',      'nursing',      null,        'blocking',  null,          null,                               50),
  ('NHS_ODP',       'dbs_enhanced',            'nursing',      null,        'blocking',  null,          null,                               60),
  ('NHS_ODP',       'occupational_health',     'nursing',      null,        'blocking',  null,          null,                               70),
  ('NHS_ODP',       'immunisations',           'nursing',      null,        'blocking',  null,          null,                               80),
  ('NHS_ODP',       'mandatory_training',      'nursing',      null,        'standard',  null,          null,                               90),
  ('NHS_ODP',       'cv',                      null,           null,        'advisory',  null,          null,                              100),
  ('NHS_ODP',       'overseas_police_check',   null,           null,        'advisory',  false,         null,                              110),
  -- NHS_GP (NHS_DOCTOR items + performers_list)
  ('NHS_GP',        'right_to_work',           null,           null,        'blocking',  null,          null,                               10),
  ('NHS_GP',        'proof_of_address',        null,           null,        'blocking',  null,          null,                               20),
  ('NHS_GP',        'references_3yr',          null,           null,        'blocking',  null,          null,                               30),
  ('NHS_GP',        'gmc_registration',        'doctors',      null,        'blocking',  null,          null,                               40),
  ('NHS_GP',        'performers_list',         'doctors',      null,        'blocking',  null,          null,                               45),
  ('NHS_GP',        'qualification_cert',      'doctors',      null,        'blocking',  null,          null,                               50),
  ('NHS_GP',        'indemnity',               'doctors',      null,        'blocking',  null,          null,                               55),
  ('NHS_GP',        'dbs_enhanced',            'doctors',      null,        'blocking',  null,          null,                               60),
  ('NHS_GP',        'occupational_health',     'doctors',      null,        'blocking',  null,          null,                               70),
  ('NHS_GP',        'immunisations',           'doctors',      null,        'blocking',  null,          null,                               80),
  ('NHS_GP',        'mandatory_training',      'doctors',      null,        'standard',  null,          null,                               90),
  ('NHS_GP',        'cv',                      null,           null,        'advisory',  null,          null,                              100),
  ('NHS_GP',        'overseas_police_check',   null,           null,        'advisory',  false,         null,                              110)
) as v(set_code, code, disc, spec, criticality, req_override, conditional, so)
join candidate.requirement_sets rs
  on rs.code = v.set_code and rs.version = 1
join candidate.compliance_requirements cr
  on cr.code = v.code
 and cr.discipline_id is not distinct from
     (select id from candidate.disciplines where code = v.disc)
 and cr.specialty_id is not distinct from
     (select s.id from candidate.specialties s
        join candidate.disciplines d2 on d2.id = s.discipline_id
       where d2.code = v.disc and s.code = v.spec)
on conflict (set_id, requirement_id) do nothing;

-- ── (c) Fix the Phase-1 map bug, then wire the specialty rows ────────────────
-- 1. Delete the bogus DISCIPLINE-WIDE NHS_HCA row (specialty_id IS NULL) that
--    27 inserted before the `hca` specialty existed.
delete from candidate.requirement_set_map m
using candidate.disciplines d, candidate.requirement_sets rs
where m.discipline_id = d.id and d.code = 'nursing'
  and m.set_id = rs.id and rs.code = 'NHS_HCA'
  and m.specialty_id is null;

-- 2. Insert the correct SPECIALTY-scoped base rows (priority 200 beats the
--    discipline-wide base at 100). INNER JOIN to specialties so a missing
--    specialty is skipped rather than re-creating a null-specialty row. The
--    ahp/odp row is belt-and-suspenders (odp exists under ahp since file 12).
insert into candidate.requirement_set_map (discipline_id, specialty_id, set_id, add_on, priority)
select d.id, s.id, rs.id, false, 200
from (values
  ('nursing', 'hca',          'NHS_HCA'),
  ('nursing', 'midwifery',    'NHS_MIDWIFE'),
  ('nursing', 'theatres_odp', 'NHS_ODP'),
  ('doctors', 'gp',           'NHS_GP'),
  ('ahp',     'odp',          'NHS_ODP')
) as v(disc, spec, set_code)
join candidate.disciplines d on d.code = v.disc
join candidate.specialties s on s.discipline_id = d.id and s.code = v.spec
join candidate.requirement_sets rs on rs.code = v.set_code and rs.version = 1
where not exists (
  select 1 from candidate.requirement_set_map m
  where m.discipline_id = d.id
    and m.specialty_id is not distinct from s.id
    and m.set_id = rs.id
);
