-- ============================================================================
--  Day Webster — Candidate Pipeline · Compliance Phase 1: set auto-assignment
--  File: candidate-pipeline/sql/26_requirement_set_map.sql
--  Run AFTER 25. Idempotent / additive.  STATUS: DRAFT — NOT YET APPLIED.
--
--  Maps (discipline, specialty) -> requirement set(s) and auto-assigns them to a
--  candidate whenever their discipline/specialty changes. Resolution:
--    · BASE set = highest-priority non-add-on row matching (discipline, specialty);
--      a specialty match beats a discipline-wide (specialty_id is null) row.
--    · plus ALL add_on=true matches (add-ons STACK).
--  Assignments always pin the LATEST ACTIVE VERSION of the resolved set code.
--  Both functions early-return under the `candidate.bulk_load` guard so the bulk
--  migration (file 29) drives assignment itself, set-based, with no trigger storm.
-- ============================================================================

create table if not exists candidate.requirement_set_map (
  id            uuid primary key default gen_random_uuid(),
  discipline_id uuid not null references candidate.disciplines(id) on delete cascade,
  specialty_id  uuid references candidate.specialties(id) on delete cascade,
  set_id        uuid not null references candidate.requirement_sets(id) on delete cascade,
  add_on        boolean not null default false,
  active        boolean not null default true,
  priority      int not null default 100,   -- higher wins among equal-specificity base rows
  unique (discipline_id, specialty_id, set_id)
);
create index if not exists requirement_set_map_lookup_idx
  on candidate.requirement_set_map (discipline_id, specialty_id);

alter table candidate.requirement_set_map enable row level security;
drop policy if exists "auth read set_map"  on candidate.requirement_set_map;
drop policy if exists "admin write set_map" on candidate.requirement_set_map;
create policy "auth read set_map" on candidate.requirement_set_map
  for select to authenticated using (candidate.is_authorized_user());
create policy "admin write set_map" on candidate.requirement_set_map
  for all to authenticated
  using (candidate.is_authorized_user() and candidate.is_admin())
  with check (candidate.is_authorized_user() and candidate.is_admin());

-- ── materialize_items: insert `not_started` placeholders for a candidate ────
-- One placeholder per requirement across the candidate's ACTIVE sets that has no
-- compliance_item yet. `distinct` dedupes requirements shared by several sets.
create or replace function candidate.materialize_items(p_candidate_id uuid)
returns void language plpgsql security definer
set search_path = candidate, public as $$
begin
  if current_setting('candidate.bulk_load', true) = 'on' then return; end if;

  insert into candidate.compliance_items (candidate_id, requirement_id, status)
  select distinct p_candidate_id, rsi.requirement_id, 'not_started'
  from candidate.candidate_requirement_sets crs
  join candidate.requirement_set_items rsi on rsi.set_id = crs.set_id
  where crs.candidate_id = p_candidate_id and crs.active
    and not exists (
      select 1 from candidate.compliance_items ci
      where ci.candidate_id = p_candidate_id
        and ci.requirement_id = rsi.requirement_id
    );
end;
$$;
revoke all on function candidate.materialize_items(uuid) from public;
grant execute on function candidate.materialize_items(uuid) to service_role;

-- ── assign_requirement_sets: resolve + upsert + deactivate + materialize ────
create or replace function candidate.assign_requirement_sets(p_candidate_id uuid)
returns void language plpgsql security definer
set search_path = candidate, public as $$
declare
  v_disc     uuid;
  v_spec     uuid;
  v_resolved uuid[];   -- latest-active-version set ids the candidate should hold
begin
  if current_setting('candidate.bulk_load', true) = 'on' then return; end if;

  select discipline_id, primary_specialty_id into v_disc, v_spec
  from candidate.candidates where id = p_candidate_id;

  if v_disc is null then
    -- Nothing to resolve; leave any existing assignments untouched.
    return;
  end if;

  -- Resolve base (best single) + all add-ons, then map each to its latest
  -- active version id.
  select coalesce(array_agg(lv.id), '{}'::uuid[])
  into v_resolved
  from (
    with matches as (
      select m.set_id, m.add_on, m.priority,
             (m.specialty_id is not null) as spec_match
      from candidate.requirement_set_map m
      where m.active
        and m.discipline_id = v_disc
        and (m.specialty_id is null or m.specialty_id = v_spec)
    ),
    base as (
      select set_id from matches
      where not add_on
      order by spec_match desc, priority desc
      limit 1
    ),
    chosen as (
      select set_id from base
      union
      select set_id from matches where add_on
    )
    select distinct rs.code
    from chosen c
    join candidate.requirement_sets rs on rs.id = c.set_id
  ) codes
  join lateral (
    select rs2.id
    from candidate.requirement_sets rs2
    where rs2.code = codes.code and rs2.status = 'active'
    order by rs2.version desc
    limit 1
  ) lv on true;

  -- Upsert the resolved sets active.
  insert into candidate.candidate_requirement_sets
    (candidate_id, set_id, set_code, set_version, active)
  select p_candidate_id, rs.id, rs.code, rs.version, true
  from unnest(v_resolved) as r(set_id)
  join candidate.requirement_sets rs on rs.id = r.set_id
  on conflict (candidate_id, set_id) do update set active = true;

  -- Deactivate previously-assigned sets that no longer resolve (Phase 0
  -- recompute then drops their stale status row => fail-closed).
  update candidate.candidate_requirement_sets crs
  set active = false
  where crs.candidate_id = p_candidate_id
    and crs.active
    and not (crs.set_id = any(v_resolved));

  perform candidate.materialize_items(p_candidate_id);
end;
$$;
revoke all on function candidate.assign_requirement_sets(uuid) from public;
grant execute on function candidate.assign_requirement_sets(uuid) to service_role;

-- ── Day-to-day trigger: (re)assign on discipline/specialty change ───────────
create or replace function candidate.trg_assign_sets()
returns trigger language plpgsql security definer
set search_path = candidate, public as $$
begin
  if current_setting('candidate.bulk_load', true) = 'on' then return new; end if;
  perform candidate.assign_requirement_sets(new.id);
  return new;
end $$;

drop trigger if exists candidates_assign_sets on candidate.candidates;
create trigger candidates_assign_sets
  after insert or update of discipline_id, primary_specialty_id
  on candidate.candidates
  for each row execute function candidate.trg_assign_sets();
