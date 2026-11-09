-- ============================================================================
--  Day Webster — Candidate Pipeline · Mandatory Training: versioned content
--  File: candidate-pipeline/sql/48_training_versions.sql
--  Run AFTER 47.  Idempotent / additive.  STATUS: DRAFT — NOT YET APPLIED.
--
--  Accreditation-bearing content, so: AI may DRAFT but a HUMAN approval gate is
--  mandatory before publish, and a published version is IMMUTABLE and versioned
--  (a training record freezes the module_version it was assessed against).
--
--  Role gates (confirmed): author/draft/edit-draft = is_compliance_officer();
--  approve + publish = is_manager() (managers/admins — the accreditation gate).
--
--  Every workflow transition appends an attributable verification_events row.
--  Those rows are CATALOGUE-level (no candidate), so candidate_id is made
--  nullable below; the event_type CHECK is widened to add the training verbs,
--  keeping the FULL prior superset (checklist_sent/override_*/breach_* etc).
-- ============================================================================

-- ── Allow catalogue-level (candidate-less) audit rows on the spine ───────────
-- Training publish/approve/submit are catalogue events, not candidate events, so
-- the append-only audit spine must accept a NULL candidate_id. Widening only
-- (existing candidate-scoped inserts are unaffected). Idempotent.
alter table candidate.verification_events alter column candidate_id drop not null;

-- ── Widen the event_type CHECK: add training verbs, keep the full superset ────
-- Drop-then-add keeps this idempotent; the list is a strict SUPERSET of sql/44's
-- (every prior verb retained) so no existing row is ever invalidated.
alter table candidate.verification_events
  drop constraint if exists verification_events_event_type_check;
alter table candidate.verification_events
  add constraint verification_events_event_type_check
  check (event_type in ('verified','rejected','unsuitable','expired','waived',
         'reinstated','evidence_received','recheck_requested','status_recomputed',
         'override_granted','override_revoked',
         'breach_logged','breach_acknowledged','breach_resolved',
         'checklist_sent',
         'training_submitted','training_approved','training_published'));

-- ── Widen the method CHECK: add 'assessment' (a pass through the LMS engine) ──
-- Keeps the full prior superset; drop-then-add is idempotent. issue_training_record
-- (50) stamps method='assessment' for an assessed pass, 'human' for a manual entry.
alter table candidate.verification_events
  drop constraint if exists verification_events_method_check;
alter table candidate.verification_events
  add constraint verification_events_method_check
  check (method in ('human','idvt','rtw','dbs_update','register_check',
         'ocr','import','system','assessment'));

-- ── module_versions: versioned KB content + workflow status ──────────────────
create table if not exists candidate.module_versions (
  id            uuid primary key default gen_random_uuid(),
  module_id     uuid not null references candidate.training_modules(id) on delete cascade,
  version       int  not null,
  status        text not null default 'draft'
                check (status in ('draft','in_review','approved','published','retired')),
  content       jsonb not null default '{}'::jsonb,   -- KB: [{heading, body_md}, ...]
  ai_generated  boolean not null default false,
  ai_model      text,
  authored_by   uuid references auth.users(id) on delete set null,
  reviewed_by   uuid references auth.users(id) on delete set null,
  approved_by   uuid references auth.users(id) on delete set null,  -- the human approval-gate signer (manager)
  approved_at   timestamptz,
  published_at  timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (module_id, version)
);
create index if not exists module_versions_module_idx on candidate.module_versions (module_id, status);

drop trigger if exists module_versions_set_updated_at on candidate.module_versions;
create trigger module_versions_set_updated_at
  before update on candidate.module_versions
  for each row execute function candidate.set_updated_at();

-- ── training_questions: the per-version MCQ bank (answer keys server-side) ────
create table if not exists candidate.training_questions (
  id                uuid primary key default gen_random_uuid(),
  module_version_id uuid not null references candidate.module_versions(id) on delete cascade,
  stem              text not null,
  options           jsonb not null,        -- [{key:'a', text:'...'}, ...]
  correct_keys      jsonb not null,        -- ['a'] or ['a','c'] — NEVER served to candidates
  explanation       text,
  sort_order        int not null default 100,
  created_at        timestamptz not null default now()
);
create index if not exists training_questions_version_idx on candidate.training_questions (module_version_id, sort_order);

