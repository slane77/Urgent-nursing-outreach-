-- ============================================================================
--  Day Webster — Candidate Pipeline · Work-Ready gate (status + recompute)
--  File: candidate-pipeline/sql/23_work_ready_gate.sql
--  Run AFTER 22. Idempotent / additive.  STATUS: DRAFT — NOT YET APPLIED.
--
--  Derived red/amber/green per (candidate, set). FAIL-CLOSED: no row => not
--  work-ready. Only recompute_candidate_status() (SECURITY DEFINER) writes the
--  status table; there is no client write policy, so a green cannot be forged.
--    red   = >=1 blocking, required item not verified OR expired
--    amber = all blocking verified, but a required standard item is open
--            OR a verified item expires within the amber window
--    green = all blocking + standard required items verified and unexpired
-- ============================================================================

create table if not exists candidate.candidate_compliance_status (
  id            uuid primary key default gen_random_uuid(),
  candidate_id  uuid not null references candidate.candidates(id) on delete cascade,
  set_id        uuid not null references candidate.requirement_sets(id) on delete cascade,
  status        text not null default 'red' check (status in ('red','amber','green')),
  blocking_open int  not null default 0,     -- blocking, required items unmet
  next_expiry   timestamptz,                 -- earliest upcoming expiry (verified items)
  detail        jsonb,                       -- optional per-requirement breakdown
  computed_at   timestamptz not null default now(),
  unique (candidate_id, set_id)
);
create index if not exists candidate_compliance_status_candidate_idx
  on candidate.candidate_compliance_status (candidate_id);

-- Amber "expiring soon" window is 30 days (a literal below). Change if policy
-- differs; kept inline for Phase 0 simplicity.

create or replace function candidate.recompute_candidate_status(p_candidate_id uuid)
returns void language plpgsql security definer
set search_path = candidate, public as $$
declare
  v_set_id        uuid;
  v_blocking_open int;
  v_standard_open int;
  v_expiring      int;
  v_next_expiry   timestamptz;
  v_status        text;
begin
  -- Fail-closed on de-assignment: drop any status row for a set the candidate
  -- no longer ACTIVELY holds (assignment deleted or set active=false), so the
  -- gate reverts to "no row => not work-ready" rather than a stale green/amber.
  delete from candidate.candidate_compliance_status s
  where s.candidate_id = p_candidate_id
    and not exists (
      select 1 from candidate.candidate_requirement_sets crs
      where crs.candidate_id = p_candidate_id and crs.active and crs.set_id = s.set_id
    );

  for v_set_id in
    select crs.set_id
    from candidate.candidate_requirement_sets crs
    where crs.candidate_id = p_candidate_id and crs.active
  loop
    with reqs as (
      select rsi.requirement_id,
             coalesce(rsi.criticality, cr.criticality)   as criticality,
             coalesce(rsi.required_override, cr.required) as required
      from candidate.requirement_set_items rsi
      join candidate.compliance_requirements cr on cr.id = rsi.requirement_id
      where rsi.set_id = v_set_id
    ),
    item_state as (
      select r.requirement_id, r.criticality, r.required,
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
    )
    select
      count(*) filter (where required and criticality = 'blocking'
                         and (status is distinct from 'verified'
                              or (expires_at is not null and expires_at <= now()))),
      count(*) filter (where required and criticality = 'standard'
                         and (status is distinct from 'verified'
                              or (expires_at is not null and expires_at <= now()))),
      count(*) filter (where status = 'verified' and expires_at is not null
                         and expires_at > now()
                         and expires_at <= now() + interval '30 days'),
      min(expires_at) filter (where status = 'verified' and expires_at > now())
      into v_blocking_open, v_standard_open, v_expiring, v_next_expiry
    from item_state;

    v_status := case
      when v_blocking_open > 0                     then 'red'
      when v_standard_open > 0 or v_expiring > 0   then 'amber'
      else 'green'
    end;

    insert into candidate.candidate_compliance_status
      (candidate_id, set_id, status, blocking_open, next_expiry, computed_at)
    values (p_candidate_id, v_set_id, v_status, v_blocking_open, v_next_expiry, now())
    on conflict (candidate_id, set_id) do update
      set status = excluded.status,
          blocking_open = excluded.blocking_open,
          next_expiry   = excluded.next_expiry,
          computed_at   = now();
  end loop;
