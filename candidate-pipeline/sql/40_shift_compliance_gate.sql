-- ============================================================================
--  Day Webster — Candidate Pipeline · Shift-date work-ready gate + buffer + override
--  File: candidate-pipeline/sql/40_shift_compliance_gate.sql
--  Run AFTER 22–25 (needs the sets/items/status spine + verification_events).
--  Idempotent / additive.  STATUS: DRAFT — NOT YET APPLIED.
--
--  [DECISION E2/E3] Booking must confirm the candidate is compliant FOR THE
--  SHIFT DATE (not just today), with a small configurable BUFFER (no bookings
--  within N days of an expiry, default 3), plus a manager OVERRIDE that is
--  audited, reasoned, time-bounded and VISIBLE. Hard cut-off at expiry — the
--  override is the only exception.
--
--  Adds:
--    · compliance_settings          — single-row config (booking_buffer_days)
--    · booking_buffer_days()        — read the configured buffer (default 3)
--    · work_ready_status_on()       — red/amber/green evaluated AS-OF a date+buffer
--    · is_work_ready_on()           — the shift-date gate (override-aware)
--    · has_active_override()        — does a live override cover (candidate,set,date)
--    · compliance_overrides         — sensitive; READ = officer, NO client writes
--    · grant/revoke_compliance_override() — officer-gated, reasoned, audited RPCs
--
--  FAIL-CLOSED like is_work_ready(): no active assignment / no data => 'red'.
--  The override NEVER auto-verifies items — the underlying items stay red so the
--  audit shows the true state PLUS the override; it only PERMITS booking.
-- ============================================================================

-- ── Config: a single-row settings table + a configurable booking buffer ─────
-- Singleton enforced by a boolean PK pinned to true. Buffer is configurable;
-- an admin can UPDATE the one row. Default 3 days.
create table if not exists candidate.compliance_settings (
  id                  boolean primary key default true check (id),
  booking_buffer_days int not null default 3 check (booking_buffer_days >= 0),
  updated_at          timestamptz not null default now(),
  updated_by          uuid references auth.users(id) on delete set null
);
insert into candidate.compliance_settings (id) values (true) on conflict (id) do nothing;

create or replace function candidate.booking_buffer_days()
returns int language sql stable security definer
set search_path = candidate, public as $$
  select coalesce((select booking_buffer_days from candidate.compliance_settings where id = true), 3);
$$;
revoke all on function candidate.booking_buffer_days() from public;
grant execute on function candidate.booking_buffer_days() to authenticated, service_role;

-- ── Manager OVERRIDE table (sensitive) — defined early so the SQL-language ──
-- readiness helpers below can reference it. Writes go ONLY through the RPCs.
create table if not exists candidate.compliance_overrides (
  id            uuid primary key default gen_random_uuid(),
  candidate_id  uuid not null references candidate.candidates(id) on delete cascade,
  set_id        uuid references candidate.requirement_sets(id) on delete cascade, -- null = ALL sets
  reason        text not null check (length(btrim(reason)) > 0),
  granted_by    uuid references auth.users(id) on delete set null,
  granted_at    timestamptz not null default now(),
  valid_from    date not null default current_date,
  valid_until   date not null,
  revoked_at    timestamptz,
  revoked_by    uuid references auth.users(id) on delete set null,
  revoke_reason text,
  check (valid_until >= valid_from)
);
create index if not exists compliance_overrides_candidate_idx
  on candidate.compliance_overrides (candidate_id);
create index if not exists compliance_overrides_live_idx
  on candidate.compliance_overrides (candidate_id, set_id, valid_until)
  where revoked_at is null;

-- Extend the append-only audit vocabulary with a legible override lifecycle pair
-- so an auditor can trace grants/revokes by event_type (not just free-text notes).
-- Drop-then-add keeps this idempotent; the new list is a strict superset so no
-- existing verification_events row is invalidated.
alter table candidate.verification_events
  drop constraint if exists verification_events_event_type_check;
alter table candidate.verification_events
  add constraint verification_events_event_type_check
  check (event_type in ('verified','rejected','unsuitable','expired','waived',
         'reinstated','evidence_received','recheck_requested','status_recomputed',
         'override_granted','override_revoked'));

-- ── AS-OF traffic light: red/amber/green for a shift DATE (+buffer) ──────────
-- Mirrors recompute_candidate_status()'s red/amber/green logic (waived handling
-- included), but evaluated against a CUT-OFF = p_as_of + buffer instead of now().
-- A blocking/standard REQUIRED item counts satisfied only if it is 'verified'
-- (or 'waived') AND (expires_at is null OR expires_at > cut-off). FAIL-CLOSED:
-- a candidate not ACTIVELY holding the set => 'red'.
create or replace function candidate.work_ready_status_on(
  p_candidate_id uuid, p_set_id uuid, p_as_of date, p_buffer_days int default null)
