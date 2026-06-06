-- ============================================================================
--  Day Webster — Candidate Pipeline · Seed: compliance requirements (config)
--  File: candidate-pipeline/sql/13_compliance_requirements.sql
--  Run AFTER 10–12. Idempotent.
--
--  STATUS: DRAFT — NOT YET APPLIED. For review only.
--
--  This is the "pluggable slot" filled in — a first per-discipline requirement
--  set derived from the Compliance Automation Feasibility Assessment. Each row
--  carries the assessment's automation tier (A–H), a deterministic expiry rule,
--  a coverage rule where relevant, and a needs_human flag for the judgement
--  calls that must never be auto-decided (§7 / the gradient principle).
--
--  These are STARTING POINTS — refine against the live compliance project.
--  New requirement = a new row, never a code change (the §2 thesis).
--
--  expiry_rule shapes used:
--    {"type":"upload_plus","years":N}        - N years from upload
--    {"type":"issue_plus","years":N}         - N years from the document's issue
--    {"type":"issue_plus","years":1,"recency_months":3} - PoA: <=3mo at reg, then +1yr
--    {"type":"issue_plus_days","days":1461}  - DBS webcheck: cert issue + 4yr + 1day
--    {"type":"from_certificate"}             - read the expiry off the cert
--    null                                    - does not expire (record/recon only)
--  coverage_rule: {"type":"continuous_history","years":3,"reconcile":"cv"}
-- ============================================================================

-- ── GLOBAL (apply to every discipline; discipline_id = null) ────────────────
insert into candidate.compliance_requirements
  (discipline_id, code, name, tier, required, expiry_rule, coverage_rule, needs_human, sort_order) values
  (null, 'cv',                 'Up-to-date CV',                'A', true,  '{"type":"upload_plus","years":1}'::jsonb, null, false, 10),
  (null, 'right_to_work',      'Right to work',                'C', true,  null, null, true,  20),
  (null, 'proof_of_address',   'Proof of address',             'B', true,  '{"type":"issue_plus","years":1,"recency_months":3}'::jsonb, null, false, 30),
  (null, 'references_3yr',     'References (continuous 3-year history)', 'D', true, null, '{"type":"continuous_history","years":3,"reconcile":"cv"}'::jsonb, true, 40),
  (null, 'overseas_police_check', 'Overseas police check (if overseas history)', 'H', false, null, null, true, 45)
on conflict (discipline_id, specialty_id, code) do nothing;

-- ── Helper to add a discipline-scoped requirement ───────────────────────────
-- (written out explicitly per row for clarity / easy editing)

-- NURSING (NMC) ------------------------------------------------------------
insert into candidate.compliance_requirements (discipline_id, code, name, tier, required, expiry_rule, coverage_rule, needs_human, sort_order)
values
 ((select id from candidate.disciplines where code='nursing'), 'nmc_registration',   'NMC registration (revalidation)', 'C', true,  null, null, true,  50),
 ((select id from candidate.disciplines where code='nursing'), 'qualification_cert', 'Qualification certificate',       'D', true,  null, null, true,  60),
 ((select id from candidate.disciplines where code='nursing'), 'dbs_enhanced',       'Enhanced DBS',                    'B', true,  '{"type":"issue_plus_days","days":1461}'::jsonb, null, false, 70),
 ((select id from candidate.disciplines where code='nursing'), 'occupational_health','Occupational health clearance',   'A', true,  '{"type":"from_certificate"}'::jsonb, null, false, 80),
 ((select id from candidate.disciplines where code='nursing'), 'immunisations',      'Immunisations',                   'A', true,  '{"type":"from_certificate"}'::jsonb, null, false, 90),
 ((select id from candidate.disciplines where code='nursing'), 'mandatory_training', 'Mandatory training',              'A', true,  '{"type":"from_certificate"}'::jsonb, null, false, 100)
on conflict (discipline_id, specialty_id, code) do nothing;

-- DOCTORS (GMC) ------------------------------------------------------------
insert into candidate.compliance_requirements (discipline_id, code, name, tier, required, expiry_rule, coverage_rule, needs_human, sort_order)
values
 ((select id from candidate.disciplines where code='doctors'), 'gmc_registration',   'GMC registration (revalidation)', 'C', true,  null, null, true,  50),
 ((select id from candidate.disciplines where code='doctors'), 'qualification_cert', 'Qualification certificate',       'D', true,  null, null, true,  60),
 ((select id from candidate.disciplines where code='doctors'), 'indemnity',          'Medical indemnity insurance',     'D', true,  '{"type":"issue_plus","years":1}'::jsonb, null, true,  65),
 ((select id from candidate.disciplines where code='doctors'), 'dbs_enhanced',       'Enhanced DBS',                    'B', true,  '{"type":"issue_plus_days","days":1461}'::jsonb, null, false, 70),
 ((select id from candidate.disciplines where code='doctors'), 'occupational_health','Occupational health clearance',   'A', true,  '{"type":"from_certificate"}'::jsonb, null, false, 80),
 ((select id from candidate.disciplines where code='doctors'), 'immunisations',      'Immunisations',                   'A', true,  '{"type":"from_certificate"}'::jsonb, null, false, 90),
 ((select id from candidate.disciplines where code='doctors'), 'mandatory_training', 'Mandatory training',              'A', true,  '{"type":"from_certificate"}'::jsonb, null, false, 100)
on conflict (discipline_id, specialty_id, code) do nothing;

