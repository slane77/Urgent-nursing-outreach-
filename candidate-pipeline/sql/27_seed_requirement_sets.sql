-- ============================================================================
--  Day Webster — Candidate Pipeline · Compliance Phase 1: seed requirement sets
--  File: candidate-pipeline/sql/27_seed_requirement_sets.sql
--  Run AFTER 22-26 and 13 (catalogue). Idempotent.  STATUS: DRAFT — NOT APPLIED.
--
--  Composes one versioned set per job type from the already-seeded catalogue
--  codes in 13_compliance_requirements.sql, and seeds requirement_set_map so
--  candidates auto-assign on qualification (file 26). NHS_RN is seeded by 24.
--
--  D5: HCAs need a Care Certificate but 13_ only scopes `care_certificate` to
--  complex_care / care_homes. We add a nursing-scoped row here so NHS_HCA can
--  require it (cleaner than cross-scoping an existing row).
--
--  Every referenced (code, discipline, specialty) was reconciled against
--  13_compliance_requirements.sql: 'rtw' in the design table == catalogue code
--  `right_to_work`; DBS variants are `dbs_enhanced` (nursing/doctors/ahp/
--  complex_care), `dbs_enhanced_adults` (care_homes), `dbs_enhanced_children`
--  (childrens); `fit_person_declaration` is specialty-scoped to registered_mgr.
--  INSURANCE `financial_reference` is required=false in the catalogue, so the set
--  carries required_override=true to make it a real (standard/amber) requirement.
-- ============================================================================

-- ── D5: nursing-scoped Care Certificate (for the HCA set) ───────────────────
-- NB: the catalogue unique key is (discipline_id, specialty_id, code); here
-- specialty_id is NULL and Postgres treats NULLs as distinct, so an ON CONFLICT
-- on that key would never fire (and would insert a duplicate on re-run). Guard
-- idempotency with an explicit NOT EXISTS instead.
insert into candidate.compliance_requirements
  (discipline_id, code, name, tier, required, expiry_rule, coverage_rule, needs_human, sort_order)
select (select id from candidate.disciplines where code = 'nursing'),
       'care_certificate', 'Care Certificate', 'A', true, null, null, false, 55
where not exists (
  select 1 from candidate.compliance_requirements
  where code = 'care_certificate'
    and discipline_id = (select id from candidate.disciplines where code = 'nursing')
    and specialty_id is null
);

-- ── The sets (all version 1) ────────────────────────────────────────────────
insert into candidate.requirement_sets (code, version, name, sector, discipline_id, status, notes)
select v.code, 1, v.name, v.sector,
       (select id from candidate.disciplines where code = v.disc),
       'active', v.notes
from (values
  ('NHS_HCA',           'NHS Healthcare Assistant',              'nhs',       'nursing',      'Phase 1: NHS HCA checks + Care Certificate.'),
  ('NHS_DOCTOR',        'NHS Doctor / Locum',                    'nhs',       'doctors',      'Phase 1: NHS doctor checks + GMC + indemnity.'),
  ('AHP_HCPC',          'AHP (HCPC registered)',                 'nhs',       'ahp',          'Phase 1: NHS AHP checks + HCPC.'),
  ('COMPLEX_CARE',      'Complex Care (CQC)',                    'care',      'complex_care', 'Phase 1: complex care package.'),
  ('CARE_HOME',         'Care Home (CQC)',                       'care',      'care_homes',   'Phase 1: care home package (adults barred DBS).'),
  ('CHILDRENS',         'Children''s Services (Ofsted)',         'childrens', 'childrens',    'Phase 1: children''s services package (children barred DBS).'),
  ('INSURANCE',         'Insurance (John Williams)',             'insurance', 'insurance',    'Phase 1: non-clinical insurance package.'),
  ('REG_MGR_CHILDRENS', 'Registered Manager add-on (Children''s)','childrens','childrens',    'Phase 1 add-on: fit-person declaration.'),
  ('REG_MGR_CARE_HOME', 'Registered Manager add-on (Care Home)', 'care',      'care_homes',   'Phase 1 add-on: fit-person declaration.')
) as v(code, name, sector, disc, notes)
on conflict (code, version) do nothing;

-- ── Compose the set items from catalogue codes ──────────────────────────────
-- Join key: (code, discipline, specialty). disc/spec NULL matches a global /
-- discipline-scoped catalogue row via `is not distinct from`.
insert into candidate.requirement_set_items
  (set_id, requirement_id, criticality, required_override, sort_order)
