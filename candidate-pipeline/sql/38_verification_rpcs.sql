-- ============================================================================
--  Day Webster — Candidate Pipeline · Compliance Phase 2: verification RPCs
--  File: candidate-pipeline/sql/38_verification_rpcs.sql
--  Run AFTER 37. Idempotent / additive.  STATUS: DRAFT — NOT YET APPLIED.
--
--  The fail-closed control surface for the provider/adapter layer. EVERY function
--  is SECURITY DEFINER + `set search_path = candidate, public`, revokes public,
--  and reaches the queue ONLY through here (provider_jobs has no client write
--  policy). There is NO code path from a provider error → `verified`.
--
--    · enqueue_verification      — officer/service: queue a check (idempotent).
--    · claim_provider_jobs       — service: FOR UPDATE SKIP LOCKED batch claim.
--    · apply_verification_result — service: map outcome→item + ONE audit event.
--    · fail_provider_job         — service: retry w/ backoff, else needs_human.
--    · enqueue_due_rechecks      — service: daily set-based re-check sweep.
--    · verification_counts       — officer: the dashboard tile.
--    · verification_history      — a read-only, actor-resolved audit view.
--
--  Audit: a human "Verify now" appends a request event NAMING the officer
--  (actor = auth.uid()), then apply_verification_result appends the result event
--  (actor_kind='service') — a complete, attributable, immutable request→result
--  pair. verification_events keeps NO update/delete policy (append-only).
-- ============================================================================

-- ── Role helper: is this call the service_role (edge function / cron)? ───────
-- Reads the JWT role claim. In the test harness auth.jwt() has no role => false;
-- set test.jwt = '{"role":"service_role"}' to exercise the service path.
create or replace function candidate.is_service_role()
returns boolean language sql stable
set search_path = candidate, public as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    auth.jwt()->>'role'
  ) = 'service_role';
$$;
revoke all on function candidate.is_service_role() from public;
grant execute on function candidate.is_service_role() to authenticated, service_role;

-- ── enqueue_verification: queue a check for one candidate+requirement ────────
-- Officer- or service-gated. Idempotent: the in-flight UNIQUE index collapses a
-- double click / overlapping sweep to the SAME job. Sets the item 'verifying'
-- ONLY IF NOT already 'verified' (an annual re-check must not drop a valid
-- registration to red mid-flight). Appends an attributable recheck_requested
-- event (human => actor = the acting officer; service => actor null).
create or replace function candidate.enqueue_verification(p_candidate_id       uuid,
                                                          p_requirement_code   text,
                                                          p_trigger            text default 'manual')
returns uuid language plpgsql security definer
set search_path = candidate, public as $$
declare
  v_is_service boolean := candidate.is_service_role();
  v_actor      uuid    := case when v_is_service then null else auth.uid() end;
  v_actor_kind text    := case when v_is_service then 'service' else 'human' end;
  v_req        record;
  v_provider   record;
  v_item_id    uuid;
  v_item_status text;
  v_job_id     uuid;
