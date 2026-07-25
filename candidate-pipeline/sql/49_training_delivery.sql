-- ============================================================================
--  Day Webster — Candidate Pipeline · Mandatory Training: delivery + assessment
--  File: candidate-pipeline/sql/49_training_delivery.sql
--  Run AFTER 48 (and before/with 50 — submit_training_attempt calls
--  issue_training_record at runtime).  Idempotent / additive.
--  STATUS: DRAFT — NOT YET APPLIED.
--
--  Passwordless magic-link delivery (no candidate account) + the integrity-first
--  assessment core. Mirrors the function-as-trust-boundary model: the candidate
--  holds only an opaque, hashed, single-use, short-TTL token and talks solely to
--  SECURITY DEFINER RPCs; the tables are default-deny to non-staff.
--
--  THE ASSESSMENT INVARIANT: the correct-answer key NEVER reaches the browser and
--  grading happens server-side. start_training_attempt serves questions with
--  correct_keys + explanation stripped; submit_training_attempt fetches the keys
--  itself and grades. No RPC in this file ever returns correct_keys.
--
--  In Round 2 the `training-portal` edge function (service role) calls these,
--  hashing the raw magic-link/session tokens before they reach the DB. Round 1
--  keeps the same gates so a compliance officer can also drive them in tests.
-- ============================================================================

-- ── training_assignments: a candidate owes a module at a pinned version ──────
create table if not exists candidate.training_assignments (
  id                uuid primary key default gen_random_uuid(),
  candidate_id      uuid not null references candidate.candidates(id) on delete cascade,
  module_id         uuid not null references candidate.training_modules(id) on delete restrict,
  module_version_id uuid not null references candidate.module_versions(id) on delete restrict,
  status            text not null default 'assigned'
                    check (status in ('assigned','in_progress','passed','failed','expired','cancelled')),
  assigned_by       uuid references auth.users(id) on delete set null,
  assigned_at       timestamptz not null default now(),
  completed_at      timestamptz,
  unique (candidate_id, module_id, module_version_id)
);
create index if not exists training_assignments_candidate_idx on candidate.training_assignments (candidate_id);

-- ── training_magic_links: hashed, short-TTL, single-use ──────────────────────
create table if not exists candidate.training_magic_links (
  token_hash    text primary key,               -- sha256(raw); raw emailed, NEVER stored
  assignment_id uuid not null references candidate.training_assignments(id) on delete cascade,
  candidate_id  uuid not null references candidate.candidates(id) on delete cascade,
  expires_at    timestamptz not null,
  consumed_at   timestamptz,
  created_at    timestamptz not null default now()
);

-- ── training_sessions: short-lived post-consume session (~60 min) ────────────
create table if not exists candidate.training_sessions (
  token_hash    text primary key,
  assignment_id uuid not null references candidate.training_assignments(id) on delete cascade,
  candidate_id  uuid not null references candidate.candidates(id) on delete cascade,
  expires_at    timestamptz not null,
  created_at    timestamptz not null default now()
);

-- ── training_attempts: one row per assessment attempt (audit trail) ──────────
create table if not exists candidate.training_attempts (
  id                  uuid primary key default gen_random_uuid(),
  assignment_id       uuid not null references candidate.training_assignments(id) on delete cascade,
  candidate_id        uuid not null references candidate.candidates(id) on delete cascade,
  module_version_id   uuid not null references candidate.module_versions(id) on delete restrict,
  served_question_ids jsonb not null,            -- exact set + order served (integrity)
  answers             jsonb,
  score               numeric,                   -- % computed server-side
  passed              boolean,
  started_at          timestamptz not null default now(),
  submitted_at        timestamptz
);
create index if not exists training_attempts_assignment_idx on candidate.training_attempts (assignment_id);

