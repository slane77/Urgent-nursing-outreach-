-- ============================================================================
--  Day Webster — Candidate Pipeline · Role-Scoped Compliance AI Chat (v1)
--  File: candidate-pipeline/sql/46_compliance_chat.sql
--  Run AFTER 34/36/41/42 (officer col + reporting views + ladder + breaches) and
--  45 (is_manager/is_compliance_officer). Idempotent / additive.
--  STATUS: DRAFT — NOT YET APPLIED.
--
--  See candidate-pipeline/COMPLIANCE_CHAT_DESIGN.md §2–3. The chat AI answers ONLY
--  from a fixed set of read-only, SCOPE-SAFE tools. The entire security model
--  rests on one property: the officer-id set a query filters on is computed
--  SERVER-SIDE from auth.uid() (chat_scope()), never from a model-supplied arg.
--
--  Scope (two tiers for chat — see 45):
--    · officer (is_compliance)             -> strictly their OWN candidates
--    · manager/admin (is_manager/is_admin) -> ALL candidates (all_access)
--  Unassigned candidates (compliance_officer is null) match no officer id, so
--  ONLY all_access callers ever see them.  [DECISION S3]
--
--  Why NEW thin wrappers instead of the existing reporting RPCs: the existing
--  compliance_officer_report / compliance_breach_report / compliance_dashboard
--  accept an ARBITRARY officer id and are gated only by is_compliance_officer() —
--  i.e. any officer can read the whole bench through them. They are leak vectors
--  and are NEVER called by the chat. These wrappers add a scope WHERE clause
--  derived from auth.uid() over the SAME underlying views (no new business logic).
--
--  Every RPC below: SECURITY DEFINER (runs as owner => RLS bypassed => it reads
--  the whole bench, then RE-APPLIES scope by hand) + the is_authorized_user() and
--  is_compliance_officer() gate + revoke-from-public + grant-to-authenticated.
-- ============================================================================

-- ── The scope resolver: no args, reads auth.uid() internally => unspoofable ───
-- all_access = manager/admin.  Otherwise officer_ids = {auth.uid()} (self only).
-- A model can NEVER influence this; it takes no parameters.
create or replace function candidate.chat_scope()
returns table(all_access boolean, officer_ids uuid[])
language sql stable security definer
set search_path = candidate, public as $$
  select
    candidate.is_manager(),
    case when candidate.is_manager() then null::uuid[]
         else array[auth.uid()] end;
$$;
revoke all on function candidate.chat_scope() from public;
grant execute on function candidate.chat_scope() to authenticated;

-- ── 1. chat_stats_in_scope(): pipeline RAG counts ───────────────────────────
create or replace function candidate.chat_stats_in_scope()
returns table(in_pipeline int, red int, amber int, green int)
language plpgsql stable security definer
set search_path = candidate, public as $$
declare v_all boolean; v_ids uuid[];
begin
  if not (candidate.is_authorized_user() and candidate.is_compliance_officer()) then
    raise exception 'not authorized';
  end if;
  select s.all_access, s.officer_ids into v_all, v_ids from candidate.chat_scope() s;

  return query
    select count(*)::int,
           count(*) filter (where os.overall_rag = 'red')::int,
           count(*) filter (where os.overall_rag = 'amber')::int,
           count(*) filter (where os.overall_rag = 'green')::int
    from candidate.candidate_overall_status os
    where (v_all or os.compliance_officer = any(v_ids));
end;
$$;
revoke all on function candidate.chat_stats_in_scope() from public;
grant execute on function candidate.chat_stats_in_scope() to authenticated;

-- ── 2. chat_urgent_in_scope(p_limit): the attention queue ────────────────────
-- Union of open breaches (rank 1), red/blocking incl. EXPIRED blocking items
-- (rank 2), and needs-human review (rank 3). p_limit clamped 1..50. Expired
-- blocking items surface as 'red' (recompute counts an expired verified doc as a
-- blocking gap), so there is no separate "expired" source to double-count.
create or replace function candidate.chat_urgent_in_scope(p_limit int default 25)
returns table(candidate_id uuid, candidate_name text, discipline text,
              reason text, severity text, detail text, rank int)
