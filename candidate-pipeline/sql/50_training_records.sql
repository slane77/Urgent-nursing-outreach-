-- ============================================================================
--  Day Webster — Candidate Pipeline · Mandatory Training: records + certs + hook
--  File: candidate-pipeline/sql/50_training_records.sql
--  Run AFTER 49.  Idempotent / additive.  STATUS: DRAFT — NOT YET APPLIED.
--
--  The producer of compliance_items. issue_training_record() is the single choke
--  point that mints a certificate, writes an immutable training_records row, and
--  writes the COMPLIANCE HOOK: a verified, expiring compliance_item under the
--  module's OWN requirement_code (CI1). The existing item trigger (23/25) then
--  recomputes the work-ready gate and the pre-expiry ladder (41) chases each
--  subject on its own clock — zero changes to the gate/ladder/passport.
--
--  Certificates are HTML in Phase 1 (PDF later). sfh_accreditation_ref is carried
--  onto the cert as STORED-not-asserted (see 47 header).
-- ============================================================================

-- ── training_records: one immutable record per completion (+ its certificate) ─
create table if not exists candidate.training_records (
  id                 uuid primary key default gen_random_uuid(),
  candidate_id       uuid not null references candidate.candidates(id) on delete cascade,
  module_id          uuid not null references candidate.training_modules(id) on delete restrict,
  -- FROZEN version assessed against. NULL only for a manual/elsewhere completion
  -- of a module that has no published version (nothing of ours to freeze).
  module_version_id  uuid references candidate.module_versions(id) on delete restrict,
  source             text not null check (source in ('assessment','manual')),
  score              numeric,
  attempt_id         uuid references candidate.training_attempts(id) on delete set null,
  provider           text,                          -- manual: where it was done elsewhere
  completion_date    date not null,
  expiry_date        date not null,                 -- completion + validity_months
  certificate_id     text not null unique,          -- 'DW-TRN-2026-3F9K2A'
  certificate_path   text,                          -- private bucket 'training-certs' (Round 2)
  compliance_item_id uuid references candidate.compliance_items(id) on delete set null,
  recorded_by        uuid references auth.users(id) on delete set null,  -- manual: the manager
  created_at         timestamptz not null default now()
);
create index if not exists training_records_candidate_idx on candidate.training_records (candidate_id);
create index if not exists training_records_module_idx    on candidate.training_records (module_id);

-- ── issue_training_record: mint cert, write record, write the compliance hook ─
-- The ONLY way a training_records row + compliance_item is produced. Reachable
-- only via submit_training_attempt (49, assessment) and record_manual_training
-- (51, manual) — both SECURITY DEFINER — plus direct service_role. NOT granted to
-- authenticated, so a plain officer cannot forge a record by calling it directly.
create or replace function candidate.issue_training_record(
    p_candidate_id   uuid,
    p_module_id      uuid,
    p_source         text,
    p_score          numeric,
    p_completion_date date,
    p_attempt_id     uuid default null,
    p_provider       text default null,
    p_evidence_path  text default null)
returns table(rec_id uuid, cert_id text)   -- named to avoid collision with table `id` columns
language plpgsql security definer
set search_path = candidate, public as $$
declare
  v_req_code text; v_validity int; v_req uuid; v_version uuid;
  v_expiry date; v_cert text; v_channel text; v_item uuid; v_rec uuid;