-- ── current_version_id FK (now that module_versions exists) ──────────────────
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'training_modules_current_version_fk') then
    alter table candidate.training_modules
      add constraint training_modules_current_version_fk
      foreign key (current_version_id) references candidate.module_versions(id) on delete set null;
  end if;
end $$;

-- ── Immutability trigger: a PUBLISHED version is frozen ──────────────────────
-- Once status='published', content cannot mutate and status can only move
-- forward to 'retired' (on republish of a successor). Editing a published module
-- means a NEW module_versions row (version+1, draft), never an in-place edit.
create or replace function candidate.trg_module_version_immutable()
returns trigger language plpgsql
set search_path = candidate, public as $$
declare
  v_order  jsonb := '{"draft":0,"in_review":1,"approved":2,"published":3,"retired":4}'::jsonb;
begin
  -- A version is immutable once it has been published OR retired: content is
  -- frozen and status can only move forward (published -> retired is allowed;
  -- retired is terminal, so every move from it is backward and rejected).
  if old.status in ('published','retired') then
    if new.content is distinct from old.content then
      raise exception 'module version % is immutable (content cannot change once %)', old.id, old.status;
    end if;
    if (v_order->>new.status)::int < (v_order->>old.status)::int then
      raise exception 'module version % cannot move backward from % to %', old.id, old.status, new.status;
    end if;
  end if;
  return new;
end $$;

drop trigger if exists module_versions_immutable on candidate.module_versions;
create trigger module_versions_immutable
  before update on candidate.module_versions
  for each row execute function candidate.trg_module_version_immutable();

-- Questions of a published version are immutable too (no insert/update/delete).
create or replace function candidate.trg_training_question_immutable()
returns trigger language plpgsql
set search_path = candidate, public as $$
declare v_status text;
begin
  select status into v_status from candidate.module_versions
   where id = coalesce(new.module_version_id, old.module_version_id);
  if v_status = 'published' then
    raise exception 'questions of a published module version are immutable';
  end if;
  return coalesce(new, old);
end $$;

drop trigger if exists training_questions_immutable on candidate.training_questions;
create trigger training_questions_immutable
  before insert or update or delete on candidate.training_questions
  for each row execute function candidate.trg_training_question_immutable();

-- ── Internal helper: append a catalogue-level workflow audit row ─────────────
create or replace function candidate.trg_training_version_event(
    p_version_id uuid, p_event_type text, p_notes text)
returns void language plpgsql security definer
set search_path = candidate, public as $$
declare v_req uuid; v_code text; v_ver int;
begin
  select cr.id, tm.code, mv.version
    into v_req, v_code, v_ver
  from candidate.module_versions mv
  join candidate.training_modules tm on tm.id = mv.module_id
  left join candidate.compliance_requirements cr
    on cr.code = tm.requirement_code and cr.discipline_id is null and cr.specialty_id is null
  where mv.id = p_version_id;

  insert into candidate.verification_events
    (candidate_id, requirement_id, event_type, method, source_ref, notes, actor, actor_kind)
  values
    (null, v_req, p_event_type, 'human',
     format('%s v%s', v_code, v_ver), p_notes, auth.uid(), 'human');
end $$;
revoke all on function candidate.trg_training_version_event(uuid, text, text) from public;

-- ── save_module_version: create/update a DRAFT (officer) ─────────────────────
-- p_version_id null => create the next draft version for the module. Otherwise
-- overwrite an existing DRAFT's content. Draft/in_review content is freely
-- editable; published content is frozen by the immutability trigger.
create or replace function candidate.save_module_version(
    p_module_id    uuid,
    p_content      jsonb,
    p_version_id   uuid    default null,
    p_ai_generated boolean default false,
    p_ai_model     text    default null)