returns text language plpgsql stable security definer
set search_path = candidate, public as $$
declare
  v_buffer        int := greatest(coalesce(p_buffer_days, candidate.booking_buffer_days()), 0);
  v_cut           timestamptz;
  v_blocking_open int;
  v_standard_open int;
  v_waived_block  int;
  v_expiring      int;
  v_has_set       boolean;
begin
  -- Fail-closed: the candidate must actively hold this set to be evaluated.
  select exists (
    select 1 from candidate.candidate_requirement_sets crs
    where crs.candidate_id = p_candidate_id and crs.set_id = p_set_id and crs.active
  ) into v_has_set;
  if not v_has_set then
    return 'red';
  end if;

  -- Cut-off = the shift date + buffer, but NEVER earlier than now(): a same-day
  -- (or past) evaluation with a small/zero buffer must not treat a document that
  -- already lapsed *today* as still valid (that would book past a same-day expiry
  -- with no override — the LOCKED hard cut-off). Clamping to now() makes an
  -- as-of=today check identical to recompute_candidate_status()'s now() compare,
  -- and leaves genuinely future cut-offs (future shift, or today+buffer) untouched.
  v_cut := greatest(now(), (p_as_of + make_interval(days => v_buffer))::timestamptz);

  with reqs as (
    select rsi.requirement_id,
           coalesce(rsi.criticality, cr.criticality)   as criticality,
           coalesce(rsi.required_override, cr.required) as required
    from candidate.requirement_set_items rsi
    join candidate.compliance_requirements cr on cr.id = rsi.requirement_id
    where rsi.set_id = p_set_id
  ),
  item_state as (
    select r.requirement_id, r.criticality, r.required, ci.status, ci.expires_at
    from reqs r
    left join lateral (
      select ci.status, ci.expires_at
      from candidate.compliance_items ci
      where ci.candidate_id = p_candidate_id
        and ci.requirement_id = r.requirement_id
      order by (ci.status = 'verified') desc, ci.updated_at desc
      limit 1
    ) ci on true
  )
  select
    -- blocking open: required blocking not satisfied AS-OF the cut-off (waived ok).
    count(*) filter (where required and criticality = 'blocking'
                       and status is distinct from 'waived'
                       and (status is distinct from 'verified'
                            or (expires_at is not null and expires_at <= v_cut))),
    -- standard open: same, waived satisfies.
    count(*) filter (where required and criticality = 'standard'
                       and status is distinct from 'waived'
                       and (status is distinct from 'verified'
                            or (expires_at is not null and expires_at <= v_cut))),
    -- waived BLOCKING items force amber (can never be green).
    count(*) filter (where required and criticality = 'blocking' and status = 'waived'),
    -- expiring within 30 days AFTER the cut-off (informational amber).
    count(*) filter (where status = 'verified' and expires_at is not null
                       and expires_at > v_cut and expires_at <= v_cut + interval '30 days')
    into v_blocking_open, v_standard_open, v_waived_block, v_expiring
  from item_state;

  return case
    when v_blocking_open > 0                                          then 'red'
    when v_standard_open > 0 or v_expiring > 0 or v_waived_block > 0  then 'amber'
    else 'green'
  end;
end;
$$;
revoke all on function candidate.work_ready_status_on(uuid, uuid, date, int) from public;
grant execute on function candidate.work_ready_status_on(uuid, uuid, date, int) to authenticated, service_role;

-- ── Override lookup: a live override covering (candidate, set, as-of) ────────
-- set_id NULL on the override = ALL sets. Non-revoked and as-of within window.
create or replace function candidate.has_active_override(
  p_candidate_id uuid, p_set_id uuid, p_as_of date)
returns boolean language sql stable security definer
set search_path = candidate, public as $$
  select exists (
    select 1 from candidate.compliance_overrides o
    where o.candidate_id = p_candidate_id
      and o.revoked_at is null
      and (o.set_id is null or o.set_id = p_set_id)
      and o.valid_from  <= p_as_of
      and o.valid_until >= p_as_of
  );
$$;
revoke all on function candidate.has_active_override(uuid, uuid, date) from public;
grant execute on function candidate.has_active_override(uuid, uuid, date) to authenticated, service_role;

-- ── THE SHIFT-DATE GATE (fail-closed, override-aware) ───────────────────────
-- green+amber (as-of the date+buffer) => ready; red => blocked. An ACTIVE
-- override makes the candidate bookable REGARDLESS of the traffic light — the
-- caller can see this because work_ready_status_on() still reports the true
-- (red) colour while is_work_ready_on() returns true (via_override at the edge).
create or replace function candidate.is_work_ready_on(
  p_candidate_id uuid, p_set_id uuid, p_as_of date, p_buffer_days int default null)
returns boolean language sql stable security definer
set search_path = candidate, public as $$
  -- The candidate must ACTIVELY hold the set (fail-closed) — an override rescues
  -- a compliance failure, it does NOT conjure eligibility for a set the candidate
  -- was never assigned. Given that, readiness comes from a live override OR a
  -- green/amber as-of light.
  select exists (
           select 1 from candidate.candidate_requirement_sets crs
           where crs.candidate_id = p_candidate_id and crs.set_id = p_set_id and crs.active
         )
     and ( candidate.has_active_override(p_candidate_id, p_set_id, p_as_of)
        or candidate.work_ready_status_on(p_candidate_id, p_set_id, p_as_of, p_buffer_days)
           in ('green','amber') );