select rs.id, cr.id, v.criticality, v.req_override, v.so
from (values
  -- set_code,            code,                    disc,           spec,             criticality, req_override, sort
  -- NHS_HCA (nursing/hca base)
  ('NHS_HCA',            'right_to_work',          null::text,     null::text,       'blocking',  null::boolean,  10),
  ('NHS_HCA',            'proof_of_address',       null,           null,             'blocking',  null,           20),
  ('NHS_HCA',            'references_3yr',         null,           null,             'blocking',  null,           30),
  ('NHS_HCA',            'care_certificate',       'nursing',      null,             'blocking',  null,           55),
  ('NHS_HCA',            'dbs_enhanced',           'nursing',      null,             'blocking',  null,           60),
  ('NHS_HCA',            'occupational_health',    'nursing',      null,             'blocking',  null,           70),
  ('NHS_HCA',            'immunisations',          'nursing',      null,             'blocking',  null,           80),
  ('NHS_HCA',            'mandatory_training',     'nursing',      null,             'standard',  null,           90),
  ('NHS_HCA',            'cv',                     null,           null,             'advisory',  null,          100),
  -- NHS_DOCTOR
  ('NHS_DOCTOR',         'right_to_work',          null,           null,             'blocking',  null,           10),
  ('NHS_DOCTOR',         'proof_of_address',       null,           null,             'blocking',  null,           20),
  ('NHS_DOCTOR',         'references_3yr',         null,           null,             'blocking',  null,           30),
  ('NHS_DOCTOR',         'gmc_registration',       'doctors',      null,             'blocking',  null,           40),
  ('NHS_DOCTOR',         'qualification_cert',     'doctors',      null,             'blocking',  null,           50),
  ('NHS_DOCTOR',         'indemnity',              'doctors',      null,             'blocking',  null,           55),
  ('NHS_DOCTOR',         'dbs_enhanced',           'doctors',      null,             'blocking',  null,           60),
  ('NHS_DOCTOR',         'occupational_health',    'doctors',      null,             'blocking',  null,           70),
  ('NHS_DOCTOR',         'immunisations',          'doctors',      null,             'blocking',  null,           80),
  ('NHS_DOCTOR',         'mandatory_training',     'doctors',      null,             'standard',  null,           90),
  ('NHS_DOCTOR',         'cv',                     null,           null,             'advisory',  null,          100),
  ('NHS_DOCTOR',         'overseas_police_check',  null,           null,             'advisory',  false,         110),
  -- AHP_HCPC
  ('AHP_HCPC',           'right_to_work',          null,           null,             'blocking',  null,           10),
  ('AHP_HCPC',           'proof_of_address',       null,           null,             'blocking',  null,           20),
  ('AHP_HCPC',           'references_3yr',         null,           null,             'blocking',  null,           30),
  ('AHP_HCPC',           'hcpc_registration',      'ahp',          null,             'blocking',  null,           40),
  ('AHP_HCPC',           'qualification_cert',     'ahp',          null,             'blocking',  null,           50),
  ('AHP_HCPC',           'dbs_enhanced',           'ahp',          null,             'blocking',  null,           60),
  ('AHP_HCPC',           'occupational_health',    'ahp',          null,             'blocking',  null,           70),
  ('AHP_HCPC',           'immunisations',          'ahp',          null,             'blocking',  null,           80),
  ('AHP_HCPC',           'mandatory_training',     'ahp',          null,             'standard',  null,           90),
  ('AHP_HCPC',           'cv',                     null,           null,             'advisory',  null,          100),
  ('AHP_HCPC',           'overseas_police_check',  null,           null,             'advisory',  false,         110),
  -- COMPLEX_CARE
  ('COMPLEX_CARE',       'right_to_work',          null,           null,             'blocking',  null,           10),
  ('COMPLEX_CARE',       'proof_of_address',       null,           null,             'blocking',  null,           20),
  ('COMPLEX_CARE',       'references_3yr',         null,           null,             'blocking',  null,           30),
  ('COMPLEX_CARE',       'care_certificate',       'complex_care', null,             'blocking',  null,           55),
  ('COMPLEX_CARE',       'dbs_enhanced',           'complex_care', null,             'blocking',  null,           60),
  ('COMPLEX_CARE',       'occupational_health',    'complex_care', null,             'blocking',  null,           70),
  ('COMPLEX_CARE',       'mandatory_training',     'complex_care', null,             'standard',  null,           90),
  ('COMPLEX_CARE',       'cv',                     null,           null,             'advisory',  null,          100),
  -- CARE_HOME
  ('CARE_HOME',          'right_to_work',          null,           null,             'blocking',  null,           10),
  ('CARE_HOME',          'proof_of_address',       null,           null,             'blocking',  null,           20),
  ('CARE_HOME',          'references_3yr',         null,           null,             'blocking',  null,           30),
  ('CARE_HOME',          'care_certificate',       'care_homes',   null,             'blocking',  null,           55),
  ('CARE_HOME',          'dbs_enhanced_adults',    'care_homes',   null,             'blocking',  null,           60),
  ('CARE_HOME',          'occupational_health',    'care_homes',   null,             'blocking',  null,           70),
  ('CARE_HOME',          'mandatory_training',     'care_homes',   null,             'standard',  null,           90),
  ('CARE_HOME',          'cv',                     null,           null,             'advisory',  null,          100),
  -- CHILDRENS
  ('CHILDRENS',          'right_to_work',          null,           null,             'blocking',  null,           10),
  ('CHILDRENS',          'proof_of_address',       null,           null,             'blocking',  null,           20),
  ('CHILDRENS',          'references_3yr',         null,           null,             'blocking',  null,           30),
  ('CHILDRENS',          'qualification_cert',     'childrens',    null,             'blocking',  null,           50),
  ('CHILDRENS',          'dbs_enhanced_children',  'childrens',    null,             'blocking',  null,           60),
  ('CHILDRENS',          'mandatory_training',     'childrens',    null,             'standard',  null,           90),
  ('CHILDRENS',          'cv',                     null,           null,             'advisory',  null,          100),
  -- INSURANCE (non-clinical). financial_reference is catalogue-optional => force required.
  ('INSURANCE',          'right_to_work',          null,           null,             'blocking',  null,           10),
  ('INSURANCE',          'proof_of_address',       null,           null,             'standard',  null,           20),
  ('INSURANCE',          'financial_reference',    'insurance',    null,             'standard',  true,           60),
  ('INSURANCE',          'cii_qualification',      'insurance',    null,             'advisory',  null,           50),
  ('INSURANCE',          'cv',                     null,           null,             'advisory',  null,          100),
  -- REG_MGR add-ons (specialty-scoped fit_person_declaration)
  ('REG_MGR_CHILDRENS',  'fit_person_declaration', 'childrens',    'registered_mgr', 'blocking',  null,          120),
  ('REG_MGR_CARE_HOME',  'fit_person_declaration', 'care_homes',   'registered_mgr', 'blocking',  null,          120)
) as v(set_code, code, disc, spec, criticality, req_override, so)
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