-- ── assign_training: create assignment + magic link, return RAW token ONCE ───
-- Officer/service gated. Pins the module's CURRENT PUBLISHED version (raises if
-- there is none). Stores only sha256(token); returns the raw token to the caller
-- (who emails it). Re-assigning the same candidate+module+version reuses the
-- assignment and issues a fresh link.
create or replace function candidate.assign_training(
    p_candidate_id uuid,
    p_module_id    uuid,
    p_ttl          interval default interval '7 days')
returns text language plpgsql security definer
set search_path = candidate, public as $$
declare
  v_version uuid; v_assignment uuid; v_raw text; v_hash text;
begin
  if not (candidate.is_compliance_officer() or candidate.is_service_role()) then
    raise exception 'not authorized';
  end if;

  select current_version_id into v_version from candidate.training_modules where id = p_module_id;
  if v_version is null then
    raise exception 'module % has no published version — cannot assign', p_module_id;
  end if;

  insert into candidate.training_assignments
    (candidate_id, module_id, module_version_id, status, assigned_by)
  values (p_candidate_id, p_module_id, v_version, 'assigned', auth.uid())
  on conflict (candidate_id, module_id, module_version_id)
  do update set status = case when candidate.training_assignments.status in ('passed')
                             then candidate.training_assignments.status else 'assigned' end
  returning id into v_assignment;

  v_raw  := encode(gen_random_bytes(32), 'hex');
  v_hash := encode(digest(v_raw, 'sha256'), 'hex');
  insert into candidate.training_magic_links (token_hash, assignment_id, candidate_id, expires_at)
  values (v_hash, v_assignment, p_candidate_id, now() + coalesce(p_ttl, interval '7 days'));

  return v_raw;
end $$;
revoke all on function candidate.assign_training(uuid, uuid, interval) from public;
grant execute on function candidate.assign_training(uuid, uuid, interval) to authenticated, service_role;

-- ── consume_training_link: single-use link -> session + KB content ───────────
-- p_token_hash = sha256(raw) (the edge function hashes the raw token before the
-- call). Validates unconsumed + unexpired, marks it consumed (single-use), mints
-- a session, flips the assignment to in_progress, and returns the KB content.
-- Generic error on any failure (no enumeration).
create or replace function candidate.consume_training_link(p_token_hash text)
returns jsonb language plpgsql security definer
set search_path = candidate, public as $$
declare
  v_assignment uuid; v_candidate uuid; v_version uuid; v_session text;
  v_module record;
begin
  if not (candidate.is_service_role() or candidate.is_compliance_officer()) then
    raise exception 'not authorized';
  end if;

  -- Atomic single-use consume (race-safe): only the first caller wins the row.
  update candidate.training_magic_links
    set consumed_at = now()
  where token_hash = p_token_hash and consumed_at is null and expires_at > now()
  returning assignment_id, candidate_id into v_assignment, v_candidate;
  if v_assignment is null then
    raise exception 'invalid or expired link';
  end if;

  select module_version_id into v_version from candidate.training_assignments where id = v_assignment;

  update candidate.training_assignments
    set status = 'in_progress'
  where id = v_assignment and status in ('assigned','failed');

  v_session := encode(gen_random_bytes(32), 'hex');
  insert into candidate.training_sessions (token_hash, assignment_id, candidate_id, expires_at)
  values (v_session, v_assignment, v_candidate, now() + interval '60 minutes');

  select tm.id, tm.code, tm.title, tm.framework, tm.framework_subject,
         tm.question_count, tm.pass_threshold, mv.content
    into v_module
  from candidate.module_versions mv
  join candidate.training_modules tm on tm.id = mv.module_id
  where mv.id = v_version;

  return jsonb_build_object(
    'session_hash', v_session,
    'assignment_id', v_assignment,
    'module', jsonb_build_object(
        'code', v_module.code, 'title', v_module.title,
        'framework', v_module.framework, 'framework_subject', v_module.framework_subject,
        'question_count', v_module.question_count, 'pass_threshold', v_module.pass_threshold),
    'content', v_module.content);
