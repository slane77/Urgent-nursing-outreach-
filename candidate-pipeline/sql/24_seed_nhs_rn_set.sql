-- ============================================================================
--  Day Webster — Candidate Pipeline · Seed: NHS Registered Nurse set (v1)
--  File: candidate-pipeline/sql/24_seed_nhs_rn_set.sql
--  Run AFTER 22, 23, and 13 (catalogue). Idempotent.  STATUS: DRAFT.
--
--  One versioned set composed from already-seeded compliance_requirements
--  codes. tier (A–E/H) = automation tier (unchanged); criticality below is the
--  placement-blocking dimension. Maps the six NHS ECS checks -> 'blocking'.
--    ECS1 Identity            -> proof_of_address        blocking
--    ECS2 Right to work       -> right_to_work           blocking
--    ECS3 Registration/quals  -> nmc_registration,
--                                qualification_cert       blocking
--    ECS4 References (3yr)     -> references_3yr          blocking
--    ECS5 Occupational health -> occupational_health,
--                                immunisations            blocking
--    ECS6 DBS                  -> dbs_enhanced            blocking
--    CSTF training            -> mandatory_training      standard  [DECISION]
--    Internal / conditional   -> cv, overseas_police_check advisory
-- ============================================================================

insert into candidate.requirement_sets (code, version, name, sector, discipline_id, status, notes)
select 'NHS_RN', 1, 'NHS Registered Nurse (RM6281 / NHS ECS)', 'nhs',
       (select id from candidate.disciplines where code = 'nursing'),
       'active', 'Phase 0 seed: six NHS Employment Check Standards + CSTF.'
on conflict (code, version) do nothing;

-- Compose from catalogue codes. Global reqs (discipline_id is null) + nursing.
insert into candidate.requirement_set_items
  (set_id, requirement_id, criticality, required_override, conditional, sort_order)
select rs.id, cr.id, v.criticality, v.required_override, v.conditional, v.so
from candidate.requirement_sets rs
join (values
  -- code,                 discipline_code, criticality, required_override, conditional,                    sort
  ('right_to_work',        null,            'blocking', null::boolean,  null::jsonb,                       10),
  ('proof_of_address',     null,            'blocking', null,           null,                              20),
  ('references_3yr',       null,            'blocking', null,           null,                              30),
  ('nmc_registration',     'nursing',       'blocking', null,           null,                              40),
  ('qualification_cert',   'nursing',       'blocking', null,           null,                              50),
  ('dbs_enhanced',         'nursing',       'blocking', null,           null,                              60),
  ('occupational_health',  'nursing',       'blocking', null,           null,                              70),
  ('immunisations',        'nursing',       'blocking', null,           null,                              80),
  ('mandatory_training',   'nursing',       'standard', null,           null,                              90),
  ('cv',                   null,            'advisory', null,           null,                             100),
  ('overseas_police_check',null,            'advisory', false,          '{"if":"overseas_history"}'::jsonb,110)
) as v(code, disc, criticality, required_override, conditional, so) on true
join candidate.compliance_requirements cr
  on cr.code = v.code
 and cr.discipline_id is not distinct from
     (select id from candidate.disciplines where code = v.disc)
where rs.code = 'NHS_RN' and rs.version = 1
on conflict (set_id, requirement_id) do nothing;