-- ── requirement_set_map: (discipline, specialty) -> set ─────────────────────
-- Base rows (specialty null except HCA); add-ons flagged. NHS_RN stays the
-- nursing discipline-wide base; hca specialty overrides it to NHS_HCA.
insert into candidate.requirement_set_map (discipline_id, specialty_id, set_id, add_on, priority)
select d.id, s.id, rs.id, v.add_on, v.priority
from (values
  ('nursing',      null::text,        'NHS_RN',            false, 100),
  ('nursing',      'hca',             'NHS_HCA',           false, 200),
  ('doctors',      null,              'NHS_DOCTOR',        false, 100),
  ('ahp',          null,              'AHP_HCPC',          false, 100),
  ('complex_care', null,              'COMPLEX_CARE',      false, 100),
  ('care_homes',   null,              'CARE_HOME',         false, 100),
  ('childrens',    null,              'CHILDRENS',         false, 100),
  ('insurance',    null,              'INSURANCE',         false, 100),
  ('childrens',    'registered_mgr',  'REG_MGR_CHILDRENS', true,  100),
  ('care_homes',   'registered_mgr',  'REG_MGR_CARE_HOME', true,  100)
) as v(disc, spec, set_code, add_on, priority)
join candidate.disciplines d on d.code = v.disc
left join candidate.specialties s on s.discipline_id = d.id and s.code = v.spec
join candidate.requirement_sets rs on rs.code = v.set_code and rs.version = 1
where not exists (
  select 1 from candidate.requirement_set_map m
  where m.discipline_id = d.id
    and m.specialty_id is not distinct from s.id
    and m.set_id = rs.id
);