end;
$$;
-- recompute is driven by the triggers below (which run with definer rights) and
-- by service-role tooling; no direct authenticated caller needs it, so lock it
-- down rather than exposing a mutation to any logged-in user.
revoke all on function candidate.recompute_candidate_status(uuid) from public;
grant execute on function candidate.recompute_candidate_status(uuid) to service_role;

-- ── The GATE (fail-closed). Callable by staff JWT and by service_role. ──────
create or replace function candidate.is_work_ready(p_candidate_id uuid, p_set_id uuid)
returns boolean language sql stable security definer
set search_path = candidate, public as $$
  select exists (
    select 1 from candidate.candidate_compliance_status s
    where s.candidate_id = p_candidate_id
      and s.set_id = p_set_id
      and s.status in ('green','amber')   -- amber is PLACEABLE; only red blocks
  );
$$;
-- Callable by the booking system (service_role) and staff cockpit (authenticated).
-- Returns only a boolean derived from the traffic light — no PII/evidence — so
-- broad execute is acceptable; it must stay callable by service_role.
revoke all on function candidate.is_work_ready(uuid, uuid) from public;
grant execute on function candidate.is_work_ready(uuid, uuid) to authenticated, service_role;

-- Companion the read-endpoint uses to expose the traffic light. Fail-closed.
create or replace function candidate.work_ready_status(p_candidate_id uuid, p_set_id uuid)
returns text language sql stable security definer
set search_path = candidate, public as $$
  select coalesce(
    (select s.status from candidate.candidate_compliance_status s
      where s.candidate_id = p_candidate_id and s.set_id = p_set_id),
    'red');
$$;
revoke all on function candidate.work_ready_status(uuid, uuid) from public;
grant execute on function candidate.work_ready_status(uuid, uuid) to authenticated, service_role;

-- ── Triggers: recompute on every input that can change the light ────────────
create or replace function candidate.trg_recompute_from_item()
returns trigger language plpgsql security definer
set search_path = candidate, public as $$
begin
  perform candidate.recompute_candidate_status(coalesce(new.candidate_id, old.candidate_id));
  return coalesce(new, old);
end $$;

drop trigger if exists compliance_items_recompute on candidate.compliance_items;
create trigger compliance_items_recompute
  after insert or update of status, expires_at, requirement_id or delete
  on candidate.compliance_items
  for each row execute function candidate.trg_recompute_from_item();

create or replace function candidate.trg_recompute_from_cand_set()
returns trigger language plpgsql security definer
set search_path = candidate, public as $$
begin
  perform candidate.recompute_candidate_status(coalesce(new.candidate_id, old.candidate_id));
  return coalesce(new, old);
end $$;

drop trigger if exists cand_sets_recompute on candidate.candidate_requirement_sets;
create trigger cand_sets_recompute
  after insert or update or delete
  on candidate.candidate_requirement_sets
  for each row execute function candidate.trg_recompute_from_cand_set();

-- Set-definition edits fan out to every candidate holding that set.
create or replace function candidate.trg_recompute_from_set_item()
returns trigger language plpgsql security definer
set search_path = candidate, public as $$
begin
  perform candidate.recompute_candidate_status(crs.candidate_id)
  from candidate.candidate_requirement_sets crs
  where crs.set_id = coalesce(new.set_id, old.set_id) and crs.active;
  return coalesce(new, old);
end $$;

drop trigger if exists set_items_recompute on candidate.requirement_set_items;
create trigger set_items_recompute
  after insert or update or delete
  on candidate.requirement_set_items
  for each row execute function candidate.trg_recompute_from_set_item();

-- ── RLS: traffic light readable to all authorised staff; NO write policy ────
alter table candidate.candidate_compliance_status enable row level security;
drop policy if exists "auth read status" on candidate.candidate_compliance_status;
create policy "auth read status" on candidate.candidate_compliance_status
  for select to authenticated using (candidate.is_authorized_user());
-- (No insert/update/delete policy: only recompute() [SECURITY DEFINER] writes it.)