end $$;
revoke all on function candidate.consume_training_link(text) from public;
grant execute on function candidate.consume_training_link(text) to authenticated, service_role;

-- ── start_training_attempt: THE INTEGRITY CORE ───────────────────────────────
-- Validates the session, randomly selects N=question_count questions from the
-- PINNED version, records an attempt storing the exact served ids, and returns
-- the questions WITH correct_keys + explanation STRIPPED. This RPC must never
-- return an answer key.
create or replace function candidate.start_training_attempt(p_session_hash text)
returns jsonb language plpgsql security definer
set search_path = candidate, public as $$
declare
  v_assignment uuid; v_candidate uuid; v_version uuid; v_n int;
  v_ids jsonb; v_attempt uuid; v_questions jsonb;
begin
  if not (candidate.is_service_role() or candidate.is_compliance_officer()) then
    raise exception 'not authorized';
  end if;

  select assignment_id, candidate_id into v_assignment, v_candidate
  from candidate.training_sessions
  where token_hash = p_session_hash and expires_at > now();
  if v_assignment is null then
    raise exception 'invalid or expired session';
  end if;

  select ta.module_version_id, tm.question_count
    into v_version, v_n
  from candidate.training_assignments ta
  join candidate.training_modules tm on tm.id = ta.module_id
  where ta.id = v_assignment;

  -- Random N-of-bank selection (re-randomised on every attempt / retake).
  with picked as (
    select id, stem, options, row_number() over () as rn
    from (
      select id, stem, options
      from candidate.training_questions
      where module_version_id = v_version
      order by random()
      limit v_n
    ) q
  )
  select jsonb_agg(id order by rn),
         jsonb_agg(jsonb_build_object('id', id, 'stem', stem, 'options', options) order by rn)
    into v_ids, v_questions
  from picked;

  if v_ids is null or jsonb_array_length(v_ids) < v_n then
    raise exception 'module version % has too few questions to serve an attempt', v_version;
  end if;

  insert into candidate.training_attempts
    (assignment_id, candidate_id, module_version_id, served_question_ids)
  values (v_assignment, v_candidate, v_version, v_ids)
  returning id into v_attempt;

  -- NOTE: v_questions was built from id/stem/options ONLY — no correct_keys,
  -- no explanation. This is the object the browser receives.
  return jsonb_build_object('attempt_id', v_attempt, 'questions', v_questions);
end $$;
revoke all on function candidate.start_training_attempt(text) from public;
grant execute on function candidate.start_training_attempt(text) to authenticated, service_role;

-- ── submit_training_attempt: server-side grading ─────────────────────────────
-- Fetches the served questions' correct_keys INSIDE the function; a question is
-- correct iff the submitted key set == the correct_keys set. Computes score %,
-- passed = score >= module.pass_threshold. On pass issues the training record
-- (+cert +compliance hook, 50); on fail marks the assignment failed (retake
-- allowed, re-randomised next start). Never returns correct_keys.
-- p_answers shape: { "<question_id>": ["a","c"], ... }
create or replace function candidate.submit_training_attempt(
    p_session_hash text,
    p_attempt_id   uuid,
    p_answers      jsonb)
returns jsonb language plpgsql security definer
set search_path = candidate, public as $$
declare
  v_assignment uuid; v_candidate uuid; v_version uuid; v_module uuid;
  v_threshold numeric; v_ids jsonb; v_n int; v_correct int := 0;
  v_qid text; v_score numeric; v_passed boolean; v_cert text; v_rec uuid;
