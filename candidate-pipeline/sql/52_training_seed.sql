-- ============================================================================
--  Day Webster — Candidate Pipeline · Mandatory Training: catalogue seed
--  File: candidate-pipeline/sql/52_training_seed.sql
--  Run AFTER 47–51.  Idempotent.  STATUS: DRAFT — NOT YET APPLIED.
--
--  Seeds the full clinical catalogue (WFA RM6281): the 11 core CSTF subjects at
--  their clinical levels (blocking) + the 3 statutory/optional extras
--  (non-blocking), then wires them into the clinical requirement sets via
--  sync_training_requirements(). Two modules (Moving & Handling L2 and IPC L2)
--  are then FULLY AUTHORED end-to-end and published, so the
--  assign -> KB -> assess -> pass -> cert -> gate path is provable.
--
--  Every validity_months / level / question here is an EDITABLE DEFAULT pending
--  named-SME sign-off (see 47 header + TRAINING_CSTF_RESEARCH.md). The authored
--  KB is genuine but marked DRAFT-for-SME; sfh_accreditation_ref seeds NULL.
--  The other 12 modules stay catalogue-only (no published version) until authored.
-- ============================================================================

-- ── 1. The catalogue (14 modules). ON CONFLICT keeps re-runs a no-op; the 47
--       mirror trigger creates each module's compliance_requirement on insert. ─
insert into candidate.training_modules
  (code, title, framework, framework_subject, validity_months,
   requirement_code, set_criticality, is_core, delivery_mode)
values
  -- ── 11 core CSTF (clinical levels) — BLOCKING ──
  ('equality_diversity_hr',    'Equality, Diversity & Human Rights',            'CSTF',
     'Equality, Diversity and Human Rights',            36, 'train_equality_diversity_hr',    'blocking', true, 'elearning'),
  ('health_safety_welfare',    'Health, Safety & Welfare',                      'CSTF',
     'Health, Safety and Welfare',                      36, 'train_health_safety_welfare',    'blocking', true, 'elearning'),
  ('conflict_resolution',      'Conflict Resolution',                           'CSTF',
     'Conflict Resolution',                             36, 'train_conflict_resolution',      'blocking', true, 'elearning'),
  ('fire_safety',              'Fire Safety',                                   'CSTF',
     'Fire Safety',                                     12, 'train_fire_safety',              'blocking', true, 'elearning'),
  ('ipc_l2',                   'Infection Prevention & Control (Level 2)',      'CSTF',
     'Infection Prevention and Control (Level 2)',      12, 'train_ipc_l2',                   'blocking', true, 'elearning'),
  ('moving_handling_l2',       'Moving & Handling (Level 2)',                   'CSTF',
     'Moving and Handling (Level 2)',                   12, 'train_moving_handling_l2',       'blocking', true, 'elearning'),
  ('safeguarding_adults_l2',   'Safeguarding Adults (Level 2)',                 'CSTF',
     'Safeguarding Adults (Level 2)',                   36, 'train_safeguarding_adults_l2',   'blocking', true, 'elearning'),
  ('safeguarding_children_l2', 'Safeguarding Children (Level 2)',               'CSTF',
     'Safeguarding Children and Young People (Level 2)',36, 'train_safeguarding_children_l2', 'blocking', true, 'elearning'),
  ('information_governance',   'Information Governance / Data Security',        'CSTF',
     'Information Governance and Data Security',        12, 'train_information_governance',   'blocking', true, 'elearning'),
  ('prevent_radicalisation',   'Preventing Radicalisation (Prevent)',           'CSTF',
     'Preventing Radicalisation',                       36, 'train_prevent_radicalisation',   'blocking', true, 'elearning'),
  ('bls_adult_l2',             'Resuscitation - Adult Basic Life Support (Level 2)', 'CSTF',
     'Resuscitation - Adult Basic Life Support (Level 2)',12, 'train_bls_adult_l2',          'blocking', true, 'elearning'),
  -- ── extras (statutory / trust) — non-blocking (standard) ──
  ('oliver_mcgowan_t2',        'Oliver McGowan Mandatory Training (LD & Autism) Tier 2', 'Statutory (Health & Care Act 2022)',
     'Learning Disability and Autism (Tier 2)',         36, 'train_oliver_mcgowan_t2',        'standard', false, 'blended'),
  ('mca_dols',                 'Mental Capacity Act & DoLS',                    'Statutory',
     'Mental Capacity Act and Deprivation of Liberty Safeguards', 36, 'train_mca_dols',       'standard', false, 'elearning'),
  ('sepsis',                   'Sepsis Awareness & Recognition',                'Trust',
     'Sepsis',                                          12, 'train_sepsis',                   'standard', false, 'elearning')
