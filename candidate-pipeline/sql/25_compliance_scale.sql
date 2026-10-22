-- ============================================================================
--  Day Webster — Candidate Pipeline · Compliance Phase 1: scale + bulk guard
--  File: candidate-pipeline/sql/25_compliance_scale.sql
--  Run AFTER 22, 23, 24. Idempotent / additive.  STATUS: DRAFT — NOT YET APPLIED.
--
--  Prepares the Phase 0 gate for 10–15k candidates / ~150k items:
--    · adds 'waived' to compliance_items.status + a `migrated` provenance flag
--    · a transaction-local `candidate.bulk_load` guard so the recompute/assign
--      triggers early-return during a set-based bulk migration (no trigger storm)
--    · extends recompute_candidate_status() to write two indexed scalars
--      (needs_human_count, expiring_count) the worklist filters/sorts on, and to
--      treat a WAIVED blocking item as satisfied-but-capped-at-amber (never green)
--    · recompute_candidate_status_bulk(uuid[]) — one call per migration batch
--    · lets compliance officers read the whole bench (desk-silo exemption)
--    · the scale indexes for the recompute hot path + worklist filters
-- ============================================================================

-- ── compliance_items: 'waived' status + migrated provenance flag ────────────
-- The status check is an unnamed column check; Postgres names it
-- <table>_<column>_check. Drop + re-add to widen the domain idempotently.
alter table candidate.compliance_items drop constraint if exists compliance_items_status_check;
alter table candidate.compliance_items add constraint compliance_items_status_check
  check (status in ('not_started','requested','received','verifying',
                    'verified','unsuitable','expired','waived'));

alter table candidate.compliance_items
  add column if not exists migrated boolean not null default false;

-- ── candidate_compliance_status: precomputed scalars for the worklist ───────
-- Filtering/sorting a 15k-row worklist on these scalars is indexable; computing
-- them live over 150k items per query is not.
alter table candidate.candidate_compliance_status
  add column if not exists needs_human_count int not null default 0,
  add column if not exists expiring_count    int not null default 0;

-- ── Recompute: waived handling + the two new scalars ────────────────────────
-- Semantics vs Phase 0:
--   · a WAIVED blocking/standard item is treated as SATISFIED (does not count as
--     open), but a waived BLOCKING item caps the set at amber — it can never go
--     green (D3).
--   · needs_human_count = requirements whose latest item is awaiting a human
--     (received/verifying), is flagged needs_human, or is a migrated item due
--     re-verification.
--   · expiring_count = verified items expiring inside the 30-day amber window.
create or replace function candidate.recompute_candidate_status(p_candidate_id uuid)
returns void language plpgsql security definer
set search_path = candidate, public as $$
declare
  v_set_id        uuid;
  v_blocking_open int;
  v_standard_open int;
  v_waived_block  int;
  v_expiring      int;
  v_needs_human   int;
  v_next_expiry   timestamptz;
  v_status        text;
begin
  -- Fail-closed on de-assignment: drop any status row for a set the candidate
  -- no longer ACTIVELY holds, so the gate reverts to "no row => not work-ready".
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
             ci.status, ci.expires_at, ci.needs_human, ci.migrated
      from reqs r
      left join lateral (
        select ci.status, ci.expires_at, ci.needs_human, ci.migrated
        from candidate.compliance_items ci
        where ci.candidate_id = p_candidate_id
          and ci.requirement_id = r.requirement_id
        order by (ci.status = 'verified') desc, ci.updated_at desc
        limit 1
      ) ci on true
    )
    select
      -- blocking open: required blocking not satisfied. WAIVED counts as satisfied.
      count(*) filter (where required and criticality = 'blocking'
                         and status is distinct from 'waived'
                         and (status is distinct from 'verified'
                              or (expires_at is not null and expires_at <= now()))),
      -- standard open: same, waived satisfies.
      count(*) filter (where required and criticality = 'standard'
                         and status is distinct from 'waived'
                         and (status is distinct from 'verified'
                              or (expires_at is not null and expires_at <= now()))),
      -- waived BLOCKING items force amber (cannot be green).
      count(*) filter (where required and criticality = 'blocking'
                         and status = 'waived'),
      -- expiring soon (30-day amber window) among verified, unexpired items.
      count(*) filter (where status = 'verified' and expires_at is not null
                         and expires_at > now()
                         and expires_at <= now() + interval '30 days'),
      -- needs a human: awaiting decision, flagged, or a migrated item to re-verify.
      count(*) filter (where status is not null
                         and (status in ('received','verifying')
                              or needs_human or migrated)),
      min(expires_at) filter (where status = 'verified' and expires_at > now())
      into v_blocking_open, v_standard_open, v_waived_block, v_expiring, v_needs_human, v_next_expiry
    from item_state;

    v_status := case
      when v_blocking_open > 0                                      then 'red'
      when v_standard_open > 0 or v_expiring > 0 or v_waived_block > 0 then 'amber'
      else 'green'
    end;

    insert into candidate.candidate_compliance_status
      (candidate_id, set_id, status, blocking_open, needs_human_count,
       expiring_count, next_expiry, computed_at)
    values
      (p_candidate_id, v_set_id, v_status, v_blocking_open, v_needs_human,
       v_expiring, v_next_expiry, now())
    on conflict (candidate_id, set_id) do update
      set status            = excluded.status,
          blocking_open     = excluded.blocking_open,
          needs_human_count = excluded.needs_human_count,
          expiring_count    = excluded.expiring_count,
          next_expiry       = excluded.next_expiry,
          computed_at       = now();
  end loop;