language plpgsql stable security definer
set search_path = candidate, public as $$
declare v_all boolean; v_ids uuid[]; v_limit int;
begin
  if not (candidate.is_authorized_user() and candidate.is_compliance_officer()) then
    raise exception 'not authorized';
  end if;
  select s.all_access, s.officer_ids into v_all, v_ids from candidate.chat_scope() s;
  v_limit := least(greatest(coalesce(p_limit, 25), 1), 50);

  return query
  with scoped_wl as (
    select w.candidate_id,
           (w.first_name || ' ' || w.last_name) as candidate_name,
           w.discipline_name,
           max(w.blocking_open)          as blocking_open,
           coalesce(sum(w.needs_human_count), 0) as needs_human,
           bool_or(w.status = 'red')     as any_red,
           min(w.next_expiry)            as next_expiry
    from candidate.compliance_worklist w
    where (v_all or w.compliance_officer = any(v_ids))
    group by w.candidate_id, candidate_name, w.discipline_name
  ),
  scoped_breach as (
    select b.candidate_id, b.candidate_name, b.discipline_name, count(*) as n
    from candidate.open_breaches b
    where (v_all or b.compliance_officer = any(v_ids))
    group by b.candidate_id, b.candidate_name, b.discipline_name
  ),
  urgent as (
    select b.candidate_id, b.candidate_name, b.discipline_name as discipline,
           'open_breach'::text as reason, 'critical'::text as severity,
           (b.n || ' open breach(es)')::text as detail, 1 as rnk,
           null::timestamptz as ord_expiry
    from scoped_breach b
    union all
    select w.candidate_id, w.candidate_name, w.discipline_name,
           'blocking', 'red',
           (coalesce(w.blocking_open, 0) || ' blocking item(s) unmet or expired'),
           2, w.next_expiry
    from scoped_wl w where w.any_red
    union all
    select w.candidate_id, w.candidate_name, w.discipline_name,
           'needs_human', 'amber',
           (w.needs_human || ' item(s) awaiting human review'),
           3, w.next_expiry
    from scoped_wl w where w.needs_human > 0 and not w.any_red
  )
  select u.candidate_id, u.candidate_name, u.discipline, u.reason, u.severity, u.detail, u.rnk
  from urgent u
  order by u.rnk, u.ord_expiry nulls last
  limit v_limit;
end;
$$;
revoke all on function candidate.chat_urgent_in_scope(int) from public;
grant execute on function candidate.chat_urgent_in_scope(int) to authenticated;

-- ── 3. chat_expiring_in_scope(p_days): documents expiring in a window ────────
-- The due_expiry_reminders "latest verified item per (candidate,requirement)"
-- pattern, restricted to a future window (p_days clamped 1..180) + officer scope.
create or replace function candidate.chat_expiring_in_scope(p_days int default 30)
returns table(candidate_id uuid, candidate_name text, requirement_code text,
              requirement_name text, expires_at timestamptz, days_left int)
language plpgsql stable security definer
set search_path = candidate, public as $$
declare v_all boolean; v_ids uuid[]; v_days int;
begin
  if not (candidate.is_authorized_user() and candidate.is_compliance_officer()) then
    raise exception 'not authorized';
  end if;
  select s.all_access, s.officer_ids into v_all, v_ids from candidate.chat_scope() s;
  v_days := least(greatest(coalesce(p_days, 30), 1), 180);

  return query
  with current_item as (
    select distinct on (ci.candidate_id, ci.requirement_id)
      ci.candidate_id, ci.requirement_id, ci.status, ci.expires_at,
      cr.code as requirement_code, cr.name as requirement_name
    from candidate.compliance_items ci
    join candidate.candidate_requirement_sets crs
      on crs.candidate_id = ci.candidate_id and crs.active
    join candidate.requirement_set_items rsi
      on rsi.set_id = crs.set_id and rsi.requirement_id = ci.requirement_id
    join candidate.compliance_requirements cr on cr.id = ci.requirement_id
    where coalesce(rsi.criticality, cr.criticality) in ('blocking','standard')
      and coalesce(rsi.required_override, cr.required)
    order by ci.candidate_id, ci.requirement_id,
             (ci.status = 'verified') desc, ci.updated_at desc
  )
  select c.id,
         (c.first_name || ' ' || c.last_name),
         ci.requirement_code, ci.requirement_name, ci.expires_at,
         greatest(0, ceil(extract(epoch from (ci.expires_at - now())) / 86400.0))::int
  from current_item ci
  join candidate.candidates c on c.id = ci.candidate_id
  where ci.status = 'verified'
    and ci.expires_at is not null
    and ci.expires_at > now()
    and ci.expires_at <= now() + make_interval(days => v_days)
    and (v_all or c.compliance_officer = any(v_ids))
  order by ci.expires_at
  limit 200;
end;
$$;
revoke all on function candidate.chat_expiring_in_scope(int) from public;
grant execute on function candidate.chat_expiring_in_scope(int) to authenticated;