-- AHP (HCPC) ---------------------------------------------------------------
insert into candidate.compliance_requirements (discipline_id, code, name, tier, required, expiry_rule, coverage_rule, needs_human, sort_order)
values
 ((select id from candidate.disciplines where code='ahp'), 'hcpc_registration',  'HCPC registration',         'C', true,  null, null, true,  50),
 ((select id from candidate.disciplines where code='ahp'), 'qualification_cert', 'Qualification certificate', 'D', true,  null, null, true,  60),
 ((select id from candidate.disciplines where code='ahp'), 'dbs_enhanced',       'Enhanced DBS',              'B', true,  '{"type":"issue_plus_days","days":1461}'::jsonb, null, false, 70),
 ((select id from candidate.disciplines where code='ahp'), 'occupational_health','Occupational health clearance', 'A', true, '{"type":"from_certificate"}'::jsonb, null, false, 80),
 ((select id from candidate.disciplines where code='ahp'), 'immunisations',      'Immunisations',             'A', true,  '{"type":"from_certificate"}'::jsonb, null, false, 90),
 ((select id from candidate.disciplines where code='ahp'), 'mandatory_training', 'Mandatory training',        'A', true,  '{"type":"from_certificate"}'::jsonb, null, false, 100)
on conflict (discipline_id, specialty_id, code) do nothing;

-- COMPLEX CARE (CQC) -------------------------------------------------------
insert into candidate.compliance_requirements (discipline_id, code, name, tier, required, expiry_rule, coverage_rule, needs_human, sort_order)
values
 ((select id from candidate.disciplines where code='complex_care'), 'dbs_enhanced',      'Enhanced DBS',               'B', true,  '{"type":"issue_plus_days","days":1461}'::jsonb, null, false, 70),
 ((select id from candidate.disciplines where code='complex_care'), 'care_certificate',  'Care Certificate',           'A', true,  null, null, false, 55),
 ((select id from candidate.disciplines where code='complex_care'), 'occupational_health','Occupational health clearance','A', true, '{"type":"from_certificate"}'::jsonb, null, false, 80),
 ((select id from candidate.disciplines where code='complex_care'), 'mandatory_training','Mandatory training',          'A', true,  '{"type":"from_certificate"}'::jsonb, null, false, 100)
on conflict (discipline_id, specialty_id, code) do nothing;

-- CARE HOMES (CQC) ---------------------------------------------------------
insert into candidate.compliance_requirements (discipline_id, code, name, tier, required, expiry_rule, coverage_rule, needs_human, sort_order)
values
 ((select id from candidate.disciplines where code='care_homes'), 'dbs_enhanced_adults','Enhanced DBS (adults barred list)', 'B', true, '{"type":"issue_plus_days","days":1461}'::jsonb, null, false, 70),
 ((select id from candidate.disciplines where code='care_homes'), 'care_certificate',   'Care Certificate',           'A', true,  null, null, false, 55),
 ((select id from candidate.disciplines where code='care_homes'), 'mandatory_training', 'Mandatory training',         'A', true,  '{"type":"from_certificate"}'::jsonb, null, false, 100),
 ((select id from candidate.disciplines where code='care_homes'), 'occupational_health','Occupational health clearance','A', true, '{"type":"from_certificate"}'::jsonb, null, false, 80)
on conflict (discipline_id, specialty_id, code) do nothing;

-- CHILDREN'S SERVICES (Ofsted) ---------------------------------------------
insert into candidate.compliance_requirements (discipline_id, code, name, tier, required, expiry_rule, coverage_rule, needs_human, sort_order)
values
 ((select id from candidate.disciplines where code='childrens'), 'dbs_enhanced_children','Enhanced DBS (children''s barred list)', 'B', true, '{"type":"issue_plus_days","days":1461}'::jsonb, null, false, 70),
 ((select id from candidate.disciplines where code='childrens'), 'qualification_cert',   'Level 3 Diploma (Children & Young People)', 'C', true, null, null, true, 60),
 ((select id from candidate.disciplines where code='childrens'), 'mandatory_training',   'Mandatory training',        'A', true,  '{"type":"from_certificate"}'::jsonb, null, false, 100),
 ((select id from candidate.disciplines where code='childrens'), 'occupational_health',  'Occupational health clearance','A', true, '{"type":"from_certificate"}'::jsonb, null, false, 80)
on conflict (discipline_id, specialty_id, code) do nothing;

-- INSURANCE (John Williams) — non-clinical --------------------------------
insert into candidate.compliance_requirements (discipline_id, code, name, tier, required, expiry_rule, coverage_rule, needs_human, sort_order)
values
 ((select id from candidate.disciplines where code='insurance'), 'cii_qualification',  'CII / professional qualification', 'C', false, null, null, false, 50),
 ((select id from candidate.disciplines where code='insurance'), 'financial_reference','Financial / credit reference',     'B', false, null, null, true,  60)
on conflict (discipline_id, specialty_id, code) do nothing;

-- REGISTERED MANAGERS (specialty-scoped extras) ----------------------------
-- Children's home registered manager
insert into candidate.compliance_requirements (discipline_id, specialty_id, code, name, tier, required, needs_human, sort_order)
select d.id, s.id, v.code, v.name, v.tier, true, v.nh, v.so
from candidate.disciplines d
join candidate.specialties s on s.discipline_id = d.id and s.code = 'registered_mgr'
cross join (values
  ('level5_diploma',        'Level 5 Diploma (Leadership & Management)', 'C', false, 110),
  ('fit_person_declaration','Fit-person declaration / interview',        'H', true,  120)
) as v(code,name,tier,nh,so)
where d.code in ('childrens','care_homes')
on conflict (discipline_id, specialty_id, code) do nothing;
