-- ============================================================================
--  Day Webster — Candidate Pipeline · Compliance BREACH: record + alert + report
--  File: candidate-pipeline/sql/42_compliance_breach.sql
--  Run AFTER 34-40 (needs the sets/items/status spine, the shift-date gate +
--  overrides, the officer/overseer routing, and the reporting rollup patterns).
--  Idempotent / additive.  STATUS: DRAFT — NOT YET APPLIED.
--
--  A COMPLIANCE BREACH is what happens when a worker is BOOKED for a shift on a
--  date they are NOT compliant for — the shift-date gate (sql/40) said either
--  'red' (blocked) OR ready-only-via a manager OVERRIDE. Placing that worker
--  means a required document is elapsed/unsatisfied on the day of work. This file
--  makes that event first-class:
--
--    1. noncompliant_items_on()  — the single source of "which docs are the
--       problem" as-of a date+buffer (mirrors work_ready_status_on's math); used
--       by the booking gate to WARN and by the breach snapshot to RECORD.
--    2. compliance_breaches       — one immutable-core row per (candidate,set,
--       shift,booking) breach, with a JSONB snapshot of the elapsed docs.
--    3. record_booking_breach()   — officer/service RPC: verify a breach really
--       exists (never log a spurious one), snapshot it, log it (idempotent), and
--       append a 'breach_logged' audit event. The alert email is sent by the
--       booking-breach edge function that wraps this RPC.
--    4. acknowledge/resolve RPCs  — officer lifecycle, append-only audited.
--    5. open_breaches view + two REPORT RPCs — the officer queue + the exec
--       headline "N candidates working with elapsed documents".
--
--  Security: every function is SECURITY DEFINER + `set search_path = candidate,
--  public`, revokes public. compliance_breaches has an officer-only SELECT policy
--  and NO insert/update/delete policy — the ONLY writers are the SECURITY DEFINER
--  RPCs below (which run as owner). The verification_events spine stays
--  append-only; breach lifecycle rows are written only via RPC INSERT.
-- ============================================================================

-- ── noncompliant_items_on: the elapsed/unsatisfied REQUIRED docs as-of a date ─
-- Returns the required (coalesce(rsi.required_override, cr.required)) blocking OR
-- standard items in the set whose LATEST item (same verified-first/updated_at
-- tiebreak as work_ready_status_on) is NOT satisfied as-of the cut-off:
--   cut-off = greatest(now(), shift_date + buffer)   -- clamp like sql/40
--   satisfied = 'waived' OR ('verified' AND (expires_at is null OR > cut-off))
-- This is the single source of "which docs block the booking" — the gate WARNS
-- with it and the breach snapshot RECORDS it, so the two can never disagree.
create or replace function candidate.noncompliant_items_on(
    p_candidate_id uuid, p_set_id uuid, p_as_of date, p_buffer_days int default null)
returns table(requirement_id uuid, code text, name text, status text, expires_at timestamptz)
language sql stable security definer
set search_path = candidate, public as $$
  with params as (
    select greatest(coalesce(p_buffer_days, candidate.booking_buffer_days()), 0) as buffer
  ),
  cut as (
    select greatest(now(),
                    (p_as_of + make_interval(days => (select buffer from params)))::timestamptz) as v_cut
  ),
  reqs as (
    select rsi.requirement_id,
           coalesce(rsi.criticality, cr.criticality)   as criticality,
           coalesce(rsi.required_override, cr.required) as required,
           cr.code, cr.name
    from candidate.requirement_set_items rsi
    join candidate.compliance_requirements cr on cr.id = rsi.requirement_id
    where rsi.set_id = p_set_id
  ),
  held as (
    -- Fail-closed like work_ready_status_on(): the candidate must ACTIVELY hold the
    -- set. If not, the gate is 'red' for that reason alone (no doc is at fault), so
    -- the snapshot must still be non-empty — otherwise a fail-closed red would log a
    -- breach with an empty snapshot. We surface that as an explicit SET_NOT_HELD row.
    select exists (
      select 1 from candidate.candidate_requirement_sets crs
      where crs.candidate_id = p_candidate_id and crs.set_id = p_set_id and crs.active
    ) as h
  ),
  item_state as (
    select r.requirement_id, r.criticality, r.required, r.code, r.name,
           ci.status, ci.expires_at
    from reqs r
    left join lateral (
      select ci.status, ci.expires_at
      from candidate.compliance_items ci
      where ci.candidate_id = p_candidate_id
        and ci.requirement_id = r.requirement_id
      order by (ci.status = 'verified') desc, ci.updated_at desc
      limit 1
    ) ci on true
  ),
  rows as (
    -- The whole set is not applicable to a candidate who doesn't hold it.
    select null::uuid as requirement_id, 'SET_NOT_HELD' as code,
           'Candidate is not actively assigned to this requirement set' as name,
           'not_assigned' as status, null::timestamptz as expires_at, 0 as sort_key
    from held where not held.h
    union all
    -- The elapsed/unsatisfied REQUIRED docs (only when the set IS held).
    select i.requirement_id, i.code, i.name,
           coalesce(i.status, 'missing') as status,   -- null latest item => no doc at all
           i.expires_at,
           case when i.criticality = 'blocking' then 1 else 2 end as sort_key
    from item_state i, cut, held
    where held.h
      and i.required
      and i.criticality in ('blocking','standard')
      and i.status is distinct from 'waived'
      and (i.status is distinct from 'verified'
           or (i.expires_at is not null and i.expires_at <= cut.v_cut))
  )
  select requirement_id, code, name, status, expires_at
  from rows
  order by sort_key, code;