-- ── 4. chat_breach_summary_in_scope(): the breach headline ───────────────────
create or replace function candidate.chat_breach_summary_in_scope()
returns table(open_breaches int, candidates_working_noncompliant int)
language plpgsql stable security definer
set search_path = candidate, public as $$
declare v_all boolean; v_ids uuid[];
begin
  if not (candidate.is_authorized_user() and candidate.is_compliance_officer()) then
    raise exception 'not authorized';
  end if;
  select s.all_access, s.officer_ids into v_all, v_ids from candidate.chat_scope() s;

  return query
    select count(*)::int,
           count(distinct b.candidate_id)
             filter (where b.shift_date >= current_date)::int
    from candidate.open_breaches b
    where (v_all or b.compliance_officer = any(v_ids));
end;
$$;
revoke all on function candidate.chat_breach_summary_in_scope() from public;
grant execute on function candidate.chat_breach_summary_in_scope() to authenticated;

-- ── 5. chat_workready_in_scope(): both senses, so "work-ready" is unambiguous ─
-- fully_compliant = green only (per compliance_exec_overview's "green = ready");
-- placeable       = green+amber (matches the booking gate is_work_ready(), which
--                   treats amber as placeable-with-caveat / bookable);
-- not_ready       = red (blocked, not bookable).
create or replace function candidate.chat_workready_in_scope()
returns table(fully_compliant int, placeable int, not_ready int)
language plpgsql stable security definer
set search_path = candidate, public as $$
declare v_all boolean; v_ids uuid[];
begin
  if not (candidate.is_authorized_user() and candidate.is_compliance_officer()) then
    raise exception 'not authorized';
  end if;
  select s.all_access, s.officer_ids into v_all, v_ids from candidate.chat_scope() s;

  return query
    select count(*) filter (where os.overall_rag = 'green')::int,
           count(*) filter (where os.overall_rag in ('green','amber'))::int,
           count(*) filter (where os.overall_rag = 'red')::int
    from candidate.candidate_overall_status os
    where (v_all or os.compliance_officer = any(v_ids));
end;
$$;
revoke all on function candidate.chat_workready_in_scope() from public;
grant execute on function candidate.chat_workready_in_scope() to authenticated;

-- ── 6. chat_candidate_lookup_in_scope(p_query): 0-or-1 row, no existence leak ─
-- Out-of-scope OR unknown => ZERO rows, identically (the scope WHERE clause makes
-- an out-of-scope candidate indistinguishable from a non-existent one). An empty
-- query also returns nothing.
create or replace function candidate.chat_candidate_lookup_in_scope(p_query text)
returns table(candidate_id uuid, candidate_name text, discipline text,
              overall_rag text, active_sets int, open_breaches int,
              next_expiry timestamptz)
language plpgsql stable security definer
set search_path = candidate, public as $$
declare v_all boolean; v_ids uuid[]; v_q text;
begin
  if not (candidate.is_authorized_user() and candidate.is_compliance_officer()) then
    raise exception 'not authorized';
  end if;
  v_q := btrim(coalesce(p_query, ''));
  if v_q = '' then
    return;                                   -- empty query => zero rows
  end if;
  select s.all_access, s.officer_ids into v_all, v_ids from candidate.chat_scope() s;

  return query
    select os.candidate_id,
           (c.first_name || ' ' || c.last_name),
           d.name,
           os.overall_rag,
           os.active_set_count::int,
           (select count(*)::int from candidate.open_breaches b
             where b.candidate_id = os.candidate_id),
           (select min(st.next_expiry) from candidate.candidate_compliance_status st
             where st.candidate_id = os.candidate_id)
    from candidate.candidate_overall_status os
    join candidate.candidates c on c.id = os.candidate_id
    left join candidate.disciplines d on d.id = os.discipline_id
    where (v_all or os.compliance_officer = any(v_ids))
      and ((c.first_name || ' ' || c.last_name) ilike '%' || v_q || '%'
           or c.email ilike '%' || v_q || '%')
    order by (lower(c.first_name || ' ' || c.last_name) = lower(v_q)) desc,
             c.last_name, c.first_name
    limit 1;
end;
$$;
revoke all on function candidate.chat_candidate_lookup_in_scope(text) from public;
grant execute on function candidate.chat_candidate_lookup_in_scope(text) to authenticated;

-- ── 7. chat_officer_breakdown_in_scope(p_division): per-officer RAG — managers ─
-- MANAGER-ONLY (raises for a plain officer). Officer names are STAFF data, not
-- candidate PII, so this is allowed even in aggregate PII mode. p_division only
-- NARROWS within the already-full-bench manager scope; it can never widen.
create or replace function candidate.chat_officer_breakdown_in_scope(p_division uuid default null)
returns table(officer uuid, officer_name text, red int, amber int, green int)
language plpgsql stable security definer
set search_path = candidate, public as $$
declare v_all boolean; v_ids uuid[];
begin
  if not (candidate.is_authorized_user() and candidate.is_compliance_officer()) then
    raise exception 'not authorized';
  end if;
  if not candidate.is_manager() then
    raise exception 'not authorized: officer breakdown is manager-only';
  end if;
  select s.all_access, s.officer_ids into v_all, v_ids from candidate.chat_scope() s;

  return query
    select os.compliance_officer,
           coalesce(st.full_name, au.email, os.compliance_officer::text),
           count(*) filter (where os.overall_rag = 'red')::int,
           count(*) filter (where os.overall_rag = 'amber')::int,
           count(*) filter (where os.overall_rag = 'green')::int
    from candidate.candidate_overall_status os
    left join candidate.staff     st on st.user_id = os.compliance_officer
    left join candidate.app_users au on au.user_id = os.compliance_officer
    where (v_all or os.compliance_officer = any(v_ids))
      and (p_division is null or os.division_id = p_division)
    group by os.compliance_officer,
             coalesce(st.full_name, au.email, os.compliance_officer::text);
end;
$$;
revoke all on function candidate.chat_officer_breakdown_in_scope(uuid) from public;
grant execute on function candidate.chat_officer_breakdown_in_scope(uuid) to authenticated;

-- ============================================================================
--  Audit — every question is logged (append-only). The log stores tool NAMES +
--  INPUTS + ROW-COUNTS only, never candidate rows, so it is not a second copy of
--  confidential data.
-- ============================================================================
create table if not exists candidate.compliance_chat_log (
  id            uuid primary key default gen_random_uuid(),
  actor         uuid references auth.users(id) on delete set null,
  actor_email   text,
  role_scope    text not null,                         -- 'officer' | 'manager' | 'admin'
  pii_mode      text not null,                         -- 'identifying' | 'aggregate'
  question      text not null,
  tools_called  jsonb not null default '[]',           -- [{name, input, row_count}] — NO rows
  answer        text,
  input_tokens  int,
  output_tokens int,
  model         text,
  created_at    timestamptz not null default now()
);
create index if not exists compliance_chat_log_actor_idx
  on candidate.compliance_chat_log (actor, created_at desc);

-- ── RLS: officer reads OWN rows; manager/admin reads all; no client write ────
alter table candidate.compliance_chat_log enable row level security;
drop policy if exists "chat_log read own or manager" on candidate.compliance_chat_log;
create policy "chat_log read own or manager" on candidate.compliance_chat_log
  for select to authenticated
  using (candidate.is_authorized_user()
         and (actor = auth.uid() or candidate.is_manager()));
-- No INSERT/UPDATE/DELETE policy: append-only; the SECURITY DEFINER writer below
-- (owned by the schema owner => RLS-exempt) is the SOLE writer. No write grant.
grant select on candidate.compliance_chat_log to authenticated;

-- ── log_compliance_chat(): the sole writer ───────────────────────────────────
create or replace function candidate.log_compliance_chat(
    p_role_scope    text,
    p_pii_mode      text,
    p_question      text,
    p_tools_called  jsonb default '[]',
    p_answer        text default null,
    p_input_tokens  int  default null,
    p_output_tokens int  default null,
    p_model         text default null)
returns uuid language plpgsql security definer
set search_path = candidate, public as $$
declare v_id uuid;
begin
  if not (candidate.is_authorized_user() and candidate.is_compliance_officer()) then
    raise exception 'not authorized';
  end if;

  insert into candidate.compliance_chat_log
    (actor, actor_email, role_scope, pii_mode, question, tools_called,
     answer, input_tokens, output_tokens, model)
  values
    (auth.uid(), lower(auth.jwt() ->> 'email'), p_role_scope, p_pii_mode, p_question,
     coalesce(p_tools_called, '[]'::jsonb), p_answer, p_input_tokens, p_output_tokens, p_model)
  returning id into v_id;

  return v_id;
end;
$$;
revoke all on function candidate.log_compliance_chat(text, text, text, jsonb, text, int, int, text) from public;
grant execute on function candidate.log_compliance_chat(text, text, text, jsonb, text, int, int, text) to authenticated;