begin
  if not (candidate.is_service_role() or candidate.is_compliance_officer()) then
    raise exception 'not authorized';
  end if;
  if p_source not in ('assessment','manual') then
    raise exception 'invalid source: %', p_source;
  end if;

  select requirement_code, validity_months, current_version_id
    into v_req_code, v_validity, v_version
  from candidate.training_modules where id = p_module_id;
  if not found then raise exception 'module % not found', p_module_id; end if;

  -- Freeze the assessed version on the assessment path; else the current version.
  if p_source = 'assessment' and p_attempt_id is not null then
    select module_version_id into v_version from candidate.training_attempts where id = p_attempt_id;
  end if;

  v_expiry  := (p_completion_date + make_interval(months => v_validity))::date;
  -- 48 bits of entropy (per-year namespaced) so a certificate_id collision — which
  -- would otherwise fail the pass submission on the unique index — is negligible.
  v_cert    := 'DW-TRN-' || to_char(p_completion_date, 'YYYY') || '-' ||
               upper(encode(gen_random_bytes(6), 'hex'));
  v_channel := case when p_source = 'assessment' then 'assessment' else 'manual' end;

  -- Resolve the module's OWN (global) requirement (CI1).
  select cr.id into v_req from candidate.compliance_requirements cr
   where cr.code = v_req_code and cr.discipline_id is null and cr.specialty_id is null;

  -- ── COMPLIANCE HOOK: upsert the latest item for (candidate, requirement) ────
  if v_req is not null then
    select id into v_item from candidate.compliance_items
     where candidate_id = p_candidate_id and requirement_id = v_req
     order by (status = 'verified') desc, updated_at desc limit 1;

    if v_item is not null then
      update candidate.compliance_items
        set status = 'verified',
            expires_at = v_expiry,
            channel = v_channel,
            source_confidence = 'high',
            received_at = p_completion_date,
            needs_human = false,
            extracted = coalesce(extracted, '{}'::jsonb) || jsonb_build_object(
                          'source_ref', v_cert, 'certificate_id', v_cert,
                          'provider', p_provider, 'training_source', p_source,
                          'completion_date', p_completion_date, 'applied_outcome', 'verified'),
            updated_at = now()
      where id = v_item;
    else
      insert into candidate.compliance_items
        (candidate_id, requirement_id, status, channel, source_confidence,
         received_at, expires_at, needs_human, extracted)
      values
        (p_candidate_id, v_req, 'verified', v_channel, 'high',
         p_completion_date, v_expiry, false, jsonb_build_object(
           'source_ref', v_cert, 'certificate_id', v_cert, 'provider', p_provider,
           'training_source', p_source, 'completion_date', p_completion_date,
           'applied_outcome', 'verified'))
      returning id into v_item;
    end if;
  end if;
  -- (If v_req is null the item isn't written but the record/cert still issue —
  --  feeds the passport once wired; never errors. In practice 47's mirror
  --  trigger guarantees the requirement exists.)

  insert into candidate.training_records
    (candidate_id, module_id, module_version_id, source, score, attempt_id,
     provider, completion_date, expiry_date, certificate_id, compliance_item_id, recorded_by)
  values
    (p_candidate_id, p_module_id, v_version, p_source, p_score, p_attempt_id,
     p_provider, p_completion_date, v_expiry, v_cert, v_item,
     case when p_source = 'manual' then auth.uid() else null end)
  returning candidate.training_records.id into v_rec;

  -- Attributable audit row (append-only spine). Assessment => method='assessment'
  -- (actor null/service); manual => method='human' (actor = the manager).
  insert into candidate.verification_events
    (candidate_id, item_id, requirement_id, event_type, new_status, method,
     source_ref, notes, actor, actor_kind)
  values
    (p_candidate_id, v_item, v_req, 'verified', 'verified',
     case when p_source = 'assessment' then 'assessment' else 'human' end,
     v_cert,
     case when p_source = 'assessment'
          then format('training passed via assessment (score %s%%) — cert %s', p_score, v_cert)
          else format('training recorded manually (provider %s, evidence %s) — cert %s',
                      coalesce(p_provider,'?'), coalesce(p_evidence_path,'-'), v_cert) end,
     case when p_source = 'manual' then auth.uid() else null end,
     case when p_source = 'manual' then 'human' else 'service' end);

  return query select v_rec, v_cert;
end $$;
revoke all on function candidate.issue_training_record(uuid, uuid, text, numeric, date, uuid, text, text) from public;
grant execute on function candidate.issue_training_record(uuid, uuid, text, numeric, date, uuid, text, text) to service_role;

-- ── verify_certificate: MINIMAL public validity check ────────────────────────
-- Returns only what a client/auditor legitimately needs to confirm a cert —
-- NEVER full name / DOB / score. Unknown id => {valid:false}. SECURITY DEFINER so
-- it reads past training_records RLS while exposing only the whitelist below.
-- The PUBLIC verify page (Round 2) reaches this via a rate-limited
-- `certificate-verify` edge function running as service_role — we deliberately do
-- NOT grant anon direct DB access (no `grant usage on schema candidate to anon`),
-- so the public never touches Postgres directly.
create or replace function candidate.verify_certificate(p_certificate_id text)
returns jsonb language plpgsql stable security definer
set search_path = candidate, public as $$
declare v jsonb;
begin
  select jsonb_build_object(
    'valid',                 true,
    'module_title',          tm.title,
    'framework_subject',     tm.framework_subject,
    'sfh_accreditation_ref', tm.sfh_accreditation_ref,
    'completion_date',       tr.completion_date,
    'expiry_date',           tr.expiry_date,
    'status',                case when tr.expiry_date >= current_date then 'valid' else 'expired' end,
    'candidate_initials',    upper(coalesce(left(c.first_name,1),'') || coalesce(left(c.last_name,1),''))
  ) into v
  from candidate.training_records tr
  join candidate.training_modules tm on tm.id = tr.module_id
  join candidate.candidates c on c.id = tr.candidate_id
  where tr.certificate_id = p_certificate_id;

  return coalesce(v, jsonb_build_object('valid', false));
end $$;
revoke all on function candidate.verify_certificate(text) from public;
grant execute on function candidate.verify_certificate(text) to authenticated, service_role;

-- ── RLS ──────────────────────────────────────────────────────────────────────
alter table candidate.training_records enable row level security;
-- authorised staff READ; NO client write (append-only, RPC only); manager DELETE.
drop policy if exists "auth read training_records"    on candidate.training_records;
drop policy if exists "manager delete training_records" on candidate.training_records;
create policy "auth read training_records" on candidate.training_records
  for select to authenticated using (candidate.is_authorized_user());
create policy "manager delete training_records" on candidate.training_records
  for delete to authenticated
  using (candidate.is_authorized_user() and candidate.is_manager());

-- Table privileges. Writes are RPC-only (append-only); manager DELETE per policy.
grant select, delete on candidate.training_records to authenticated;