$$;
revoke all on function candidate.noncompliant_items_on(uuid, uuid, date, int) from public;
grant execute on function candidate.noncompliant_items_on(uuid, uuid, date, int) to authenticated, service_role;

-- ── Extend the append-only audit vocabulary with the breach lifecycle ────────
-- Drop-then-add keeps this idempotent; the new list is a strict SUPERSET (keeps
-- everything through sql/40's override_granted/override_revoked) so no existing
-- verification_events row is ever invalidated.
alter table candidate.verification_events
  drop constraint if exists verification_events_event_type_check;
alter table candidate.verification_events
  add constraint verification_events_event_type_check
  check (event_type in ('verified','rejected','unsuitable','expired','waived',
         'reinstated','evidence_received','recheck_requested','status_recomputed',
         'override_granted','override_revoked',
         'breach_logged','breach_acknowledged','breach_resolved'));

-- ── compliance_settings: the central compliance mailbox (configurable) ───────
alter table candidate.compliance_settings
  add column if not exists compliance_alert_email text;

-- ── compliance_breaches: one row per booked-non-compliant placement ──────────
-- Core fields (candidate/set/shift/snapshot/via_override) are written ONCE at
-- log time and never rewritten; only the lifecycle columns move. RLS below makes
-- this officer-read-only and NOT client-writable — writes go through the RPCs.
create table if not exists candidate.compliance_breaches (
  id              uuid primary key default gen_random_uuid(),
  candidate_id    uuid not null references candidate.candidates(id) on delete cascade,
  set_id          uuid references candidate.requirement_sets(id) on delete set null,
  shift_date      date not null,
  booking_ref     text,
  reason          text,
  via_override    boolean not null default false,   -- true = only bookable via a manager override
  override_id     uuid references candidate.compliance_overrides(id) on delete set null,
  expired_items   jsonb not null default '[]',      -- snapshot: [{code,name,expires_at,status}]
  status          text not null default 'open'
                  check (status in ('open','acknowledged','resolved')),
  booked_by       uuid references auth.users(id) on delete set null,
  booked_by_email text,
  booked_at       timestamptz not null default now(),
  acknowledged_by uuid references auth.users(id) on delete set null,
  acknowledged_at timestamptz,
  resolved_by     uuid references auth.users(id) on delete set null,
  resolved_at     timestamptz,
  notes           text
);

-- Idempotency guard: the same booking can't double-log. coalesce(booking_ref,'')
-- so a null ref still collapses repeat calls for the same candidate/set/shift.
create unique index if not exists compliance_breaches_booking_uq
  on candidate.compliance_breaches (candidate_id, set_id, shift_date, coalesce(booking_ref, ''));
create index if not exists compliance_breaches_open_idx
  on candidate.compliance_breaches (status) where status <> 'resolved';
create index if not exists compliance_breaches_candidate_idx
  on candidate.compliance_breaches (candidate_id);
create index if not exists compliance_breaches_shift_idx
  on candidate.compliance_breaches (shift_date);

-- ── RLS: compliance officers may READ; NO write policy => not client-writable ─
alter table candidate.compliance_breaches enable row level security;
drop policy if exists "officer read breaches" on candidate.compliance_breaches;
create policy "officer read breaches" on candidate.compliance_breaches
  for select to authenticated
  using (candidate.is_authorized_user() and candidate.is_compliance_officer());
-- SELECT only at the grant level too: the RPCs (SECURITY DEFINER) do every write.
grant select on candidate.compliance_breaches to authenticated;

-- ── record_booking_breach: verify → snapshot → log (idempotent) → audit ──────
-- Gate mirrors sql/38's service-or-officer pattern: an officer (UI) OR the
-- service_role edge function (booking system) may call. NEVER logs a spurious
-- breach — if the candidate is genuinely compliant (green/amber and NOT relying
-- on an override) it RAISES instead. Idempotent on the booking guard: a repeat
-- call returns the same id and appends no second audit row.
create or replace function candidate.record_booking_breach(
    p_candidate_id    uuid,
    p_set_id          uuid,
    p_shift_date      date,
    p_booking_ref     text default null,
    p_reason          text default null,
    p_booked_by_email text default null,
    p_buffer_days     int  default null)
returns uuid language plpgsql security definer
set search_path = candidate, public as $$
declare
  v_is_service boolean := candidate.is_service_role();
  v_actor      uuid    := auth.uid();
  v_status     text;
  v_overridden boolean;
  v_items      jsonb;
  v_override_id uuid;
  v_count      int;
  v_id         uuid;
  v_inserted   boolean;
begin
  if not (candidate.is_compliance_officer() or v_is_service) then
    raise exception 'not authorized';
  end if;
  if p_shift_date is null then
    raise exception 'shift_date is required';
  end if;
  -- set_id is mandatory: a breach is always against a specific requirement set, and
  -- a NULL set_id would defeat the idempotency guard (NULLs compare as distinct, so
  -- ON CONFLICT never matches) — letting the same booking log duplicate rows/audit.
  if p_set_id is null then
    raise exception 'set_id is required';
  end if;

  v_status     := candidate.work_ready_status_on(p_candidate_id, p_set_id, p_shift_date, p_buffer_days);
  v_overridden := candidate.has_active_override(p_candidate_id, p_set_id, p_shift_date);

  -- A breach is STRICTLY a RED light (a genuinely elapsed/unsatisfied blocking doc,
  -- or the fail-closed reds: set not held). green/amber = compliant/placeable, so
  -- there is NO breach — even if a stale/blanket override happens to be active
  -- (a compliant worker never "relies" on an override). The override only sets the
  -- via_override flag on a red breach; it never creates one.
  if v_status <> 'red' then
    raise exception 'no breach: candidate is compliant for %', p_shift_date;
  end if;

  -- Snapshot the elapsed/unsatisfied required docs as-of the shift date+buffer.
  select coalesce(jsonb_agg(jsonb_build_object(
           'code', code, 'name', name, 'expires_at', expires_at, 'status', status)), '[]'::jsonb)
    into v_items
  from candidate.noncompliant_items_on(p_candidate_id, p_set_id, p_shift_date, p_buffer_days);
  v_count := jsonb_array_length(v_items);

  -- The live override row rescuing this booking (if any).
  if v_overridden then
    select o.id into v_override_id
    from candidate.compliance_overrides o
    where o.candidate_id = p_candidate_id
      and o.revoked_at is null
      and (o.set_id is null or o.set_id = p_set_id)
      and o.valid_from  <= p_shift_date
      and o.valid_until >= p_shift_date
    order by o.valid_until desc
    limit 1;
  end if;

  -- Log it. ON CONFLICT (the booking guard) makes a repeat call idempotent — it
  -- returns the SAME id. `xmax = 0` in RETURNING is true only on a genuine INSERT,
  -- so the audit event is appended exactly once per real breach.
  insert into candidate.compliance_breaches
    (candidate_id, set_id, shift_date, booking_ref, reason, via_override, override_id,
     expired_items, status, booked_by, booked_by_email)
  values
    (p_candidate_id, p_set_id, p_shift_date, p_booking_ref, p_reason, v_overridden, v_override_id,
     v_items, 'open', v_actor, p_booked_by_email)
  -- Idempotent: a repeat call for the same booking returns the SAME id and does NOT
  -- rewrite the original (immutable) breach — the no-op `set` keeps the first-logged
  -- reason intact while still yielding a RETURNING row. `xmax = 0` is true only on a
  -- genuine INSERT, so the audit event is appended exactly once per real breach.
  on conflict (candidate_id, set_id, shift_date, coalesce(booking_ref, ''))
  do update set reason = candidate.compliance_breaches.reason
  returning id, (xmax = 0) into v_id, v_inserted;

  if v_inserted then
    insert into candidate.verification_events
      (candidate_id, set_id, event_type, method, source_ref, notes, actor, actor_kind)
    values
      (p_candidate_id, p_set_id, 'breach_logged',
       case when v_actor is not null then 'human' else 'system' end,
       v_id::text,
       format('booking breach LOGGED for shift %s — %s required document(s) elapsed/unsatisfied%s',
              p_shift_date, v_count,
              case when v_overridden then ' (permitted only by a manager override)' else '' end),
       v_actor,
       case when v_actor is not null then 'human' else 'system' end);
  end if;

  return v_id;
end;
$$;
revoke all on function candidate.record_booking_breach(uuid, uuid, date, text, text, text, int) from public;
grant execute on function candidate.record_booking_breach(uuid, uuid, date, text, text, text, int) to authenticated, service_role;

-- ── acknowledge_breach: officer flips open => acknowledged (idempotent) ──────
create or replace function candidate.acknowledge_breach(p_id uuid, p_note text default null)
returns void language plpgsql security definer
set search_path = candidate, public as $$
declare v_b candidate.compliance_breaches;
begin
  if not (candidate.is_authorized_user() and candidate.is_compliance_officer()) then
    raise exception 'not authorized';
  end if;
  select * into v_b from candidate.compliance_breaches where id = p_id for update;
  if not found then
    raise exception 'breach % not found', p_id;
  end if;
  if v_b.status <> 'open' then
    return;                                        -- already acknowledged/resolved: no-op
  end if;

  update candidate.compliance_breaches
    set status = 'acknowledged', acknowledged_by = auth.uid(), acknowledged_at = now(),
        notes = coalesce(nullif(btrim(p_note), ''), notes)
    where id = p_id;

  insert into candidate.verification_events
    (candidate_id, set_id, event_type, method, source_ref, notes, actor, actor_kind)
  values
    (v_b.candidate_id, v_b.set_id, 'breach_acknowledged', 'human', p_id::text,
     coalesce(nullif(btrim(p_note), ''), 'breach acknowledged'), auth.uid(), 'human');
end;
$$;
revoke all on function candidate.acknowledge_breach(uuid, text) from public;
grant execute on function candidate.acknowledge_breach(uuid, text) to authenticated;

-- ── resolve_breach: officer flips open/acknowledged => resolved (idempotent) ─
create or replace function candidate.resolve_breach(p_id uuid, p_note text default null)
returns void language plpgsql security definer
set search_path = candidate, public as $$
declare v_b candidate.compliance_breaches;
begin
  if not (candidate.is_authorized_user() and candidate.is_compliance_officer()) then
    raise exception 'not authorized';
  end if;
  select * into v_b from candidate.compliance_breaches where id = p_id for update;
  if not found then
    raise exception 'breach % not found', p_id;
  end if;
  if v_b.status = 'resolved' then
    return;                                        -- already resolved: no-op
  end if;

  update candidate.compliance_breaches
    set status = 'resolved', resolved_by = auth.uid(), resolved_at = now(),
        notes = coalesce(nullif(btrim(p_note), ''), notes)
    where id = p_id;

  insert into candidate.verification_events
    (candidate_id, set_id, event_type, method, source_ref, notes, actor, actor_kind)
  values
    (v_b.candidate_id, v_b.set_id, 'breach_resolved', 'human', p_id::text,
     coalesce(nullif(btrim(p_note), ''), 'breach resolved'), auth.uid(), 'human');
end;
$$;
revoke all on function candidate.resolve_breach(uuid, text) from public;
grant execute on function candidate.resolve_breach(uuid, text) to authenticated;

-- ── open_breaches: the officer queue (security_invoker => officer-only RLS) ──
create or replace view candidate.open_breaches
with (security_invoker = true) as
select
  b.id,
  b.candidate_id,
  c.first_name,
  c.last_name,
  (c.first_name || ' ' || c.last_name) as candidate_name,
  c.email                              as candidate_email,
  c.compliance_officer,
  coalesce(st.full_name, au.email)     as officer_name,
  c.discipline_id,
  di.name                              as discipline_name,
  di.division_id,
  dv.name                              as division_name,
  b.set_id,
  b.shift_date,
  b.booking_ref,
  b.reason,
  b.via_override,
  b.override_id,
  b.expired_items,
  b.status,
  b.booked_by_email,
  b.booked_at,
  b.acknowledged_at,
  b.notes
from candidate.compliance_breaches b
join candidate.candidates  c  on c.id = b.candidate_id
left join candidate.staff      st on st.user_id = c.compliance_officer
left join candidate.app_users  au on au.user_id = c.compliance_officer
left join candidate.disciplines di on di.id = c.discipline_id
left join candidate.divisions  dv on dv.id = di.division_id
where b.status <> 'resolved';

grant select on candidate.open_breaches to authenticated;

-- ── compliance_breach_report: officer × division × discipline queue counts ───
-- open_breaches            = count of NON-RESOLVED breach rows (any shift date)
-- candidates_working_...   = COUNT(DISTINCT candidate) among non-resolved breaches
--                            whose shift_date >= p_as_of (currently/future working
--                            non-compliant). rollup((all dims)) adds a grand total;
--                            is_total=1 marks it (grouping() like sql/36).
create or replace function candidate.compliance_breach_report(
    p_as_of    date default current_date,
    p_division uuid default null,
    p_officer  uuid default null)
returns table(
    division_id                     uuid,
    division_name                   text,
    discipline_id                   uuid,
    discipline_name                 text,
    compliance_officer              uuid,
    officer_name                    text,
    open_breaches                   bigint,
    candidates_working_noncompliant bigint,
    is_total                        int)
language plpgsql stable security definer
set search_path = candidate, public as $$
begin
  if not (candidate.is_authorized_user() and candidate.is_compliance_officer()) then
    raise exception 'not authorized';
  end if;

  return query
  with base as (
    select
      dv.id   as division_id,   dv.name as division_name,
      di.id   as discipline_id, di.name as discipline_name,
      c.compliance_officer,
      coalesce(st.full_name, au.email) as officer_name,
      b.id as breach_id, b.candidate_id, b.shift_date
    from candidate.compliance_breaches b
    join candidate.candidates  c  on c.id = b.candidate_id
    left join candidate.disciplines di on di.id = c.discipline_id
    left join candidate.divisions  dv on dv.id = di.division_id
    left join candidate.staff      st on st.user_id = c.compliance_officer
    left join candidate.app_users  au on au.user_id = c.compliance_officer
    where b.status <> 'resolved'
      and (p_division is null or dv.id = p_division)
      and (p_officer  is null or c.compliance_officer = p_officer)
  )
  select
    base.division_id, base.division_name, base.discipline_id, base.discipline_name,
    base.compliance_officer, base.officer_name,
    count(base.breach_id) as open_breaches,
    count(distinct base.candidate_id) filter (where base.shift_date >= p_as_of)
      as candidates_working_noncompliant,
    grouping(base.division_id) as is_total
  from base
  group by rollup((base.division_id, base.division_name, base.discipline_id,
                   base.discipline_name, base.compliance_officer, base.officer_name));
end;
$$;
revoke all on function candidate.compliance_breach_report(date, uuid, uuid) from public;
grant execute on function candidate.compliance_breach_report(date, uuid, uuid) to authenticated;

-- ── breach_exec_summary: division rollup for the exec headline ───────────────
-- "N candidates working with elapsed documents" = the grand-total row's
-- candidates_working_noncompliant (is_total=1).
create or replace function candidate.breach_exec_summary(p_as_of date default current_date)
returns table(
    division_id                     uuid,
    division_name                   text,
    candidates_working_noncompliant bigint,
    open_breaches                   bigint,
    is_total                        int)
language plpgsql stable security definer
set search_path = candidate, public as $$
begin
  if not (candidate.is_authorized_user() and candidate.is_compliance_officer()) then
    raise exception 'not authorized';
  end if;

  return query
  with base as (
    select dv.id as division_id, dv.name as division_name,
           b.id as breach_id, b.candidate_id, b.shift_date
    from candidate.compliance_breaches b
    join candidate.candidates  c  on c.id = b.candidate_id
    left join candidate.disciplines di on di.id = c.discipline_id
    left join candidate.divisions  dv on dv.id = di.division_id
    where b.status <> 'resolved'
  )
  select
    base.division_id, base.division_name,
    count(distinct base.candidate_id) filter (where base.shift_date >= p_as_of)
      as candidates_working_noncompliant,
    count(base.breach_id) as open_breaches,
    grouping(base.division_id) as is_total
  from base
  group by rollup((base.division_id, base.division_name));
end;
$$;
revoke all on function candidate.breach_exec_summary(date) from public;
grant execute on function candidate.breach_exec_summary(date) to authenticated;