end;
$$;
revoke all on function candidate.recompute_candidate_status(uuid) from public;
grant execute on function candidate.recompute_candidate_status(uuid) to service_role;

-- ── Batch recompute (one call per migration batch) ──────────────────────────
create or replace function candidate.recompute_candidate_status_bulk(p_ids uuid[])
returns void language plpgsql security definer
set search_path = candidate, public as $$
declare v_id uuid;
begin
  foreach v_id in array coalesce(p_ids, '{}'::uuid[]) loop
    perform candidate.recompute_candidate_status(v_id);
  end loop;
end;
$$;
revoke all on function candidate.recompute_candidate_status_bulk(uuid[]) from public;
grant execute on function candidate.recompute_candidate_status_bulk(uuid[]) to service_role;

-- ── Trigger guard: early-return during a bulk load ──────────────────────────
-- `set_config('candidate.bulk_load','on', true)` is transaction-local, so the
-- migration RPC disables these fan-out triggers for its own transaction only.
-- current_setting(..., true) returns NULL when unset => normal operation.
create or replace function candidate.trg_recompute_from_item()
returns trigger language plpgsql security definer
set search_path = candidate, public as $$
begin
  if current_setting('candidate.bulk_load', true) = 'on' then
    return coalesce(new, old);
  end if;
  perform candidate.recompute_candidate_status(coalesce(new.candidate_id, old.candidate_id));
  return coalesce(new, old);
end $$;

create or replace function candidate.trg_recompute_from_cand_set()
returns trigger language plpgsql security definer
set search_path = candidate, public as $$
begin
  if current_setting('candidate.bulk_load', true) = 'on' then
    return coalesce(new, old);
  end if;
  perform candidate.recompute_candidate_status(coalesce(new.candidate_id, old.candidate_id));
  return coalesce(new, old);
end $$;

create or replace function candidate.trg_recompute_from_set_item()
returns trigger language plpgsql security definer
set search_path = candidate, public as $$
begin
  if current_setting('candidate.bulk_load', true) = 'on' then
    return coalesce(new, old);
  end if;
  perform candidate.recompute_candidate_status(crs.candidate_id)
  from candidate.candidate_requirement_sets crs
  where crs.set_id = coalesce(new.set_id, old.set_id) and crs.active;
  return coalesce(new, old);
end $$;

-- ── RLS: let compliance officers see the whole bench ────────────────────────
-- Amends the 18_desks.sql desk-silo read policy. Recruiters still see only their
-- desk(s); compliance officers (and admins) see every candidate.
drop policy if exists "desk read candidates" on candidate.candidates;
create policy "desk read candidates" on candidate.candidates for select to authenticated
  using (candidate.is_authorized_user()
         and (candidate.is_admin()
              or candidate.is_compliance_officer()
              or desk_id in (select candidate.my_desk_ids())));

-- ── Scale indexes ───────────────────────────────────────────────────────────
-- The recompute lateral hot path (latest item per candidate+requirement).
create index if not exists compliance_items_recompute_idx
  on candidate.compliance_items (candidate_id, requirement_id, updated_at desc);
create index if not exists compliance_items_requirement_idx
  on candidate.compliance_items (requirement_id);
create index if not exists compliance_items_migrated_idx
  on candidate.compliance_items (migrated) where migrated;

create index if not exists candidate_compliance_status_status_idx
  on candidate.candidate_compliance_status (status);
create index if not exists candidate_compliance_status_set_status_idx
  on candidate.candidate_compliance_status (set_id, status);
create index if not exists candidate_compliance_status_expiry_idx
  on candidate.candidate_compliance_status (next_expiry);

create index if not exists candidate_requirement_sets_active_set_idx
  on candidate.candidate_requirement_sets (set_id) where active;
