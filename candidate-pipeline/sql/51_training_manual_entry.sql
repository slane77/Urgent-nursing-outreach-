-- ============================================================================
--  Day Webster — Candidate Pipeline · Mandatory Training: manager manual entry
--  File: candidate-pipeline/sql/51_training_manual_entry.sql
--  Run AFTER 50.  Idempotent / additive.  STATUS: DRAFT — NOT YET APPLIED.
--
--  "Managers only can manually enter training dates." record_manual_training is
--  SECURITY DEFINER and hard-guarded on is_manager(): an ordinary compliance
--  officer cannot manual-enter (guard + no client write path). It records the
--  external evidence (when a path is supplied) and calls issue_training_record
--  (50) with source='manual' — issuing the DW cert + record + compliance hook and
--  an attributable, human-method verification_events row naming the manager,
--  the external provider and the evidence reference.
-- ============================================================================

create or replace function candidate.record_manual_training(
    p_candidate_id    uuid,
    p_module_id       uuid,
    p_completion_date date,
    p_score           numeric default null,
    p_provider        text    default null,
    p_evidence_path   text    default null)
returns table(id uuid, certificate_id text)
language plpgsql security definer
set search_path = candidate, public as $$
declare v_id uuid; v_cert text; v_req uuid; v_req_code text; v_item uuid;
begin
  -- Manager-only (managers include admins). Ordinary officers are refused.
  if not candidate.is_manager() then
    raise exception 'not authorized';
  end if;

  select r.rec_id, r.cert_id into v_id, v_cert
  from candidate.issue_training_record(
         p_candidate_id, p_module_id, 'manual', p_score, p_completion_date,
         null, p_provider, p_evidence_path) r;

  -- Link the uploaded external certificate (Round 2 UI uploads to candidate-docs
  -- and passes the path) to the module's requirement + the freshly-written item.
  if p_evidence_path is not null then
    select cr.id, cr.code into v_req, v_req_code
    from candidate.training_modules tm
    join candidate.compliance_requirements cr
      on cr.code = tm.requirement_code and cr.discipline_id is null and cr.specialty_id is null
    where tm.id = p_module_id;

    select tr.compliance_item_id into v_item
    from candidate.training_records tr where tr.id = v_id;

    insert into candidate.candidate_evidence
      (candidate_id, item_id, requirement_id, bucket, path, filename, uploaded_by)
    values
      (p_candidate_id, v_item, v_req, 'candidate-docs', p_evidence_path,
       'manual training evidence (' || coalesce(p_provider,'external') || ')', auth.uid());
  end if;

  return query select v_id, v_cert;
end $$;
revoke all on function candidate.record_manual_training(uuid, uuid, date, numeric, text, text) from public;
grant execute on function candidate.record_manual_training(uuid, uuid, date, numeric, text, text) to authenticated, service_role;
