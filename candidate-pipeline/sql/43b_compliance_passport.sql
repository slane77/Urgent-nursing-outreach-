-- ============================================================================
--  Day Webster — Candidate Pipeline · Client Checklist Auto-Fill (Phase 1)
--  File: candidate-pipeline/sql/43b_compliance_passport.sql
--  Run AFTER 43. Idempotent / additive.  STATUS: DRAFT — NOT YET APPLIED.
--
--  THE COMPLIANCE PASSPORT — the canonical, live-resolved answer to "everything a
--  client checklist could ask about this candidate", built ONCE and reused by
--  every client template's token->field map (design §1). Officer/service-gated
--  SECURITY DEFINER, so the token vocabulary is resolved with full read of the
--  candidate file but never leaks to a non-officer.
--
--  Every field is an OBJECT — never a bare scalar — carrying:
--     { value, provenance ∈ {verified,self_declared,derived,missing}, as_at, source_ref }
--  A field with no data is returned EXPLICITLY as provenance 'missing' with a null
--  value — NEVER omitted — so a checklist can state provenance ("DBS verified
--  01/06/2026") and a missing answer-blank is surfaced, never silently blank (§3).
--
--  Resolution order per field:
--    1. first-class `candidates` columns (identity)          -> self_declared
--    2. role joins (division/discipline/specialty)           -> derived
--    3. latest compliance_item per requirement `code`, picked verified-wins
--       (order by (status='verified') desc, updated_at desc) -> verified/derived
--    4. overlay `candidate_attributes` for any vocabulary key not yet satisfied
--       (dbs.number, rtw.share_code, training.<module>.expiry, …).
--  Plus a generic `item.<code>.{status,expires_at,verified_at,source_ref}` block
--  for EVERY seeded requirement code (sql/13 + sql/27).
-- ============================================================================

-- ── pp_field: the field-object constructor (auto-marks empty => 'missing') ───
-- Pure/immutable helper. If the value is null/blank the provenance is forced to
-- 'missing' regardless of the caller's guess, so "missing is explicit" is a table
-- stake, not a per-call responsibility.
create or replace function candidate.pp_field(
    p_value      text,
    p_provenance text default 'self_declared',
    p_as_at      date default null,
    p_source_ref text default null)
returns jsonb language sql immutable
set search_path = candidate, public as $$
  select jsonb_build_object(
    'value',      case when p_value is null or btrim(p_value) = '' then null else p_value end,
    'provenance', case when p_value is null or btrim(p_value) = '' then 'missing' else p_provenance end,
    'as_at',      p_as_at,
    'source_ref', p_source_ref);
$$;
revoke all on function candidate.pp_field(text, text, date, text) from public;
grant execute on function candidate.pp_field(text, text, date, text) to authenticated, service_role;

-- ── compliance_passport: resolve the whole vocabulary for one candidate ──────
create or replace function candidate.compliance_passport(p_candidate_id uuid)
returns jsonb language plpgsql stable security definer
set search_path = candidate, public as $$
declare
  v_c      candidate.candidates;
  v_div    text;
  v_disc   text;
  v_spec   text;
  v_items  jsonb := '{}'::jsonb;   -- code -> {status,expires_at,received_at,updated_at,source_ref,number}
  v_reg    jsonb;                  -- the registration item (nmc/gmc/hcpc), verified-wins
  v_dbs    jsonb;                  -- the DBS item (enhanced/adults/children), verified-wins
  v_rtw    jsonb;                  -- the right_to_work item
  v_oh     jsonb;
  v_immun  jsonb;
  v_train  jsonb;
  v_qual   jsonb;
  v_refs   jsonb;
  v_fields jsonb := '{}'::jsonb;
  v_code   text;
  r        record;
  v_seeded text[] := array[
    'cv','right_to_work','proof_of_address','references_3yr','overseas_police_check',
    'nmc_registration','gmc_registration','hcpc_registration','qualification_cert',
    'indemnity','dbs_enhanced','dbs_enhanced_adults','dbs_enhanced_children',
    'occupational_health','immunisations','mandatory_training','care_certificate',
    'cii_qualification','financial_reference','level5_diploma','fit_person_declaration'];
begin
  -- Fail-closed gate: officer (UI) OR the service_role (edge function). Never anon.
  if not ((candidate.is_authorized_user() and candidate.is_compliance_officer())
          or candidate.is_service_role()) then
    raise exception 'not authorized';
  end if;

  select * into v_c from candidate.candidates where id = p_candidate_id;
  if not found then
    raise exception 'candidate % not found', p_candidate_id;
  end if;

  -- Role via the division -> discipline -> specialty taxonomy.
  select di.name, dv.name, sp.name
    into v_disc, v_div, v_spec
  from candidate.candidates c
  left join candidate.disciplines di on di.id = c.discipline_id
  left join candidate.divisions   dv on dv.id = di.division_id
  left join candidate.specialties  sp on sp.id = c.primary_specialty_id
  where c.id = p_candidate_id;

  -- Latest compliance_item per requirement CODE, verified-wins (regardless of
  -- discipline — a code seeded per-discipline resolves to the candidate's actual
  -- held item). Same lateral tiebreak as recompute_candidate_status.
  for r in
    select distinct on (cr.code)
           cr.code   as code,
           ci.status as status,
           ci.expires_at,
           ci.received_at,
           ci.updated_at,
           ci.extracted
    from candidate.compliance_items ci
    join candidate.compliance_requirements cr on cr.id = ci.requirement_id
    where ci.candidate_id = p_candidate_id
    order by cr.code, (ci.status = 'verified') desc, ci.updated_at desc
  loop
    v_items := v_items || jsonb_build_object(r.code, jsonb_build_object(
      'status',      r.status,
      'expires_at',  r.expires_at,
      'received_at', r.received_at,
      'updated_at',  r.updated_at,
      'source_ref',  r.extracted->>'source_ref',
      'number',      r.extracted->>'registration_number'));
  end loop;

  -- Composite pickers: the verified one wins if more than one code is present.
  v_reg := (select e from (values (v_items->'nmc_registration'),
                                  (v_items->'gmc_registration'),
                                  (v_items->'hcpc_registration')) t(e)
            where e is not null order by (e->>'status' = 'verified') desc limit 1);
  v_dbs := (select e from (values (v_items->'dbs_enhanced'),
                                  (v_items->'dbs_enhanced_adults'),
                                  (v_items->'dbs_enhanced_children')) t(e)
            where e is not null order by (e->>'status' = 'verified') desc limit 1);
  v_rtw   := v_items->'right_to_work';
  v_oh    := v_items->'occupational_health';
  v_immun := v_items->'immunisations';
  v_train := v_items->'mandatory_training';
  v_qual  := v_items->'qualification_cert';
  v_refs  := v_items->'references_3yr';

  -- ── identity.* (first-class columns; candidate-provided => self_declared) ──
  v_fields := v_fields
    || jsonb_build_object('identity.first_name',     candidate.pp_field(v_c.first_name))
    || jsonb_build_object('identity.last_name',      candidate.pp_field(v_c.last_name))
    || jsonb_build_object('identity.full_name',      candidate.pp_field(
         nullif(btrim(concat_ws(' ', v_c.first_name, v_c.last_name)), ''), 'derived'))
    || jsonb_build_object('identity.known_as',       candidate.pp_field(v_c.known_as))
    || jsonb_build_object('identity.dob',            candidate.pp_field(v_c.dob::text))
    || jsonb_build_object('identity.email',          candidate.pp_field(v_c.email))
    || jsonb_build_object('identity.phone',          candidate.pp_field(v_c.phone))
    || jsonb_build_object('identity.town',           candidate.pp_field(v_c.town))
    || jsonb_build_object('identity.postcode',       candidate.pp_field(v_c.postcode))
    || jsonb_build_object('identity.region',         candidate.pp_field(v_c.region))
    || jsonb_build_object('identity.country',        candidate.pp_field(v_c.country))
    || jsonb_build_object('identity.address',        candidate.pp_field(v_c.address))
    || jsonb_build_object('identity.ni_number',      candidate.pp_field(v_c.ni_number))
    || jsonb_build_object('identity.nationality',    candidate.pp_field(v_c.nationality))
    || jsonb_build_object('identity.gender',         candidate.pp_field(v_c.gender))
    || jsonb_build_object('identity.place_of_birth', candidate.pp_field(v_c.place_of_birth));

  -- ── role.* (taxonomy joins => derived) ──
  v_fields := v_fields
    || jsonb_build_object('role.division',   candidate.pp_field(v_div,  'derived'))
    || jsonb_build_object('role.discipline', candidate.pp_field(v_disc, 'derived'))
    || jsonb_build_object('role.specialty',  candidate.pp_field(v_spec, 'derived'))
    -- no dedicated job_title column: seed from specialty (derived), overlay may refine.
    || jsonb_build_object('role.job_title',  candidate.pp_field(v_spec, 'derived'));

  -- ── reg.* (verified registration item wins over the self-declared column) ──
  v_fields := v_fields
    || jsonb_build_object('reg.body',
         candidate.pp_field(v_c.registration_body))
    || jsonb_build_object('reg.number',
         case when v_reg is not null and (v_reg->>'status') = 'verified' and (v_reg->>'number') is not null
              then candidate.pp_field(v_reg->>'number', 'verified',
                     (v_reg->>'received_at')::timestamptz::date, v_reg->>'source_ref')
              else candidate.pp_field(v_c.registration_number) end)
    || jsonb_build_object('reg.expiry',
         candidate.pp_field(nullif(v_reg->>'expires_at','')::timestamptz::date::text,
           case when (v_reg->>'status') = 'verified' then 'verified' else 'derived' end,
           null, v_reg->>'source_ref'))
    || jsonb_build_object('reg.verified',
         candidate.pp_field(case when (v_reg->>'status') = 'verified' then 'Yes' else 'No' end,
           'derived', (v_reg->>'received_at')::timestamptz::date, v_reg->>'source_ref'))
    || jsonb_build_object('reg.checked_at',
         candidate.pp_field((v_reg->>'received_at')::timestamptz::date::text, 'derived'))
    || jsonb_build_object('reg.source_ref',
         candidate.pp_field(v_reg->>'source_ref', 'verified'));

  -- ── dbs.* (number/level/issue_date come from candidate_attributes overlay) ──
  v_fields := v_fields
    || jsonb_build_object('dbs.number',         candidate.pp_field(null))  -- overlay fills
    || jsonb_build_object('dbs.level',          candidate.pp_field(null))
    || jsonb_build_object('dbs.issue_date',     candidate.pp_field(null))
    || jsonb_build_object('dbs.update_service', candidate.pp_field(null))
    || jsonb_build_object('dbs.verified',
         candidate.pp_field(case when (v_dbs->>'status') = 'verified' then 'Yes' else 'No' end,
           'derived', (v_dbs->>'received_at')::timestamptz::date, v_dbs->>'source_ref'));

  -- ── rtw.* (status self-declared, upgraded to verified when the item passes) ──
  v_fields := v_fields
    || jsonb_build_object('rtw.status',
         candidate.pp_field(v_c.right_to_work_status,
           case when (v_rtw->>'status') = 'verified' then 'verified' else 'self_declared' end,
           (v_rtw->>'received_at')::timestamptz::date, v_rtw->>'source_ref'))
    || jsonb_build_object('rtw.share_code', candidate.pp_field(null))  -- overlay fills
    || jsonb_build_object('rtw.method',     candidate.pp_field(null))
    || jsonb_build_object('rtw.expiry',
         candidate.pp_field(nullif(v_rtw->>'expires_at','')::timestamptz::date::text,
           case when (v_rtw->>'status') = 'verified' then 'verified' else 'derived' end))
    || jsonb_build_object('rtw.verified',
         candidate.pp_field(case when (v_rtw->>'status') = 'verified' then 'Yes' else 'No' end,
           'derived', (v_rtw->>'received_at')::timestamptz::date, v_rtw->>'source_ref'));

  -- ── refs.* / oh.* / immun.* / training.* / qual.* (item-derived) ──
  v_fields := v_fields
    || jsonb_build_object('refs.covered',
         candidate.pp_field(case when (v_refs->>'status') = 'verified' then 'Yes' else 'No' end, 'derived'))
    || jsonb_build_object('refs.years',  candidate.pp_field(null))   -- overlay fills
    || jsonb_build_object('refs.count',  candidate.pp_field(null))
    || jsonb_build_object('oh.status',
         candidate.pp_field(nullif(v_oh->>'status','not_started'),
           case when (v_oh->>'status') = 'verified' then 'verified' else 'derived' end))
    || jsonb_build_object('oh.date',
         candidate.pp_field((v_oh->>'received_at')::timestamptz::date::text, 'derived'))
    || jsonb_build_object('immun.status',
         candidate.pp_field(nullif(v_immun->>'status','not_started'),
           case when (v_immun->>'status') = 'verified' then 'verified' else 'derived' end))
    || jsonb_build_object('immun.date',
         candidate.pp_field((v_immun->>'received_at')::timestamptz::date::text, 'derived'))
    || jsonb_build_object('training.status',
         candidate.pp_field(nullif(v_train->>'status','not_started'),
           case when (v_train->>'status') = 'verified' then 'verified' else 'derived' end))
    || jsonb_build_object('training.expiry',
         candidate.pp_field(nullif(v_train->>'expires_at','')::timestamptz::date::text,
           case when (v_train->>'status') = 'verified' then 'verified' else 'derived' end))
    || jsonb_build_object('qual.name',   candidate.pp_field(null))   -- overlay fills
    || jsonb_build_object('qual.status',
         candidate.pp_field(nullif(v_qual->>'status','not_started'),
           case when (v_qual->>'status') = 'verified' then 'verified' else 'derived' end))
    || jsonb_build_object('qual.cert_date',
         candidate.pp_field((v_qual->>'received_at')::timestamptz::date::text, 'derived'));

  -- ── generic item.<code>.* block for EVERY seeded requirement code ──
  foreach v_code in array v_seeded loop
    v_fields := v_fields
      || jsonb_build_object('item.'||v_code||'.status',
           candidate.pp_field(nullif((v_items->v_code)->>'status','not_started'),
             case when ((v_items->v_code)->>'status') = 'verified' then 'verified' else 'derived' end,
             ((v_items->v_code)->>'updated_at')::timestamptz::date,
             (v_items->v_code)->>'source_ref'))
      || jsonb_build_object('item.'||v_code||'.expires_at',
           candidate.pp_field(nullif((v_items->v_code)->>'expires_at','')::timestamptz::date::text,
             case when ((v_items->v_code)->>'status') = 'verified' then 'verified' else 'derived' end,
             null, (v_items->v_code)->>'source_ref'))
      || jsonb_build_object('item.'||v_code||'.verified_at',
           candidate.pp_field(
             case when ((v_items->v_code)->>'status') = 'verified'
                  then ((v_items->v_code)->>'received_at')::timestamptz::date::text end,
             'verified', null, (v_items->v_code)->>'source_ref'))
      || jsonb_build_object('item.'||v_code||'.source_ref',
           candidate.pp_field((v_items->v_code)->>'source_ref', 'verified'));
  end loop;

  -- ── Overlay candidate_attributes for any key not satisfied by a column/item ─
  -- Fills a still-missing named field (dbs.number, rtw.share_code, qual.name, …)
  -- AND introduces brand-new long-tail keys (training.bls.expiry, …) with NO
  -- migration. Never overwrites an already-resolved (non-null) value.
  for r in
    select key, value, provenance, as_at, source_ref
    from candidate.candidate_attributes
    where candidate_id = p_candidate_id
  loop
    if (v_fields->r.key) is null or (v_fields->r.key->>'value') is null then
      v_fields := v_fields || jsonb_build_object(
        r.key, candidate.pp_field(r.value, r.provenance, r.as_at, r.source_ref));
    end if;
  end loop;

  return jsonb_build_object(
    'passport_version', 1,
    'candidate_id',     p_candidate_id,
    'generated_at',     now(),
    'fields',           v_fields);
end;
$$;
revoke all on function candidate.compliance_passport(uuid) from public;
grant execute on function candidate.compliance_passport(uuid) to authenticated, service_role;