returns uuid language plpgsql security definer
set search_path = candidate, public as $$
declare v_id uuid; v_status text; v_next int;
begin
  if not candidate.is_compliance_officer() then
    raise exception 'not authorized';
  end if;

  if p_version_id is null then
    select coalesce(max(version), 0) + 1 into v_next
      from candidate.module_versions where module_id = p_module_id;
    insert into candidate.module_versions
      (module_id, version, status, content, ai_generated, ai_model, authored_by)
    values (p_module_id, v_next, 'draft', coalesce(p_content, '{}'::jsonb),
            p_ai_generated, p_ai_model, auth.uid())
    returning id into v_id;
    return v_id;
  end if;

  select status into v_status from candidate.module_versions where id = p_version_id;
  if not found then raise exception 'module version % not found', p_version_id; end if;
  if v_status <> 'draft' then
    raise exception 'only a draft version can be edited (version is %)', v_status;
  end if;
  update candidate.module_versions
    set content = coalesce(p_content, content),
        ai_generated = p_ai_generated, ai_model = p_ai_model, updated_at = now()
  where id = p_version_id;
  return p_version_id;
end $$;
revoke all on function candidate.save_module_version(uuid, jsonb, uuid, boolean, text) from public;
grant execute on function candidate.save_module_version(uuid, jsonb, uuid, boolean, text) to authenticated, service_role;

-- ── add_training_question: append an MCQ to a DRAFT version (officer) ────────
-- Questions are edited THROUGH this RPC (the table has no direct write policy),
-- so a staff-token leak can neither dump nor forge the answer bank.
create or replace function candidate.add_training_question(
    p_version_id   uuid,
    p_stem         text,
    p_options      jsonb,
    p_correct_keys jsonb,
    p_explanation  text default null,
    p_sort_order   int  default 100)
returns uuid language plpgsql security definer
set search_path = candidate, public as $$
declare v_status text; v_id uuid;
begin
  if not candidate.is_compliance_officer() then
    raise exception 'not authorized';
  end if;
  select status into v_status from candidate.module_versions where id = p_version_id;
  if not found then raise exception 'module version % not found', p_version_id; end if;
  if v_status not in ('draft','in_review') then
    raise exception 'questions can only be edited on a draft/in_review version (is %)', v_status;
  end if;
  if jsonb_typeof(p_correct_keys) <> 'array' or jsonb_array_length(p_correct_keys) = 0 then
    raise exception 'correct_keys must be a non-empty array';
  end if;
  insert into candidate.training_questions
    (module_version_id, stem, options, correct_keys, explanation, sort_order)
  values (p_version_id, p_stem, p_options, p_correct_keys, p_explanation, p_sort_order)
  returning id into v_id;
  return v_id;
end $$;
revoke all on function candidate.add_training_question(uuid, text, jsonb, jsonb, text, int) from public;
grant execute on function candidate.add_training_question(uuid, text, jsonb, jsonb, text, int) to authenticated, service_role;

-- ── submit_module_for_review: draft -> in_review (officer) ───────────────────
create or replace function candidate.submit_module_for_review(p_version_id uuid)
returns void language plpgsql security definer
set search_path = candidate, public as $$
declare v_status text;
begin
  if not candidate.is_compliance_officer() then
    raise exception 'not authorized';
  end if;
  select status into v_status from candidate.module_versions where id = p_version_id;
  if not found then raise exception 'module version % not found', p_version_id; end if;
  if v_status <> 'draft' then
    raise exception 'only a draft can be submitted for review (is %)', v_status;
  end if;
  update candidate.module_versions
    set status = 'in_review', reviewed_by = auth.uid(), updated_at = now()
  where id = p_version_id;
  perform candidate.trg_training_version_event(p_version_id, 'training_submitted',
    'module version submitted for review');
end $$;
revoke all on function candidate.submit_module_for_review(uuid) from public;
grant execute on function candidate.submit_module_for_review(uuid) to authenticated, service_role;