$$;
revoke all on function candidate.is_work_ready_on(uuid, uuid, date, int) from public;
grant execute on function candidate.is_work_ready_on(uuid, uuid, date, int) to authenticated, service_role;

-- ── Manager OVERRIDE (sensitive): audited, reasoned, time-bounded, visible ──
-- (table defined near the top of this file; RLS + write RPCs below.)
-- RLS: compliance officers may READ. NO insert/update/delete policy exists, so
-- the table is NOT client-writable — the only writers are the SECURITY DEFINER
-- RPCs below (which run as the table owner and bypass RLS).
alter table candidate.compliance_overrides enable row level security;
drop policy if exists "officer read overrides" on candidate.compliance_overrides;
create policy "officer read overrides" on candidate.compliance_overrides
  for select to authenticated
  using (candidate.is_authorized_user() and candidate.is_compliance_officer());

-- grant: officer-gated, reason MANDATORY, time-bounded. Appends a 'reinstated'
-- audit row (method='human') to the append-only verification_events spine.
create or replace function candidate.grant_compliance_override(
  p_candidate_id uuid, p_set_id uuid, p_reason text, p_valid_until date)
returns uuid language plpgsql security definer
set search_path = candidate, public as $$
declare
  v_actor uuid := auth.uid();
  v_id    uuid;
begin
  if not (candidate.is_authorized_user() and candidate.is_compliance_officer()) then
    raise exception 'not authorized';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'a reason is required to grant a compliance override';
  end if;
  if p_valid_until is null then
    raise exception 'valid_until is required';
  end if;
  if p_valid_until < current_date then
    raise exception 'valid_until (%) is in the past', p_valid_until;
  end if;

  insert into candidate.compliance_overrides
    (candidate_id, set_id, reason, granted_by, valid_from, valid_until)
  values
    (p_candidate_id, p_set_id, btrim(p_reason), v_actor, current_date, p_valid_until)
  returning id into v_id;

  -- Append-only audit — legible override lifecycle event.
  insert into candidate.verification_events
    (candidate_id, set_id, event_type, method, source_ref, notes, actor, actor_kind)
  values
    (p_candidate_id, p_set_id, 'override_granted', 'human', v_id::text,
     format('booking override GRANTED until %s%s — reason: %s',
            p_valid_until,
            case when p_set_id is null then ' (all sets)' else '' end,
            btrim(p_reason)),
     v_actor, 'human');

  return v_id;
end;
$$;
revoke all on function candidate.grant_compliance_override(uuid, uuid, text, date) from public;
grant execute on function candidate.grant_compliance_override(uuid, uuid, text, date) to authenticated;

-- revoke: officer-gated, reason MANDATORY, idempotent. Appends an audit row.
create or replace function candidate.revoke_compliance_override(p_id uuid, p_reason text)
returns void language plpgsql security definer
set search_path = candidate, public as $$
declare
  v_actor uuid := auth.uid();
  v_ovr   candidate.compliance_overrides;
begin
  if not (candidate.is_authorized_user() and candidate.is_compliance_officer()) then
    raise exception 'not authorized';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'a reason is required to revoke a compliance override';
  end if;

  select * into v_ovr from candidate.compliance_overrides where id = p_id for update;
  if not found then
    raise exception 'override % not found', p_id;
  end if;
  if v_ovr.revoked_at is not null then
    return;                                     -- already revoked: idempotent no-op
  end if;

  update candidate.compliance_overrides
    set revoked_at = now(), revoked_by = v_actor, revoke_reason = btrim(p_reason)
    where id = p_id;

  insert into candidate.verification_events
    (candidate_id, set_id, event_type, method, source_ref, notes, actor, actor_kind)
  values
    (v_ovr.candidate_id, v_ovr.set_id, 'override_revoked', 'human', p_id::text,
     format('booking override REVOKED — reason: %s', btrim(p_reason)),
     v_actor, 'human');
end;
$$;
revoke all on function candidate.revoke_compliance_override(uuid, text) from public;
grant execute on function candidate.revoke_compliance_override(uuid, text) to authenticated;

-- ── RLS: compliance_settings — authorised staff read; admins write ──────────
alter table candidate.compliance_settings enable row level security;
drop policy if exists "auth read settings"  on candidate.compliance_settings;
drop policy if exists "admin write settings" on candidate.compliance_settings;
create policy "auth read settings" on candidate.compliance_settings
  for select to authenticated using (candidate.is_authorized_user());
create policy "admin write settings" on candidate.compliance_settings
  for all to authenticated
  using (candidate.is_authorized_user() and candidate.is_admin())
  with check (candidate.is_authorized_user() and candidate.is_admin());