on conflict (code) do nothing;

-- ── 2. Wire the active modules into the clinical requirement sets ────────────
select candidate.sync_training_requirements();

-- ── 3. Fully author + publish two seed modules (idempotent) ──────────────────
-- Moving & Handling L2.
do $$
declare v_module uuid; v_version uuid; q jsonb;
begin
  select id into v_module from candidate.training_modules where code = 'moving_handling_l2';
  if v_module is not null and (select current_version_id from candidate.training_modules where id = v_module) is null then
    v_version := candidate.save_module_version(v_module, $c$[
      {"heading":"About this module","body_md":"Moving and Handling Level 2 (people handling) for clinical and care staff. This is an EDITABLE DRAFT reconstructed from CSTF norms and is pending named-SME sign-off before it is treated as authoritative or accredited."},
      {"heading":"The law","body_md":"The Manual Handling Operations Regulations 1992 (as amended) require employers to avoid hazardous manual handling so far as is reasonably practicable, assess what cannot be avoided, and reduce the risk. The Health and Safety at Work etc. Act 1974 sets the overarching duty of care."},
      {"heading":"Assess before you move","body_md":"Use the TILE framework - Task, Individual, Load, Environment - and always check the person's own moving and handling risk assessment and care plan. Reassess dynamically as the situation changes."},
      {"heading":"Safe technique","body_md":"Keep the load close to your body, maintain the natural curve of your spine, bend at the knees and hips rather than the back, keep a stable base with feet shoulder-width apart, and never twist while carrying a load. Explain the move and gain the person's cooperation and consent."},
      {"heading":"Equipment","body_md":"Hoists transfer fully dependent people; slide sheets reduce friction when repositioning in bed. Always check the sling size and condition, ensure the sling and hoist are compatible, and never exceed the Safe Working Load. A faulty hoist must be removed from use and reported."},
      {"heading":"Never do this","body_md":"Discredited techniques such as the drag lift and the underarm (orthodox) lift are unsafe and must not be used. If a person begins to fall, do not try to catch them - guide them to the floor while protecting their head."}
    ]$c$::jsonb, null, false, null);

    for q in select value from jsonb_array_elements($qq$[
      {"stem":"Which UK regulations specifically govern manual handling at work?","options":[{"key":"a","text":"Manual Handling Operations Regulations 1992"},{"key":"b","text":"Data Protection Act 2018"},{"key":"c","text":"Regulatory Reform (Fire Safety) Order 2005"},{"key":"d","text":"Equality Act 2010"}],"correct_keys":["a"],"explanation":"MHOR 1992 (as amended) is the specific manual handling law.","sort_order":10},
      {"stem":"In the hierarchy of control for manual handling, what comes first?","options":[{"key":"a","text":"Provide back-support belts"},{"key":"b","text":"Avoid hazardous manual handling so far as is reasonably practicable"},{"key":"c","text":"Train staff to lift heavier loads"},{"key":"d","text":"Speed the task up"}],"correct_keys":["b"],"explanation":"Avoid first, then assess what cannot be avoided, then reduce the risk.","sort_order":20},
      {"stem":"What does the TILE assessment framework stand for?","options":[{"key":"a","text":"Task, Individual, Load, Environment"},{"key":"b","text":"Time, Injury, Lifting, Effort"},{"key":"c","text":"Technique, Instruction, Load, Equipment"},{"key":"d","text":"Task, Injury, Location, Equipment"}],"correct_keys":["a"],"explanation":"Task, Individual, Load, Environment.","sort_order":30},
      {"stem":"Before assisting a patient to move you should first:","options":[{"key":"a","text":"Ask a colleague to guess the weight"},{"key":"b","text":"Check the patient moving and handling risk assessment and care plan"},{"key":"c","text":"Lift quickly to minimise strain"},{"key":"d","text":"Remove any equipment from the area"}],"correct_keys":["b"],"explanation":"The individual risk assessment / care plan directs the safe method.","sort_order":40},
      {"stem":"Which is correct posture when handling a load?","options":[{"key":"a","text":"Keep the load at arm's length"},{"key":"b","text":"Keep the load close to your body"},{"key":"c","text":"Hold the load above your head"},{"key":"d","text":"Keep your knees locked straight"}],"correct_keys":["b"],"explanation":"Keeping the load close reduces the load on the spine.","sort_order":50},
      {"stem":"When lifting a light object from the floor you should:","options":[{"key":"a","text":"Bend from the waist with straight legs"},{"key":"b","text":"Bend the knees and hips and keep the back's natural curve"},{"key":"c","text":"Twist as you lift to save time"},{"key":"d","text":"Hold your breath and jerk the load up"}],"correct_keys":["b"],"explanation":"Bend at the knees and hips, not the back.","sort_order":60},
      {"stem":"Which equipment transfers a fully dependent patient between bed and chair?","options":[{"key":"a","text":"Slide sheet"},{"key":"b","text":"Hoist"},{"key":"c","text":"Handling belt"},{"key":"d","text":"Transfer board only"}],"correct_keys":["b"],"explanation":"A hoist is used for fully dependent transfers.","sort_order":70},
      {"stem":"Before using a hoist you must check that:","options":[{"key":"a","text":"The sling size and condition are correct and compatible with the hoist"},{"key":"b","text":"The battery is fully discharged"},{"key":"c","text":"Only one person is present"},{"key":"d","text":"The Safe Working Label has been removed"}],"correct_keys":["a"],"explanation":"Sling compatibility, size and condition are essential safety checks.","sort_order":80},
      {"stem":"What does Safe Working Load (SWL) mean?","options":[{"key":"a","text":"The average weight lifted per shift"},{"key":"b","text":"The maximum weight the equipment is rated to lift"},{"key":"c","text":"The weight of the hoist itself"},{"key":"d","text":"A guideline you may exceed briefly"}],"correct_keys":["b"],"explanation":"SWL is the maximum rated load and must never be exceeded.","sort_order":90},
      {"stem":"Which techniques are discredited and must NOT be used?","options":[{"key":"a","text":"The drag lift"},{"key":"b","text":"Using a slide sheet"},{"key":"c","text":"The underarm (orthodox) lift"},{"key":"d","text":"Using a hoist"}],"correct_keys":["a","c"],"explanation":"The drag lift and underarm/orthodox lift are unsafe and banned.","sort_order":100},
      {"stem":"If a patient starts to fall while you are assisting them, you should:","options":[{"key":"a","text":"Catch them to stop the fall"},{"key":"b","text":"Step away completely"},{"key":"c","text":"Guide them to the floor while protecting their head"},{"key":"d","text":"Lift them straight back up"}],"correct_keys":["c"],"explanation":"Do not try to catch a falling person; guide them down safely.","sort_order":110},
      {"stem":"Slide sheets are used to:","options":[{"key":"a","text":"Reduce friction when repositioning a patient in bed"},{"key":"b","text":"Lift a patient off the floor"},{"key":"c","text":"Replace a hoist sling"},{"key":"d","text":"Measure a patient's weight"}],"correct_keys":["a"],"explanation":"Slide sheets reduce friction and shear when repositioning.","sort_order":120},
      {"stem":"A mobile hoist is generally operated safely by:","options":[{"key":"a","text":"One member of staff"},{"key":"b","text":"Two trained members of staff"},{"key":"c","text":"The patient alone"},{"key":"d","text":"Any number, untrained"}],"correct_keys":["b"],"explanation":"Two trained staff are typically required for a mobile hoist transfer.","sort_order":130},
      {"stem":"You discover a hoist is faulty. You should:","options":[{"key":"a","text":"Keep using it carefully"},{"key":"b","text":"Remove it from use, label it and report it"},{"key":"c","text":"Repair it yourself"},{"key":"d","text":"Ignore it if it still moves"}],"correct_keys":["b"],"explanation":"Faulty equipment must be taken out of use and reported.","sort_order":140},
      {"stem":"The main injury risk to staff from poor manual handling is:","options":[{"key":"a","text":"Musculoskeletal injury, especially to the back"},{"key":"b","text":"Hearing loss"},{"key":"c","text":"Eye strain"},{"key":"d","text":"Skin infection"}],"correct_keys":["a"],"explanation":"Musculoskeletal (particularly back) injury is the primary risk.","sort_order":150},
      {"stem":"Dynamic risk assessment means:","options":[{"key":"a","text":"Assessing the risk once at the start of the day"},{"key":"b","text":"Continuously reassessing risk as the situation changes"},{"key":"c","text":"Letting the patient decide the method"},{"key":"d","text":"Only assessing after an incident"}],"correct_keys":["b"],"explanation":"Risk is reassessed continuously as conditions change.","sort_order":160},
      {"stem":"Good communication before a move includes:","options":[{"key":"a","text":"Moving without warning to avoid resistance"},{"key":"b","text":"Explaining the move and gaining consent and cooperation"},{"key":"c","text":"Talking only to your colleague"},{"key":"d","text":"Assuming the patient understands"}],"correct_keys":["b"],"explanation":"Explain and gain consent/cooperation from the person.","sort_order":170},
      {"stem":"Which individual factor increases manual handling risk?","options":[{"key":"a","text":"A pre-existing back injury or pregnancy"},{"key":"b","text":"Wearing flat shoes"},{"key":"c","text":"Having eaten breakfast"},{"key":"d","text":"Being right-handed"}],"correct_keys":["a"],"explanation":"Existing injury or pregnancy raises the individual's risk.","sort_order":180},
      {"stem":"A stable base for handling is achieved by:","options":[{"key":"a","text":"Keeping feet together"},{"key":"b","text":"Feet shoulder-width apart, one slightly forward"},{"key":"c","text":"Standing on tiptoe"},{"key":"d","text":"Crossing your legs"}],"correct_keys":["b"],"explanation":"Feet shoulder-width apart with one forward gives a stable base.","sort_order":190},
      {"stem":"Which of the following are good moving and handling practice? (select all)","options":[{"key":"a","text":"Keep the load close to your body"},{"key":"b","text":"Twist at the waist to turn with a load"},{"key":"c","text":"Assess the task before you move"},{"key":"d","text":"Hold your breath throughout the lift"}],"correct_keys":["a","c"],"explanation":"Keep the load close and assess first; never twist or hold your breath.","sort_order":200}
    ]$qq$::jsonb) loop
      perform candidate.add_training_question(v_version, q->>'stem', q->'options', q->'correct_keys', q->>'explanation', (q->>'sort_order')::int);
    end loop;

    perform candidate.submit_module_for_review(v_version);
    perform candidate.approve_module_version(v_version);
    perform candidate.publish_module_version(v_version);
  end if;
