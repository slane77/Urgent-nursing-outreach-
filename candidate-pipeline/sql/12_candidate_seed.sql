-- ============================================================================
--  Day Webster — Candidate Pipeline  ·  Seed: disciplines & specialties
--  File: candidate-pipeline/sql/12_candidate_seed.sql
--  Run AFTER 10 + 11. Idempotent (on conflict do nothing).
--
--  STATUS: DRAFT — NOT YET APPLIED. For review only.
--
--  Day-one business areas from the brief:
--    Nursing (Theatres, Midwifery, Primary Care), Doctors (all), Complex Care,
--    AHP (all specialities), Insurance (John Williams), Children's Services
--    (carers + registered managers), Care Homes (incl. registered managers).
--  Specialty lists are starting points — extend as rows, never as code.
-- ============================================================================

insert into candidate.disciplines (code, name, regulator, brand, sort_order) values
  ('nursing',    'Nursing',           'NMC',    null,             10),
  ('doctors',    'Doctors',           'GMC',    null,             20),
  ('complex_care','Complex Care',     'CQC',    null,             30),
  ('ahp',        'AHP',               'HCPC',   null,             40),
  ('insurance',  'Insurance',         null,     'John Williams',  50),
  ('childrens',  'Children''s Services','Ofsted',null,            60),
  ('care_homes', 'Care Homes',        'CQC',    null,             70)
on conflict (code) do nothing;

-- Helper inserts per discipline ---------------------------------------------
-- Nursing
insert into candidate.specialties (discipline_id, code, name, regulator_override, sort_order)
select d.id, v.code, v.name, v.reg, v.so
from candidate.disciplines d,
  (values
    ('general',     'General Nursing', null,   10),
    ('theatres',    'Theatres',        null,   20),  -- ODP sub-roles -> HCPC, see below
    ('theatres_odp','Theatres (ODP)',  'HCPC', 25),
    ('midwifery',   'Midwifery',       null,   30),
    ('primary_care','Primary Care',    null,   40)
  ) as v(code,name,reg,so)
where d.code = 'nursing'
on conflict (discipline_id, code) do nothing;

-- Doctors (all aspects — common grades; extend freely)
insert into candidate.specialties (discipline_id, code, name, sort_order)
select d.id, v.code, v.name, v.so
from candidate.disciplines d,
  (values
    ('general',    'General / Locum',      10),
    ('gp',         'GP',                   20),
    ('specialty',  'Specialty Doctor',     30),
    ('consultant', 'Consultant',           40)
  ) as v(code,name,so)
where d.code = 'doctors'
on conflict (discipline_id, code) do nothing;

-- Complex Care
insert into candidate.specialties (discipline_id, code, name, sort_order)
select d.id, 'general', 'Complex Care', 10
from candidate.disciplines d where d.code = 'complex_care'
on conflict (discipline_id, code) do nothing;

-- AHP (all specialities — common HCPC professions; extend freely)
insert into candidate.specialties (discipline_id, code, name, sort_order)
select d.id, v.code, v.name, v.so
from candidate.disciplines d,
  (values
    ('physio',      'Physiotherapy',                10),
    ('ot',          'Occupational Therapy',         20),
    ('slt',         'Speech & Language Therapy',    30),
    ('dietetics',   'Dietetics',                    40),
    ('radiography', 'Radiography',                  50),
    ('paramedic',   'Paramedic',                    60),
    ('odp',         'Operating Department Practitioner', 70),
    ('podiatry',    'Podiatry',                     80)
  ) as v(code,name,so)
where d.code = 'ahp'
on conflict (discipline_id, code) do nothing;

-- Insurance (John Williams brand)
insert into candidate.specialties (discipline_id, code, name, sort_order)
select d.id, v.code, v.name, v.so
from candidate.disciplines d,
  (values
    ('underwriter', 'Underwriter',  10),
    ('broker',      'Broker',       20),
    ('claims',      'Claims',       30)
  ) as v(code,name,so)
where d.code = 'insurance'
on conflict (discipline_id, code) do nothing;

-- Children's Services (carers + registered managers)
insert into candidate.specialties (discipline_id, code, name, is_registered_manager, sort_order)
select d.id, v.code, v.name, v.rm, v.so
from candidate.disciplines d,
  (values
    ('carer',           'Children''s Home Carer',          false, 10),
    ('senior',          'Senior Residential Worker',       false, 20),
    ('registered_mgr',  'Registered Manager (Children''s)', true, 30)
  ) as v(code,name,rm,so)
where d.code = 'childrens'
on conflict (discipline_id, code) do nothing;

-- Care Homes (incl. registered managers)
insert into candidate.specialties (discipline_id, code, name, is_registered_manager, sort_order)
select d.id, v.code, v.name, v.rm, v.so
from candidate.disciplines d,
  (values
    ('care_assistant',  'Care Assistant',              false, 10),
    ('senior_carer',    'Senior Carer',                false, 20),
    ('nurse',           'Nurse (Care Home)',           false, 30),
    ('registered_mgr',  'Registered Manager (Care Home)', true, 40)
  ) as v(code,name,rm,so)
where d.code = 'care_homes'
on conflict (discipline_id, code) do nothing;

-- A starter inbound source so the agent has somewhere to file day-one arrivals
insert into candidate.sources (code, name, channel_type, default_consent_basis) values
  ('inbound_web', 'Inbound web enquiry', 'inbound',  'consent'),
  ('referral',    'Referral',            'referral', 'consent')
on conflict (code) do nothing;
