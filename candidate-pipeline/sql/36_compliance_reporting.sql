-- ============================================================================
--  Day Webster — Candidate Pipeline · Compliance reporting layer
--  File: candidate-pipeline/sql/36_compliance_reporting.sql
--  Run AFTER 33-35. Idempotent / additive.  STATUS: DRAFT — NOT YET APPLIED.
--
--  Roll-up reporting over the traffic lights:
--    · candidate_overall_status — ONE row per in-pipeline candidate, collapsing
--      their per-set lights into a single overall RAG (fail-closed).
--    · compliance_officer_report — candidate counts by officer × division ×
--      discipline × RAG, scoped to an overseer / officer / division.
--    · compliance_exec_overview  — division/discipline rollup: in-pipeline,
--      red, amber, green (green = ready-to-work).
--
--  Both RPCs are SECURITY DEFINER + gated is_compliance_officer(); they read the
--  security_invoker view under definer rights, so a compliance officer sees the
--  whole bench regardless of desk silo.
-- ============================================================================

-- ── One overall RAG per in-pipeline candidate (fail-closed) ─────────────────
-- INNER JOIN to active sets => only candidates actually in the pipeline. A set
-- with NO status row coalesces to 'red' (fail-closed). One row per candidate, so
-- a candidate is never double-counted no matter how many sets they hold.
create or replace view candidate.candidate_overall_status
with (security_invoker = true) as
select
  c.id                as candidate_id,
  c.compliance_officer,
  c.discipline_id,
  d.division_id,
  count(*)            as active_set_count,
  case
    when bool_or(coalesce(s.status, 'red') = 'red')   then 'red'
    when bool_or(coalesce(s.status, 'red') = 'amber') then 'amber'
    else 'green'
  end                 as overall_rag
from candidate.candidates c
join candidate.candidate_requirement_sets crs
  on crs.candidate_id = c.id and crs.active
left join candidate.candidate_compliance_status s
  on s.candidate_id = crs.candidate_id and s.set_id = crs.set_id
left join candidate.disciplines d on d.id = c.discipline_id
group by c.id, c.compliance_officer, c.discipline_id, d.division_id;

grant select on candidate.candidate_overall_status to authenticated;

-- ── Officer report: counts by officer × division × discipline × RAG ─────────
create or replace function candidate.compliance_officer_report(
    p_overseer uuid default null,
    p_officer  uuid default null,
    p_division uuid default null)
returns table(
    officer         uuid,
    officer_name    text,
    overseen_by     uuid,
    division_id     uuid,
    division_name   text,
    discipline_id   uuid,
    discipline_name text,
    overall_rag     text,
    candidate_count bigint)
language plpgsql stable security definer
set search_path = candidate, public as $$
begin
  if not (candidate.is_authorized_user() and candidate.is_compliance_officer()) then
    raise exception 'not authorized';
  end if;

  return query
    select
      os.compliance_officer,
      coalesce(st.full_name, au.email),
      st.overseen_by,
      os.division_id,
      dv.name,
      os.discipline_id,
      d.name,
      os.overall_rag,
      count(*)
    from candidate.candidate_overall_status os
    left join candidate.staff      st on st.user_id = os.compliance_officer
    left join candidate.app_users  au on au.user_id = os.compliance_officer
    left join candidate.divisions  dv on dv.id = os.division_id
    left join candidate.disciplines d on d.id = os.discipline_id
    where (p_officer  is null or os.compliance_officer = p_officer)
      and (p_division is null or os.division_id = p_division)
      -- Scope to an overseer's team; still surface UNASSIGNED candidates (no
      -- officer) so nothing falls through the cracks.
      and (p_overseer is null
           or st.overseen_by = p_overseer
           or os.compliance_officer is null)
    group by os.compliance_officer, coalesce(st.full_name, au.email), st.overseen_by,
             os.division_id, dv.name, os.discipline_id, d.name, os.overall_rag;
end;
$$;
revoke all on function candidate.compliance_officer_report(uuid, uuid, uuid) from public;
grant execute on function candidate.compliance_officer_report(uuid, uuid, uuid) to authenticated;

-- ── Exec overview: division/discipline rollup with RAG counters ─────────────
-- rollup over (division) then (division, discipline) — id+name grouped as a
-- single unit so the FD name never spawns a redundant subtotal level. NULLs in
-- division_id/discipline_id mark the subtotal / grand-total rows.
create or replace function candidate.compliance_exec_overview(p_division uuid default null)
returns table(
    division_id     uuid,
    division_name   text,
    discipline_id   uuid,
    discipline_name text,
    in_pipeline     bigint,
    red             bigint,
    amber           bigint,
    green           bigint,
    -- ROLLUP markers so a consumer can tell a subtotal/grand-total row apart
    -- from a genuine candidate that has NO division/discipline (both would
    -- otherwise show NULL ids). is_division_total=1 => grand total;
    -- is_discipline_total=1 (with is_division_total=0) => a division subtotal;
    -- both 0 => a real detail row (division/discipline may still be NULL).
    is_division_total   int,
    is_discipline_total int)
language plpgsql stable security definer
set search_path = candidate, public as $$
begin
  if not (candidate.is_authorized_user() and candidate.is_compliance_officer()) then
    raise exception 'not authorized';
  end if;

  return query
    select
      os.division_id,
      dv.name,
      os.discipline_id,
      d.name,
      count(*),
      count(*) filter (where os.overall_rag = 'red'),
      count(*) filter (where os.overall_rag = 'amber'),
      count(*) filter (where os.overall_rag = 'green'),  -- green = ready-to-work
      grouping(os.division_id),
      grouping(os.discipline_id)
    from candidate.candidate_overall_status os
    left join candidate.divisions   dv on dv.id = os.division_id
    left join candidate.disciplines d  on d.id = os.discipline_id
    where (p_division is null or os.division_id = p_division)
    group by rollup((os.division_id, dv.name), (os.discipline_id, d.name));
end;
$$;
revoke all on function candidate.compliance_exec_overview(uuid) from public;
grant execute on function candidate.compliance_exec_overview(uuid) to authenticated;