end $$;

-- Infection Prevention & Control L2.
do $$
declare v_module uuid; v_version uuid; q jsonb;
begin
  select id into v_module from candidate.training_modules where code = 'ipc_l2';
  if v_module is not null and (select current_version_id from candidate.training_modules where id = v_module) is null then
    v_version := candidate.save_module_version(v_module, $c$[
      {"heading":"About this module","body_md":"Infection Prevention and Control Level 2 for clinical and care staff. This is an EDITABLE DRAFT reconstructed from CSTF norms and is pending named-SME sign-off before it is treated as authoritative or accredited."},
      {"heading":"Standard precautions","body_md":"Standard (universal) precautions apply to the care of ALL patients at all times, regardless of known infection status: hand hygiene, appropriate PPE, safe handling and disposal of sharps, safe waste management, and cleaning/decontamination of equipment and the environment."},
      {"heading":"Hand hygiene","body_md":"Hand hygiene is the single most important measure to prevent healthcare-associated infection. Follow the WHO 5 Moments. Use alcohol hand rub on visibly clean hands; wash with soap and water when hands are visibly soiled and for organisms not killed by alcohol, such as Clostridioides difficile spores and norovirus. Be bare below the elbows."},
      {"heading":"PPE","body_md":"Select PPE by risk assessment. A common donning order is apron, then mask, then eye protection, then gloves; remove and dispose in reverse order performing hand hygiene before donning and after removing gloves. PPE is the last line of defence in the hierarchy of controls."},
      {"heading":"Sharps and waste","body_md":"Dispose of sharps immediately at the point of use into a sharps bin; never re-sheath needles. Infectious clinical waste goes into orange bags. After a sharps injury, encourage bleeding, wash under running water, cover, and report and seek occupational health advice immediately."},
      {"heading":"The chain of infection","body_md":"Infection requires an infectious agent, a reservoir, a portal of exit, a mode of transmission (contact, droplet or airborne), a portal of entry, and a susceptible host. Breaking any single link - most readily transmission, via hand hygiene - prevents infection. Aseptic Non Touch Technique (ANTT) protects key parts and key sites during procedures."}
    ]$c$::jsonb, null, false, null);

    for q in select value from jsonb_array_elements($qq$[
      {"stem":"What is the single most important measure to prevent healthcare-associated infection?","options":[{"key":"a","text":"Wearing gloves at all times"},{"key":"b","text":"Hand hygiene"},{"key":"c","text":"Giving antibiotics"},{"key":"d","text":"Isolating every patient"}],"correct_keys":["b"],"explanation":"Hand hygiene is the most important single IPC measure.","sort_order":10},
      {"stem":"Standard precautions apply to:","options":[{"key":"a","text":"Only patients with a known infection"},{"key":"b","text":"All patients regardless of known infection status"},{"key":"c","text":"Only patients in isolation"},{"key":"d","text":"Only surgical patients"}],"correct_keys":["b"],"explanation":"Standard precautions apply to the care of all patients at all times.","sort_order":20},
      {"stem":"When hands are visibly soiled you should use:","options":[{"key":"a","text":"Alcohol hand rub only"},{"key":"b","text":"Soap and water"},{"key":"c","text":"A dry paper towel"},{"key":"d","text":"Gloves without washing"}],"correct_keys":["b"],"explanation":"Visibly soiled hands must be washed with soap and water.","sort_order":30},
      {"stem":"Alcohol hand rub is NOT reliably effective against:","options":[{"key":"a","text":"Clostridioides difficile spores and norovirus"},{"key":"b","text":"Transient hand flora"},{"key":"c","text":"Most bacteria on clean hands"},{"key":"d","text":"Influenza virus on clean hands"}],"correct_keys":["a"],"explanation":"Spores (C. difficile) and norovirus require soap and water.","sort_order":40},
      {"stem":"How many WHO Moments for Hand Hygiene are there?","options":[{"key":"a","text":"Three"},{"key":"b","text":"Five"},{"key":"c","text":"Seven"},{"key":"d","text":"Ten"}],"correct_keys":["b"],"explanation":"The WHO 5 Moments for Hand Hygiene.","sort_order":50},
      {"stem":"Sharps should be disposed of:","options":[{"key":"a","text":"By re-sheathing then binning later"},{"key":"b","text":"Immediately at the point of use into a sharps bin"},{"key":"c","text":"In an orange clinical waste bag"},{"key":"d","text":"In general domestic waste"}],"correct_keys":["b"],"explanation":"Dispose immediately at point of use; never re-sheath.","sort_order":60},
      {"stem":"Your first action after a needlestick injury is to:","options":[{"key":"a","text":"Ignore it if the skin is unbroken"},{"key":"b","text":"Encourage bleeding and wash under running water"},{"key":"c","text":"Apply a plaster and continue"},{"key":"d","text":"Squeeze the wound tightly closed"}],"correct_keys":["b"],"explanation":"Encourage bleeding, wash, cover, then report and seek OH advice.","sort_order":70},
      {"stem":"Infectious (clinical) waste is placed in:","options":[{"key":"a","text":"Black bags"},{"key":"b","text":"Orange bags"},{"key":"c","text":"Clear bags"},{"key":"d","text":"A sharps bin"}],"correct_keys":["b"],"explanation":"Orange bags are for infectious clinical waste.","sort_order":80},
      {"stem":"Gloves should be changed:","options":[{"key":"a","text":"Once per shift"},{"key":"b","text":"Between patients and between tasks or body sites"},{"key":"c","text":"Only when torn"},{"key":"d","text":"Never, if washed"}],"correct_keys":["b"],"explanation":"Change gloves between patients and between tasks/body sites.","sort_order":90},
      {"stem":"When should hand hygiene be performed in relation to gloves?","options":[{"key":"a","text":"Only after removing gloves"},{"key":"b","text":"Only before donning gloves"},{"key":"c","text":"Both before donning and after removing gloves"},{"key":"d","text":"Gloves replace the need for hand hygiene"}],"correct_keys":["c"],"explanation":"Perform hand hygiene both before donning and after removing gloves.","sort_order":100},
      {"stem":"Aseptic Non Touch Technique (ANTT) aims to:","options":[{"key":"a","text":"Speed up procedures"},{"key":"b","text":"Prevent contamination of key parts and key sites"},{"key":"c","text":"Avoid the need for gloves"},{"key":"d","text":"Sterilise the whole room"}],"correct_keys":["b"],"explanation":"ANTT protects key parts/sites from contamination.","sort_order":110},
      {"stem":"A patient with suspected infectious diarrhoea should ideally be:","options":[{"key":"a","text":"Nursed in an open bay"},{"key":"b","text":"Isolated in a single room where possible"},{"key":"c","text":"Discharged immediately"},{"key":"d","text":"Moved between wards"}],"correct_keys":["b"],"explanation":"Isolate in a single room to reduce transmission.","sort_order":120},
      {"stem":"Bare below the elbows means:","options":[{"key":"a","text":"No wristwatch, no rings except a plain band, sleeves rolled up"},{"key":"b","text":"Wearing a long-sleeved gown at all times"},{"key":"c","text":"Rolling sleeves down for warmth"},{"key":"d","text":"Wearing a wristwatch to time tasks"}],"correct_keys":["a"],"explanation":"Bare below the elbows supports effective hand hygiene.","sort_order":130},
      {"stem":"The correct contact time and dilution for a disinfectant are found:","options":[{"key":"a","text":"By personal preference"},{"key":"b","text":"On the manufacturer's instructions and local policy"},{"key":"c","text":"By smell"},{"key":"d","text":"They do not matter"}],"correct_keys":["b"],"explanation":"Follow manufacturer instructions and local policy.","sort_order":140},
      {"stem":"Which is a recognised route of transmission?","options":[{"key":"a","text":"Contact"},{"key":"b","text":"Emotional"},{"key":"c","text":"Financial"},{"key":"d","text":"Legal"}],"correct_keys":["a"],"explanation":"Contact (also droplet and airborne) are transmission routes.","sort_order":150},
      {"stem":"In the hierarchy of controls, PPE is:","options":[{"key":"a","text":"The first and only control needed"},{"key":"b","text":"The last line of defence"},{"key":"c","text":"Never necessary"},{"key":"d","text":"A substitute for hand hygiene"}],"correct_keys":["b"],"explanation":"PPE is the last line of defence, not the first.","sort_order":160},
      {"stem":"Colonisation differs from infection because colonisation:","options":[{"key":"a","text":"Always causes severe illness"},{"key":"b","text":"Has no signs or symptoms of disease"},{"key":"c","text":"Cannot be transmitted"},{"key":"d","text":"Only occurs in children"}],"correct_keys":["b"],"explanation":"Colonisation is presence without signs/symptoms of disease.","sort_order":170},
      {"stem":"A common safe order for donning PPE is:","options":[{"key":"a","text":"Gloves, then apron, then mask"},{"key":"b","text":"Apron, then mask, then eye protection, then gloves"},{"key":"c","text":"Eye protection last, gloves first"},{"key":"d","text":"Any order is fine"}],"correct_keys":["b"],"explanation":"Apron, mask, eye protection, then gloves is a common safe sequence.","sort_order":180},
      {"stem":"The chain of infection is most readily broken at which link in daily practice?","options":[{"key":"a","text":"The susceptible host"},{"key":"b","text":"The infectious agent"},{"key":"c","text":"The mode of transmission, via hand hygiene"},{"key":"d","text":"The reservoir"}],"correct_keys":["c"],"explanation":"Breaking transmission (hand hygiene) is the most practical link.","sort_order":190},
      {"stem":"Which of the following are standard (universal) precautions? (select all)","options":[{"key":"a","text":"Hand hygiene"},{"key":"b","text":"Reusing single-use gloves between patients"},{"key":"c","text":"Safe sharps disposal"},{"key":"d","text":"Appropriate use of PPE"}],"correct_keys":["a","c","d"],"explanation":"Hand hygiene, safe sharps disposal and appropriate PPE are standard precautions; single-use gloves are never reused.","sort_order":200}
    ]$qq$::jsonb) loop
      perform candidate.add_training_question(v_version, q->>'stem', q->'options', q->'correct_keys', q->>'explanation', (q->>'sort_order')::int);
    end loop;

    perform candidate.submit_module_for_review(v_version);
    perform candidate.approve_module_version(v_version);
    perform candidate.publish_module_version(v_version);
  end if;
end $$;