begin
  if not (candidate.is_compliance_officer() or v_is_service) then
    raise exception 'not authorized';
  end if;
  if p_trigger not in ('pre_placement','annual_recheck','pre_expiry','manual') then
    raise exception 'unknown trigger: %', p_trigger;
  end if;

  -- Resolve the requirement WITHIN the candidate's active set(s) (exact scope).
  select cr.id, cr.code, cr.provider_key, cr.verification_method
    into v_req
  from candidate.candidate_requirement_sets crs
  join candidate.requirement_set_items rsi on rsi.set_id = crs.set_id
  join candidate.compliance_requirements cr on cr.id = rsi.requirement_id
  where crs.candidate_id = p_candidate_id and crs.active and cr.code = p_requirement_code
  order by cr.discipline_id nulls last
  limit 1;
  if not found then
    raise exception 'requirement % is not in an active set for candidate %', p_requirement_code, p_candidate_id;
  end if;
  if v_req.provider_key is null then
    raise exception 'requirement % has no verification provider (not automatable)', p_requirement_code;
  end if;

  -- Resolve the provider; must exist and be active (not paused/retired).
  select id, provider_key, status into v_provider
  from candidate.verification_providers where provider_key = v_req.provider_key;
  if not found then
    raise exception 'no verification provider registered for %', v_req.provider_key;
  end if;
  if v_provider.status <> 'active' then
    raise exception 'verification provider % is % (not active)', v_provider.provider_key, v_provider.status;
  end if;

  -- Ensure a compliance_item exists to attach the result to (prefer verified).
  select id, status into v_item_id, v_item_status
  from candidate.compliance_items
  where candidate_id = p_candidate_id and requirement_id = v_req.id
  order by (status = 'verified') desc, updated_at desc
  limit 1;
  if v_item_id is null then
    insert into candidate.compliance_items (candidate_id, requirement_id, status)
    values (p_candidate_id, v_req.id, 'not_started')
    returning id, status into v_item_id, v_item_status;
  end if;

  -- Set 'verifying' ONLY IF NOT already verified (don't drop a valid reg to red).
  if v_item_status is distinct from 'verified' then
    update candidate.compliance_items
      set status = 'verifying', updated_at = now()
      where id = v_item_id and status is distinct from 'verified';
  end if;

  -- Enqueue. IDEMPOTENT: the in-flight partial-unique index makes a concurrent
  -- duplicate a no-op; we then return the EXISTING in-flight job id.
  insert into candidate.provider_jobs
    (provider_id, provider_key, candidate_id, requirement_id, item_id,
     requirement_code, trigger, status, request, created_by)
  values
    (v_provider.id, v_provider.provider_key, p_candidate_id, v_req.id, v_item_id,
     v_req.code, p_trigger, 'queued',
     jsonb_build_object('code', v_req.code, 'method', v_req.verification_method,
                        'trigger', p_trigger),
     v_actor)
  on conflict (candidate_id, requirement_id) where status in ('queued','running')
  do nothing
  returning id into v_job_id;

  if v_job_id is null then
    -- A check is already in flight: return it (idempotent), no second event.
    select id into v_job_id
    from candidate.provider_jobs
    where candidate_id = p_candidate_id and requirement_id = v_req.id
      and status in ('queued','running')
    order by created_at desc
    limit 1;
    return v_job_id;
  end if;

  -- Attributable request event: NAMES the officer on a human "Verify now".
  insert into candidate.verification_events
    (candidate_id, item_id, requirement_id, event_type, method,
     source_ref, notes, actor, actor_kind)
  values
    (p_candidate_id, v_item_id, v_req.id, 'recheck_requested',
     coalesce(v_req.verification_method, 'system'),
     v_job_id::text,
     format('verification queued via %s (trigger=%s)', v_provider.provider_key, p_trigger),
     v_actor, v_actor_kind);

  return v_job_id;
end;
$$;
revoke all on function candidate.enqueue_verification(uuid, text, text) from public;
grant execute on function candidate.enqueue_verification(uuid, text, text) to authenticated, service_role;

-- ── claim_provider_jobs: safe parallel batch claim (service only) ────────────
-- FOR UPDATE SKIP LOCKED + the per-provider limit => never double-processes a
-- job, never hammers a facility. Returns each claimed job joined to its (non-
-- secret) provider config so the adapter knows the kind/endpoint/secret_ref.
create or replace function candidate.claim_provider_jobs(p_worker       text,
                                                         p_provider_key text,
                                                         p_limit        int default 10)
returns table(
  job_id          uuid,
  candidate_id    uuid,
  requirement_id  uuid,
  item_id         uuid,
  requirement_code text,
  trigger         text,
  attempts        int,
  max_attempts    int,
  provider_key    text,
  provider_kind   text,
  regulator       text,
  endpoint        text,
  config          jsonb)
language plpgsql security definer
set search_path = candidate, public as $$
begin
  return query
  with claimed as (
    update candidate.provider_jobs j
    set status = 'running', locked_at = now(), locked_by = p_worker,
        attempts = j.attempts + 1, updated_at = now()
    where j.id in (
      select c.id from candidate.provider_jobs c
      where c.status = 'queued'
        and c.run_after <= now()
        and c.provider_key = p_provider_key
      order by c.run_after
      limit greatest(coalesce(p_limit, 10), 0)
      for update skip locked
    )
    returning j.*
  )
  select c.id, c.candidate_id, c.requirement_id, c.item_id, c.requirement_code,
         c.trigger, c.attempts, c.max_attempts, c.provider_key,
         p.kind, p.regulator, p.endpoint, p.config
  from claimed c
  left join candidate.verification_providers p on p.id = c.provider_id;
end;
$$;
revoke all on function candidate.claim_provider_jobs(text, text, int) from public;
grant execute on function candidate.claim_provider_jobs(text, text, int) to service_role;

-- ── apply_verification_result: write the outcome through the gate (service) ──
-- Guards job.status='running' (a duplicate callback is a no-op). Maps outcome→
-- item status: ONLY 'verified' outcome ever sets 'verified'. Sets the regulator
-- expiry, appends ONE immutable result event (actor_kind='service'), and updates
-- the job. The existing compliance_items trigger recomputes the gate.
create or replace function candidate.apply_verification_result(
    p_job_id              uuid,
    p_outcome             text,
    p_expires_at          timestamptz default null,
    p_source_ref          text        default null,
    p_registration_number text        default null,
    p_response            jsonb       default null,
    p_notes               text        default null)
returns void language plpgsql security definer
set search_path = candidate, public as $$
declare
  v_job         candidate.provider_jobs;
  v_method      text;
  v_outcome     text;                                     -- effective outcome after data-quality guard
  v_item_status text;
  v_needs_human boolean;
  v_event       text;
  v_job_status  text;
  v_dq          boolean := false;                         -- register_check verified w/ no renewal date
  v_note        text;
begin
  select * into v_job from candidate.provider_jobs where id = p_job_id for update;
  if not found then
    raise exception 'provider job % not found', p_job_id;
  end if;
  -- Duplicate / late callback for an already-finalised job: no-op (idempotent).
  if v_job.status <> 'running' then
    return;
  end if;

  select verification_method into v_method
  from candidate.compliance_requirements where id = v_job.requirement_id;

  -- F6 fail-closed data-quality guard: a register-check 'verified' with NO
  -- renewal date must NOT become a never-expiring green (a regulator-driven
  -- registration always carries a renewal date). Downgrade to needs_human so a
  -- human reconciles it, rather than crediting an open-ended pass.
  v_outcome := p_outcome;
  if p_outcome = 'verified' and v_method = 'register_check' and p_expires_at is null then
    v_outcome := 'needs_human';
    v_dq := true;
  end if;

  -- Outcome → item status (fail-closed: only 'verified' credits the gate).
  v_item_status := case v_outcome
                     when 'verified'    then 'verified'
                     when 'expired'     then 'expired'
                     when 'unsuitable'  then 'unsuitable'
                     else null end;                       -- needs_human/other: leave status
  v_needs_human := (v_outcome <> 'verified');
  v_event       := case v_outcome
                     when 'verified'   then 'verified'
                     when 'expired'    then 'expired'
                     when 'unsuitable' then 'unsuitable'
                     else 'status_recomputed' end;        -- needs_human/other: a check ran, human review
  v_job_status  := case when v_outcome in ('verified','expired','unsuitable')
                        then 'succeeded' else 'needs_human' end;
  v_note := coalesce(p_notes,
              case when v_dq then 'register check returned verified but NO renewal date — routed to human review'
                   else format('provider outcome: %s', p_outcome) end);

  if v_job.item_id is not null then
    update candidate.compliance_items ci
    set status            = coalesce(v_item_status, ci.status),  -- leave status for needs_human
        expires_at        = case when p_expires_at is not null then p_expires_at else ci.expires_at end,
        -- F4: label the channel by the verification method (register_check /
        -- dbs_update / rtw / …), not a hardcoded value, so DBS/RTW aren't mislabelled.
        channel           = coalesce(v_method, 'register_check'),
        source_confidence = case when v_outcome = 'verified' then 'high' else ci.source_confidence end,
        received_at       = now(),
        needs_human       = v_needs_human,
        migrated          = case when v_outcome = 'verified' then false else ci.migrated end,
        extracted         = coalesce(ci.extracted, '{}'::jsonb) || jsonb_strip_nulls(jsonb_build_object(
                              'registration_number', p_registration_number,
                              'source_ref',          p_source_ref,
                              'provider_outcome',    p_outcome,               -- raw adapter outcome
                              'applied_outcome',     v_outcome,               -- after the data-quality guard
                              'missing_expiry',      nullif(v_dq, false),
                              'provider_key',        v_job.provider_key,
                              'checked_at',          now())),
        updated_at        = now()
    where ci.id = v_job.item_id;
  end if;

  -- ONE immutable result event (actor_kind='service'). Completes the audit pair.
  insert into candidate.verification_events
    (candidate_id, item_id, requirement_id, event_type, new_status, method,
     source_ref, notes, actor, actor_kind)
  values
    (v_job.candidate_id, v_job.item_id, v_job.requirement_id, v_event, v_item_status,
     coalesce(v_method, 'system'), p_source_ref, v_note, null, 'service');

  update candidate.provider_jobs
  set status = v_job_status, outcome = v_outcome, source_ref = p_source_ref,
      response = coalesce(p_response, response),
      locked_at = null, locked_by = null, updated_at = now()
  where id = p_job_id;
end;
$$;
revoke all on function candidate.apply_verification_result(uuid, text, timestamptz, text, text, jsonb, text) from public;
grant execute on function candidate.apply_verification_result(uuid, text, timestamptz, text, text, jsonb, text) to service_role;

-- ── fail_provider_job: retry with backoff, else degrade to human (service) ───
-- Retryable + attempts left => requeue with exponential backoff. Otherwise the
-- job is 'failed' and the item is flagged needs_human — a provider outage NEVER
-- becomes a pass (no path from error → verified).
create or replace function candidate.fail_provider_job(p_job_id    uuid,
                                                       p_error     text,
                                                       p_retryable boolean default true,
                                                       p_response  jsonb   default null)
returns void language plpgsql security definer
set search_path = candidate, public as $$
declare
  v_job     candidate.provider_jobs;
  v_backoff interval;
begin
  select * into v_job from candidate.provider_jobs where id = p_job_id for update;
  if not found then
    raise exception 'provider job % not found', p_job_id;
  end if;
  if v_job.status <> 'running' then
    return;                                                -- idempotent no-op
  end if;

  if p_retryable and v_job.attempts < v_job.max_attempts then
    -- Exponential backoff: ~2^attempts minutes, capped.
    v_backoff := least(make_interval(mins => power(2, v_job.attempts)::int), interval '6 hours');
    update candidate.provider_jobs
    set status = 'queued', run_after = now() + v_backoff, error = p_error,
        response = coalesce(p_response, response),
        locked_at = null, locked_by = null, updated_at = now()
    where id = p_job_id;
    return;
  end if;

  -- Terminal failure: degrade to human review, never to a pass.
  update candidate.provider_jobs
  set status = 'failed', error = p_error, outcome = 'error',
      response = coalesce(p_response, response),
      locked_at = null, locked_by = null, updated_at = now()
  where id = p_job_id;

  if v_job.item_id is not null then
    update candidate.compliance_items
    set needs_human = true, updated_at = now()
    where id = v_job.item_id;
  end if;

  -- Attributable audit row for the terminal failure (append-only).
  insert into candidate.verification_events
    (candidate_id, item_id, requirement_id, event_type, method, source_ref, notes, actor, actor_kind)
  values
    (v_job.candidate_id, v_job.item_id, v_job.requirement_id, 'status_recomputed',
     'system', p_job_id::text,
     format('provider check failed (%s) — routed to human review', left(coalesce(p_error,'error'), 240)),
     null, 'service');
end;
$$;
revoke all on function candidate.fail_provider_job(uuid, text, boolean, jsonb) from public;
grant execute on function candidate.fail_provider_job(uuid, text, boolean, jsonb) to service_role;

-- ── enqueue_due_rechecks: the daily set-based re-check sweep (service) ───────
-- Enqueues register/dbs/rtw items on active sets whose provider is active and
-- that are DUE — nearing/at expiry OR last verified beyond the provider's
-- recheck_months — and that have no in-flight job. run_after is rate-spread per
-- provider (row_number × the provider's per-request spacing). Returns the count.
create or replace function candidate.enqueue_due_rechecks(p_limit int default 500)
returns int language plpgsql security definer
set search_path = candidate, public as $$
declare
  v_lead interval := interval '30 days';   -- pre-expiry lead window
  v_count int;
begin
  with due as (
    select distinct on (ci.id)
      ci.id            as item_id,
      ci.candidate_id,
      ci.requirement_id,
      cr.code          as requirement_code,
      cr.provider_key,
      vp.id            as provider_id,
      vp.rate_limit_per_min,
      case when ci.expires_at is not null and ci.expires_at <= now() + v_lead
           then 'pre_expiry' else 'annual_recheck' end as trigger
    from candidate.compliance_items ci
    join candidate.candidate_requirement_sets crs
      on crs.candidate_id = ci.candidate_id and crs.active
    join candidate.requirement_set_items rsi
      on rsi.set_id = crs.set_id and rsi.requirement_id = ci.requirement_id
    join candidate.compliance_requirements cr on cr.id = ci.requirement_id
    join candidate.verification_providers vp
      on vp.provider_key = cr.provider_key and vp.status = 'active'
    where cr.provider_key is not null
      and cr.verification_method in ('register_check','dbs_update','rtw')
      and ci.status in ('verified','expired')
      -- DUE: nearing/at expiry OR the last successful check is older than cadence.
      and (
        (ci.expires_at is not null and ci.expires_at <= now() + v_lead)
        or coalesce(
             (select max(ve.occurred_at) from candidate.verification_events ve
               where ve.candidate_id = ci.candidate_id
                 and ve.requirement_id = ci.requirement_id
                 and ve.event_type = 'verified'),
             ci.received_at)
           < now() - make_interval(months => vp.recheck_months)
      )
      -- No in-flight job for this candidate+requirement.
      and not exists (
        select 1 from candidate.provider_jobs pj
        where pj.candidate_id = ci.candidate_id
          and pj.requirement_id = ci.requirement_id
          and pj.status in ('queued','running')
      )
    order by ci.id, ci.expires_at nulls last
  ),
  ranked as (
    select d.*,
           row_number() over (partition by d.provider_key order by d.item_id) as rn
    from due d
    limit greatest(coalesce(p_limit, 500), 0)
  ),
  ins as (
    insert into candidate.provider_jobs
      (provider_id, provider_key, candidate_id, requirement_id, item_id,
       requirement_code, trigger, status, run_after, request)
    select r.provider_id, r.provider_key, r.candidate_id, r.requirement_id, r.item_id,
           r.requirement_code, r.trigger, 'queued',
           -- rate-spread: space requests by 60/rate_limit seconds within a provider.
           now() + ((r.rn - 1) * make_interval(secs => 60.0 / greatest(r.rate_limit_per_min, 1))),
           jsonb_build_object('code', r.requirement_code, 'trigger', r.trigger, 'sweep', true)
    from ranked r
    on conflict (candidate_id, requirement_id) where status in ('queued','running')
    do nothing
    returning id, candidate_id, item_id, requirement_id, provider_key
  ),
  ev as (
    insert into candidate.verification_events
      (candidate_id, item_id, requirement_id, event_type, method, source_ref, notes, actor, actor_kind)
    select i.candidate_id, i.item_id, i.requirement_id, 'recheck_requested',
           coalesce((select verification_method from candidate.compliance_requirements cr where cr.id = i.requirement_id), 'system'),
           i.id::text, 'annual/expiry re-check sweep', null, 'service'
    from ins i
    returning 1
  )
  select count(*) into v_count from ins;

  return coalesce(v_count, 0);
end;
$$;
revoke all on function candidate.enqueue_due_rechecks(int) from public;
grant execute on function candidate.enqueue_due_rechecks(int) to service_role;

-- ── verification_counts: the dashboard "Register checks" tile (officer) ──────
create or replace function candidate.verification_counts()
returns jsonb language plpgsql stable security definer
set search_path = candidate, public as $$
declare v jsonb;
begin
  if not (candidate.is_authorized_user() and candidate.is_compliance_officer()) then
    raise exception 'not authorized';
  end if;

  select jsonb_build_object(
    'queued',           count(*) filter (where status = 'queued'),
    'running',          count(*) filter (where status = 'running'),
    'failed',           count(*) filter (where status = 'failed'),
    'needs_human',      count(*) filter (where status = 'needs_human'),
    'auto_verified_24h', count(*) filter (where outcome = 'verified' and status = 'succeeded'
                                             and updated_at >= now() - interval '24 hours')
  ) into v
  from candidate.provider_jobs;

  return coalesce(v, '{}'::jsonb);
end;
$$;
revoke all on function candidate.verification_counts() from public;
grant execute on function candidate.verification_counts() to authenticated;

-- ── verification_history: actor-resolved, read-only audit view ───────────────
-- security_invoker => the underlying verification_events RLS (compliance read)
-- applies. Resolves the acting officer's uid → staff name / login email so the
-- audit pack (and the UI pill) can show WHO ran each check. Append-only is
-- preserved: this is a SELECT-only view over the immutable spine.
create or replace view candidate.verification_history
with (security_invoker = true) as
select
  ve.id,
  ve.candidate_id,
  ve.item_id,
  ve.requirement_id,
  cr.code           as requirement_code,
  cr.name           as requirement_name,
  ve.event_type,
  ve.method,
  ve.old_status,
  ve.new_status,
  ve.source_ref,
  ve.notes,
  ve.actor,
  ve.actor_kind,
  coalesce(st.full_name, au.email) as actor_name,
  au.email          as actor_email,
  ve.occurred_at
from candidate.verification_events ve
left join candidate.compliance_requirements cr on cr.id = ve.requirement_id
left join candidate.staff     st on st.user_id = ve.actor
left join candidate.app_users au on au.user_id = ve.actor;

grant select on candidate.verification_history to authenticated;