-- ── approve_module_version: in_review -> approved (MANAGER — accreditation) ──
-- Refuses if the bank has fewer than the module's question_count questions.
create or replace function candidate.approve_module_version(p_version_id uuid)
returns void language plpgsql security definer
set search_path = candidate, public as $$
declare v_status text; v_module uuid; v_need int; v_have int;
begin
  if not candidate.is_manager() then
    raise exception 'not authorized';
  end if;
  select mv.status, mv.module_id, tm.question_count
    into v_status, v_module, v_need
  from candidate.module_versions mv
  join candidate.training_modules tm on tm.id = mv.module_id
  where mv.id = p_version_id;
  if not found then raise exception 'module version % not found', p_version_id; end if;
  if v_status <> 'in_review' then
    raise exception 'only an in_review version can be approved (is %)', v_status;
  end if;
  select count(*) into v_have from candidate.training_questions where module_version_id = p_version_id;
  if v_have < v_need then
    raise exception 'cannot approve: % questions authored, module requires at least %', v_have, v_need;
  end if;
  update candidate.module_versions
    set status = 'approved', approved_by = auth.uid(), approved_at = now(), updated_at = now()
  where id = p_version_id;
  perform candidate.trg_training_version_event(p_version_id, 'training_approved',
    format('module version approved (%s questions in bank)', v_have));
end $$;
revoke all on function candidate.approve_module_version(uuid) from public;
grant execute on function candidate.approve_module_version(uuid) to authenticated, service_role;

-- ── publish_module_version: approved -> published (MANAGER) ──────────────────
-- Sets training_modules.current_version_id and retires the prior published
-- version. Appends the training_published audit row.
create or replace function candidate.publish_module_version(p_version_id uuid)
returns void language plpgsql security definer
set search_path = candidate, public as $$
declare v_status text; v_module uuid; v_prior uuid;
begin
  if not candidate.is_manager() then
    raise exception 'not authorized';
  end if;
  select status, module_id into v_status, v_module
    from candidate.module_versions where id = p_version_id;
  if not found then raise exception 'module version % not found', p_version_id; end if;
  if v_status <> 'approved' then
    raise exception 'only an approved version can be published (is %)', v_status;
  end if;

  -- Retire the prior published version (if any) for this module.
  select current_version_id into v_prior from candidate.training_modules where id = v_module;
  if v_prior is not null and v_prior <> p_version_id then
    update candidate.module_versions set status = 'retired', updated_at = now()
      where id = v_prior and status = 'published';
  end if;

  update candidate.module_versions
    set status = 'published', published_at = now(), updated_at = now()
  where id = p_version_id;

  update candidate.training_modules
    set current_version_id = p_version_id, updated_at = now()
  where id = v_module;

  perform candidate.trg_training_version_event(p_version_id, 'training_published',
    'module version published (current version set; prior retired)');
end $$;
revoke all on function candidate.publish_module_version(uuid) from public;
grant execute on function candidate.publish_module_version(uuid) to authenticated, service_role;

-- ── RLS ──────────────────────────────────────────────────────────────────────
alter table candidate.module_versions   enable row level security;
alter table candidate.training_questions enable row level security;

-- module_versions: authorised staff READ; all writes go through the RPCs above
-- (SECURITY DEFINER), so there is NO direct write policy.
drop policy if exists "auth read module_versions" on candidate.module_versions;
create policy "auth read module_versions" on candidate.module_versions
  for select to authenticated using (candidate.is_authorized_user());

-- training_questions: SELECT is MANAGER-ONLY (raw correct_keys are the answer
-- bank — a staff-token leak must not be able to dump them). No write policy:
-- questions are authored only via add_training_question (SECURITY DEFINER).
drop policy if exists "manager read training_questions" on candidate.training_questions;
create policy "manager read training_questions" on candidate.training_questions
  for select to authenticated
  using (candidate.is_authorized_user() and candidate.is_manager());

-- Table privileges. Writes to both tables are RPC-only (SECURITY DEFINER), so no
-- insert/update/delete grant here; RLS above still restricts question SELECT to
-- managers even though the grant is table-wide.
grant select on candidate.module_versions   to authenticated;
grant select on candidate.training_questions to authenticated;