begin
  if not (candidate.is_service_role() or candidate.is_compliance_officer()) then
    raise exception 'not authorized';
  end if;

  select assignment_id, candidate_id into v_assignment, v_candidate
  from candidate.training_sessions
  where token_hash = p_session_hash and expires_at > now();
  if v_assignment is null then
    raise exception 'invalid or expired session';
  end if;

  select served_question_ids into v_ids
  from candidate.training_attempts
  where id = p_attempt_id and assignment_id = v_assignment
    and candidate_id = v_candidate and submitted_at is null;
  if v_ids is null then
    raise exception 'invalid or already-submitted attempt';
  end if;

  select ta.module_version_id, ta.module_id into v_version, v_module
  from candidate.training_assignments ta where ta.id = v_assignment;
  select pass_threshold into v_threshold from candidate.training_modules where id = v_module;

  v_n := jsonb_array_length(v_ids);

  -- Grade each SERVED question against its server-side correct_keys (set equality).
  for v_qid in select jsonb_array_elements_text(v_ids) loop
    if exists (
      select 1 from candidate.training_questions q
      where q.id = v_qid::uuid
        and (select array_agg(x order by x)
               from jsonb_array_elements_text(q.correct_keys) x)
          = (select array_agg(x order by x)
               from jsonb_array_elements_text(coalesce(p_answers->v_qid, '[]'::jsonb)) x)
    ) then
      v_correct := v_correct + 1;
    end if;
  end loop;

  v_score  := round((v_correct::numeric / greatest(v_n, 1)) * 100, 2);
  v_passed := v_score >= v_threshold;

  update candidate.training_attempts
    set answers = p_answers, score = v_score, passed = v_passed, submitted_at = now()
  where id = p_attempt_id;

  if v_passed then
    -- issue_training_record (50) writes the record + cert + compliance hook.
    select cert_id, rec_id into v_cert, v_rec
    from candidate.issue_training_record(
           v_candidate, v_module, 'assessment', v_score, current_date,
           p_attempt_id, null, null);
    update candidate.training_assignments
      set status = 'passed', completed_at = now() where id = v_assignment;
  else
    update candidate.training_assignments
      set status = 'failed' where id = v_assignment;
  end if;

  return jsonb_build_object('passed', v_passed, 'score', v_score,
    'certificate_id', v_cert);   -- correct_keys are NEVER included
end $$;
revoke all on function candidate.submit_training_attempt(text, uuid, jsonb) from public;
grant execute on function candidate.submit_training_attempt(text, uuid, jsonb) to authenticated, service_role;

-- ── RLS ──────────────────────────────────────────────────────────────────────
alter table candidate.training_assignments enable row level security;
alter table candidate.training_magic_links enable row level security;   -- no policy: service only
alter table candidate.training_sessions    enable row level security;   -- no policy: service only
alter table candidate.training_attempts    enable row level security;

-- assignments: authorised staff READ + officer INSERT; status transitions via
-- RPC only (no UPDATE policy); managers may DELETE.
drop policy if exists "auth read training_assignments"     on candidate.training_assignments;
drop policy if exists "officer insert training_assignments" on candidate.training_assignments;
drop policy if exists "manager delete training_assignments" on candidate.training_assignments;
create policy "auth read training_assignments" on candidate.training_assignments
  for select to authenticated using (candidate.is_authorized_user());
create policy "officer insert training_assignments" on candidate.training_assignments
  for insert to authenticated
  with check (candidate.is_authorized_user() and candidate.is_compliance_officer());
create policy "manager delete training_assignments" on candidate.training_assignments
  for delete to authenticated
  using (candidate.is_authorized_user() and candidate.is_manager());

-- attempts: authorised staff READ; no client write (RPC only) => un-forgeable.
drop policy if exists "auth read training_attempts" on candidate.training_attempts;
create policy "auth read training_attempts" on candidate.training_attempts
  for select to authenticated using (candidate.is_authorized_user());

-- Table privileges. magic_links/sessions get NONE (service-only). Assignment
-- status transitions + attempt writes are RPC-only, so no update/insert grant on
-- attempts; assignments allow officer INSERT + manager DELETE per policy.
grant select, insert, delete on candidate.training_assignments to authenticated;
grant select on candidate.training_attempts to authenticated;
