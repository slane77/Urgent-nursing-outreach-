-- ============================================================================
--  Day Webster — Candidate Pipeline · Compliance Phase 1: ops surface
--  File: candidate-pipeline/sql/29_compliance_ops.sql
--  Run AFTER 22-28. Idempotent / additive.  STATUS: DRAFT — NOT YET APPLIED.
--
--  The compliance team's server side:
--    · compliance_worklist  — security_invoker view (one row per candidate+set),
--      pre-joined so the cockpit paginates on indexed scalars.
--    · compliance_dashboard(desk,set) — RAG / expiring / needs-review / backlog.
--    · decide_item(item,decision,reason) — atomic status update + audit event.
--    · bulk_assign_set / bulk_request    — bulk_load-guarded, one recompute.
--    · import_compliance_bulk(rows)      — the set-based migration path (D1/D2).
--
--  Invariants preserved: candidate_compliance_status keeps NO client write
--  policy (only SECURITY DEFINER recompute writes it); verification_events stays
--  append-only. Every SECURITY DEFINER fn pins search_path = candidate, public.
-- ============================================================================

-- ── Worklist view (security_invoker: RLS is the querying user's) ────────────
-- A recruiter sees only their desk's rows; a compliance officer / admin sees the
-- whole bench (25_ desk-read policy). One row per (candidate, active set).
create or replace view candidate.compliance_worklist
with (security_invoker = true) as
select
  s.candidate_id,
  s.set_id,
  s.status,
  s.blocking_open,
  s.needs_human_count,
  s.expiring_count,
  s.next_expiry,
  s.computed_at,
  crs.set_code,
  crs.set_version,
  c.first_name,
  c.last_name,
  c.email,
  c.phone,
  c.discipline_id,
  c.primary_specialty_id,
  c.desk_id,
  c.owner_user,
  d.code as discipline_code,
  d.name as discipline_name,
  exists (
    select 1 from candidate.compliance_items ci
    where ci.candidate_id = s.candidate_id and ci.migrated
  ) as has_migrated
from candidate.candidate_compliance_status s
join candidate.candidate_requirement_sets crs
  on crs.candidate_id = s.candidate_id and crs.set_id = s.set_id and crs.active
join candidate.candidates c on c.id = s.candidate_id
left join candidate.disciplines d on d.id = c.discipline_id;

grant select on candidate.compliance_worklist to authenticated;

-- ── Dashboard: aggregate counters for the compliance team ───────────────────
create or replace function candidate.compliance_dashboard(p_desk uuid default null,
                                                          p_set  uuid default null)
returns jsonb language plpgsql stable security definer
set search_path = candidate, public as $$
declare v jsonb;
begin
  if not (candidate.is_authorized_user() and candidate.is_compliance_officer()) then
    raise exception 'not authorized';
  end if;

  with scope as (
    select s.*
    from candidate.candidate_compliance_status s
    join candidate.candidate_requirement_sets crs
      on crs.candidate_id = s.candidate_id and crs.set_id = s.set_id and crs.active
    join candidate.candidates c on c.id = s.candidate_id
    where (p_desk is null or c.desk_id = p_desk)
      and (p_set  is null or s.set_id  = p_set)
  )
  select jsonb_build_object(
    'rag', (
      select coalesce(jsonb_object_agg(status, cnt), '{}'::jsonb)
      from (select status, count(*) cnt from scope group by status) t
    ),
    'needs_review', (select count(*) from scope where needs_human_count > 0),
    'migration_backlog', (
      select count(distinct s.candidate_id)
      from scope s
      where exists (select 1 from candidate.compliance_items ci
                    where ci.candidate_id = s.candidate_id and ci.migrated)
    ),
    'expiring', jsonb_build_object(
      'd30', (select count(*) from scope where next_expiry is not null
                and next_expiry <= now() + interval '30 days'),
      'd60', (select count(*) from scope where next_expiry is not null
                and next_expiry <= now() + interval '60 days'),
      'd90', (select count(*) from scope where next_expiry is not null
                and next_expiry <= now() + interval '90 days')
    )
  ) into v;

  return v;
end;
$$;
revoke all on function candidate.compliance_dashboard(uuid, uuid) from public;
grant execute on function candidate.compliance_dashboard(uuid, uuid) to authenticated;

-- ── decide_item: atomic decision + append-only audit event ──────────────────
-- decision ∈ {verify, reject, waive}; waive requires a reason. The compliance_
-- items update fires trg_recompute_from_item => the RAG light refreshes.
create or replace function candidate.decide_item(p_item_id  uuid,
                                                 p_decision text,
                                                 p_reason   text default null)
returns void language plpgsql security definer
set search_path = candidate, public as $$
declare
  v_item       candidate.compliance_items;
  v_new_status text;
  v_event      text;
begin
  if not (candidate.is_authorized_user() and candidate.is_compliance_officer()) then
    raise exception 'not authorized';
  end if;
  if p_decision not in ('verify', 'reject', 'waive') then
    raise exception 'unknown decision: %', p_decision;
  end if;
  if p_decision = 'waive' and (p_reason is null or btrim(p_reason) = '') then
    raise exception 'a reason is required to waive a requirement';
  end if;

  select * into v_item from candidate.compliance_items where id = p_item_id;
  if not found then
    raise exception 'compliance item % not found', p_item_id;
  end if;

  v_new_status := case p_decision
                    when 'verify' then 'verified'
                    when 'reject' then 'unsuitable'
                    when 'waive'  then 'waived' end;
  v_event      := case p_decision
                    when 'verify' then 'verified'
                    when 'reject' then 'unsuitable'
                    when 'waive'  then 'waived' end;

  update candidate.compliance_items
  set status      = v_new_status,
      -- a human verification clears the migrated re-verify flag
      migrated    = case when p_decision = 'verify' then false else migrated end,
      needs_human = false,
      decided_by  = auth.uid(),
      human_notes = coalesce(p_reason, human_notes),
      updated_at  = now()
  where id = p_item_id;

  insert into candidate.verification_events
    (candidate_id, item_id, requirement_id, event_type, old_status, new_status,
     method, notes, actor, actor_kind)
  values
    (v_item.candidate_id, p_item_id, v_item.requirement_id, v_event,
     v_item.status, v_new_status, 'human', p_reason, auth.uid(), 'human');
end;
$$;
revoke all on function candidate.decide_item(uuid, text, text) from public;
grant execute on function candidate.decide_item(uuid, text, text) to authenticated;

-- ── bulk_assign_set: assign a set (latest active version) to many candidates ─
create or replace function candidate.bulk_assign_set(p_ids uuid[], p_set_code text)
returns int language plpgsql security definer
set search_path = candidate, public as $$
declare
  v_set record;
begin
  -- D8: compliance-officer capability required (matches decide_item). No
  -- service-role bypass — the edge function calls the dedicated import RPC.
  if not candidate.is_compliance_officer() then
    raise exception 'not authorized';
  end if;

  select id, code, version into v_set
  from candidate.requirement_sets
  where code = p_set_code and status = 'active'
  order by version desc
  limit 1;
  if not found then
    raise exception 'unknown or inactive set: %', p_set_code;
  end if;

  perform set_config('candidate.bulk_load', 'on', true);

  insert into candidate.candidate_requirement_sets
    (candidate_id, set_id, set_code, set_version, active, assigned_by)
  select u.id, v_set.id, v_set.code, v_set.version, true, auth.uid()
  from unnest(p_ids) as u(id)
  join candidate.candidates c on c.id = u.id
  on conflict (candidate_id, set_id) do update set active = true;

  insert into candidate.compliance_items (candidate_id, requirement_id, status)
  select distinct u.id, rsi.requirement_id, 'not_started'
  from unnest(p_ids) as u(id)
  join candidate.requirement_set_items rsi on rsi.set_id = v_set.id
  where not exists (
    select 1 from candidate.compliance_items ci
    where ci.candidate_id = u.id and ci.requirement_id = rsi.requirement_id
  );

  perform candidate.recompute_candidate_status_bulk(p_ids);
  perform set_config('candidate.bulk_load', 'off', true);

  return coalesce(array_length(p_ids, 1), 0);
end;
$$;
revoke all on function candidate.bulk_assign_set(uuid[], text) from public;
grant execute on function candidate.bulk_assign_set(uuid[], text) to authenticated, service_role;

-- ── bulk_request: mark listed requirement codes as 'requested' ──────────────
-- Only requirements that already belong to the candidate's active set(s) are
-- touched, so we never invent an out-of-scope item.
create or replace function candidate.bulk_request(p_ids uuid[], p_codes text[])
returns int language plpgsql security definer
set search_path = candidate, public as $$
declare v_count int;
begin
  -- D8: compliance-officer capability required (matches decide_item).
  if not candidate.is_compliance_officer() then
    raise exception 'not authorized';
  end if;

  perform set_config('candidate.bulk_load', 'on', true);

  -- Create placeholders for in-scope requirements with no item yet.
  insert into candidate.compliance_items (candidate_id, requirement_id, status)
  select distinct crs.candidate_id, rsi.requirement_id, 'requested'
  from candidate.candidate_requirement_sets crs
  join candidate.requirement_set_items rsi on rsi.set_id = crs.set_id
  join candidate.compliance_requirements cr on cr.id = rsi.requirement_id
  where crs.active
    and crs.candidate_id = any(p_ids)
    and cr.code = any(p_codes)
    and not exists (
      select 1 from candidate.compliance_items ci
      where ci.candidate_id = crs.candidate_id and ci.requirement_id = rsi.requirement_id
    );

  -- Advance existing not_started items to requested.
  update candidate.compliance_items ci
  set status = 'requested', updated_at = now()
  from candidate.candidate_requirement_sets crs
  join candidate.requirement_set_items rsi on rsi.set_id = crs.set_id
  join candidate.compliance_requirements cr on cr.id = rsi.requirement_id
  where ci.candidate_id = crs.candidate_id
    and ci.requirement_id = rsi.requirement_id
    and crs.active
    and crs.candidate_id = any(p_ids)
    and cr.code = any(p_codes)
    and ci.status = 'not_started';

  perform candidate.recompute_candidate_status_bulk(p_ids);
  perform set_config('candidate.bulk_load', 'off', true);

  select coalesce(array_length(p_ids, 1), 0) into v_count;
  return v_count;
end;
$$;
revoke all on function candidate.bulk_request(uuid[], text[]) from public;
grant execute on function candidate.bulk_request(uuid[], text[]) to authenticated, service_role;

-- ── Migrated-item expiry helper (D2) ────────────────────────────────────────
-- Provided expiry wins; else derive from the catalogue rule + issue date; else
-- the 90-day migration grace window so nothing stays trusted-but-unverified.
create or replace function candidate.compute_migrated_expiry(p_rule   jsonb,
                                                             p_issue  date,
                                                             p_expiry date)
returns timestamptz language sql stable
set search_path = candidate, public as $$
  select coalesce(
    p_expiry::timestamptz,
    case
      when p_issue is null then null
      when p_rule->>'type' = 'issue_plus'
        then (p_issue + make_interval(years => (p_rule->>'years')::int))::timestamptz
      when p_rule->>'type' = 'upload_plus'
        then (p_issue + make_interval(years => (p_rule->>'years')::int))::timestamptz
      when p_rule->>'type' = 'issue_plus_days'
        then (p_issue + make_interval(days => (p_rule->>'days')::int))::timestamptz
      else null
    end,
    now() + interval '90 days'
  );
$$;

-- ── import_compliance_bulk: the set-based bulk migration (D1/D2) ─────────────
-- p_rows = jsonb array of normalized item rows produced by the compliance-import
-- edge function, each:
--   { email, phone, code, status?, issue_date?, expiry_date?, number?, evidence_note? }
-- Steps (all under the txn-local bulk_load guard so no fan-out triggers fire):
--   1 match candidate by lower(email) then phone   2 auto-assign sets via the map
--   3 set-based insert of verified/migrated items  4 one audit event per item
--   5 one recompute per batch.  Returns a match/insert report.
create or replace function candidate.import_compliance_bulk(p_rows jsonb)
returns jsonb language plpgsql security definer
set search_path = candidate, public as $$
declare
  v_total    int;
  v_unmatched int;
  v_items    int;
  v_unparsed int;
  v_oos      int;
  v_migrated_at timestamptz := now();  -- one migration timestamp for the batch
  v_result   jsonb;
begin
  perform set_config('candidate.bulk_load', 'on', true);

  -- 1. Parse + match to candidates (email first, then phone).
  --    expiry_unparsed = the source had a non-empty expiry cell the edge fn could
  --    not parse to a real date (D1/D3). Such items must NOT get the D2 90-day
  --    grace — an unknown/expired date can't be silently trusted.
  create temporary table _imp_match on commit drop as
  select r.email, r.phone, r.code, r.status, r.issue_date, r.expiry_date,
         coalesce(r.expiry_unparsed, false) as expiry_unparsed,
         r.number, r.evidence_note,
         coalesce(
           (select c.id from candidate.candidates c
             where r.email is not null and lower(c.email) = lower(r.email) limit 1),
           (select c.id from candidate.candidates c
             where r.phone is not null and c.phone = r.phone limit 1)
         ) as candidate_id
  from jsonb_to_recordset(p_rows) as r(
         email text, phone text, code text, status text,
         issue_date date, expiry_date date, expiry_unparsed boolean,
         number text, evidence_note text);

  select count(*), count(*) filter (where candidate_id is null),
         count(*) filter (where expiry_unparsed)
    into v_total, v_unmatched, v_unparsed
  from _imp_match;

  -- 2. Auto-assign sets for matched candidates (base best-match + all add-ons),
  --    each pinned to its latest active version.
  with cand as (
    select distinct candidate_id from _imp_match where candidate_id is not null
  ),
  resolved as (
    select r.candidate_id, r.set_id from (
      -- all add-ons
      select c.candidate_id, mp.set_id
      from cand c
      join candidate.candidates ca on ca.id = c.candidate_id
      join candidate.requirement_set_map mp
        on mp.active and mp.add_on and mp.discipline_id = ca.discipline_id
       and (mp.specialty_id is null or mp.specialty_id = ca.primary_specialty_id)
      union
      -- single best base
      select candidate_id, set_id from (
        select c.candidate_id, mp.set_id,
               row_number() over (partition by c.candidate_id
                 order by (mp.specialty_id is not null) desc, mp.priority desc) rn
        from cand c
        join candidate.candidates ca on ca.id = c.candidate_id
        join candidate.requirement_set_map mp
          on mp.active and not mp.add_on and mp.discipline_id = ca.discipline_id
         and (mp.specialty_id is null or mp.specialty_id = ca.primary_specialty_id)
      ) b where rn = 1
    ) r
  )
  insert into candidate.candidate_requirement_sets
    (candidate_id, set_id, set_code, set_version, active)
  select r.candidate_id, lv.id, lv.code, lv.version, true
  from resolved r
  join candidate.requirement_sets rs0 on rs0.id = r.set_id
  join lateral (
    select rs2.id, rs2.code, rs2.version
    from candidate.requirement_sets rs2
    where rs2.code = rs0.code and rs2.status = 'active'
    order by rs2.version desc limit 1
  ) lv on true
  on conflict (candidate_id, set_id) do nothing;

  -- 3. Set-based insert of migrated, verified items — only for codes that belong
  --    to the candidate's now-active set(s), so requirement scoping is exact.
  create temporary table _imp_ins on commit drop as
  with ins as (
    insert into candidate.compliance_items
      (candidate_id, requirement_id, status, channel, source_confidence,
       received_at, expires_at, needs_human, extracted, migrated)
    -- D7: two source rows for the same requirement collapse to ONE item; keep the
    -- best/newest deterministically (latest parsed expiry, then latest issue).
    select distinct on (i.candidate_id, rsi.requirement_id)
      i.candidate_id,
      rsi.requirement_id,
      'verified',
      'import',
      'migrated',
      v_migrated_at,
      -- D1/D3: an UNPARSEABLE expiry cell is landed as due-now (expires_at =
      -- migration_date) so the gate flags it red + needs re-verify immediately,
      -- rather than trusting an unknown date for the 90-day grace window.
      case when i.expiry_unparsed then v_migrated_at
           else candidate.compute_migrated_expiry(cr.expiry_rule, i.issue_date, i.expiry_date)
      end,
      i.expiry_unparsed,   -- needs_human: force a human to reconcile the bad date
      jsonb_strip_nulls(jsonb_build_object(
        'number', i.number, 'note', i.evidence_note, 'imported_status', i.status,
        'expiry_unparsed', nullif(i.expiry_unparsed, false))),
      true
    from _imp_match i
    join candidate.candidate_requirement_sets crs
      on crs.candidate_id = i.candidate_id and crs.active
    join candidate.requirement_set_items rsi on rsi.set_id = crs.set_id
    join candidate.compliance_requirements cr
      on cr.id = rsi.requirement_id and cr.code = i.code
    where i.candidate_id is not null
      and not exists (
        select 1 from candidate.compliance_items ci
        where ci.candidate_id = i.candidate_id
          and ci.requirement_id = rsi.requirement_id
          and ci.status = 'verified'
      )
    order by i.candidate_id, rsi.requirement_id,
             i.expiry_date desc nulls last, i.issue_date desc nulls last
    returning id, candidate_id, requirement_id
  )
  select * from ins;

  select count(*) into v_items from _imp_ins;

  -- D2: rows that matched a candidate but whose code is NOT in any of that
  -- candidate's active set items produce no item — count them so they don't
  -- vanish (distinct from unmatched-candidate rows).
  select count(*) into v_oos
  from _imp_match i
  where i.candidate_id is not null
    and not exists (
      select 1
      from candidate.candidate_requirement_sets crs
      join candidate.requirement_set_items rsi on rsi.set_id = crs.set_id
      join candidate.compliance_requirements cr on cr.id = rsi.requirement_id
      where crs.candidate_id = i.candidate_id and crs.active and cr.code = i.code
    );

  -- 4. One append-only provenance event per migrated item (D1).
  insert into candidate.verification_events
    (candidate_id, item_id, requirement_id, event_type, new_status,
     method, notes, actor_kind)
  select candidate_id, id, requirement_id, 'verified', 'verified',
         'import', 'bulk migration — provenance only', 'system'
  from _imp_ins;

  -- 5. One recompute per batch (covers matched-but-no-item candidates too).
  perform candidate.recompute_candidate_status_bulk(
    (select coalesce(array_agg(distinct candidate_id), '{}'::uuid[])
       from _imp_match where candidate_id is not null));

  perform set_config('candidate.bulk_load', 'off', true);

  v_result := jsonb_build_object(
    'rows',           v_total,
    'matched_rows',   v_total - v_unmatched,
    'unmatched_rows', v_unmatched,
    'candidates',     (select count(distinct candidate_id) from _imp_match
                        where candidate_id is not null),
    'items_inserted', v_items,
    'expiry_unparsed', v_unparsed,           -- D1/D3 data-quality signal
    'skipped_out_of_scope', v_oos,           -- D2 matched-but-not-in-set
    'unmatched_sample', (
      select coalesce(jsonb_agg(jsonb_build_object('email', email, 'phone', phone)), '[]'::jsonb)
      from (select distinct email, phone from _imp_match
             where candidate_id is null limit 50) s),
    'out_of_scope_sample', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'code', code, 'email', email, 'phone', phone)), '[]'::jsonb)
      from (
        select distinct i.code, i.email, i.phone
        from _imp_match i
        where i.candidate_id is not null
          and not exists (
            select 1
            from candidate.candidate_requirement_sets crs
            join candidate.requirement_set_items rsi on rsi.set_id = crs.set_id
            join candidate.compliance_requirements cr on cr.id = rsi.requirement_id
            where crs.candidate_id = i.candidate_id and crs.active and cr.code = i.code
          )
        limit 20) s)
  );
  return v_result;
end;
$$;
revoke all on function candidate.import_compliance_bulk(jsonb) from public;
grant execute on function candidate.import_compliance_bulk(jsonb) to service_role;
