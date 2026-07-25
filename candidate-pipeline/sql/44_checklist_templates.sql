-- ============================================================================
--  Day Webster — Candidate Pipeline · Client Checklist Auto-Fill (Phase 1)
--  File: candidate-pipeline/sql/44_checklist_templates.sql
--  Run AFTER 43b. Idempotent / additive.  STATUS: DRAFT — NOT YET APPLIED.
--
--  The reusable client-form library + the append-only fill audit (design §2).
--
--    · checklist_templates — one row per client form VERSION: the tokenized .docx
--      path + the token->passport-field map + per-template missing_policy. A form
--      is NEVER mutated in place — an edit makes a new `version` (existing fills
--      froze their template_version). Officers create/edit; only admins retire
--      (status='retired') / delete — enforced via RLS (the update WITH CHECK
--      blocks a non-admin flipping to 'retired'; DELETE is admin-only).
--
--    · checklist_fills — the immutable "we sent client X this exact file for
--      candidate Y on date Z" record. Has NO client INSERT/UPDATE/DELETE policy:
--      the ONLY writers are the SECURITY DEFINER RPCs below (which run as owner),
--      so a fill can never be forged or back-dated — the same un-forgeable pattern
--      as verification_events / compliance_breaches (sql/37/38/42).
--
--    · record_checklist_fill / mark_checklist_sent — service-or-officer gated
--      writers; the SENT transition is cross-linked into the verification_events
--      audit timeline (event_type='checklist_sent', widened below).
--
--  Storage: two PRIVATE buckets (checklist-templates, checklist-outputs). Buckets
--  are created at deploy time (see DEPLOY.md) — like `candidate-docs`, Supabase
--  bucket creation is an API/dashboard action, not SQL. The officer-read object
--  policies are added here but GUARDED so the migration still applies clean in a
--  bare Postgres harness that has no `storage` schema.
-- ============================================================================

-- ── Extend the append-only audit vocabulary with 'checklist_sent' ────────────
-- Drop-then-add keeps this idempotent; the new list is a strict SUPERSET of
-- sql/42's (keeps every override_*/breach_* verb) so no existing
-- verification_events row is ever invalidated.
alter table candidate.verification_events
  drop constraint if exists verification_events_event_type_check;
alter table candidate.verification_events
  add constraint verification_events_event_type_check
  check (event_type in ('verified','rejected','unsuitable','expired','waived',
         'reinstated','evidence_received','recheck_requested','status_recomputed',
         'override_granted','override_revoked',
         'breach_logged','breach_acknowledged','breach_resolved',
         'checklist_sent'));

-- ── checklist_templates: the reusable client form + token map ────────────────
create table if not exists candidate.checklist_templates (
  id             uuid primary key default gen_random_uuid(),
  client_name    text not null,
  client_ref     text,
  name           text not null,                          -- 'St Elsewhere NHS — Agency Worker Checklist'
  version        int  not null default 1,
  status         text not null default 'draft'
                 check (status in ('draft','active','retired')),
  bucket         text not null default 'checklist-templates',
  template_path  text not null,                          -- tokenized .docx in Storage
  original_path  text,                                   -- untouched original (audit / re-tokenize)
  field_map      jsonb not null default '[]'::jsonb,     -- [{token, field|static, required, transform}]
  static_answers jsonb not null default '{}'::jsonb,     -- constant answers (agency name, PAYE ref…)
  missing_policy text not null default 'block'
                 check (missing_policy in ('block','annotate')),
  discipline_id  uuid references candidate.disciplines(id) on delete set null,
  created_by     uuid references auth.users(id) on delete set null,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (client_name, name, version)
);
create index if not exists checklist_templates_status_idx
  on candidate.checklist_templates (status);
create index if not exists checklist_templates_client_idx
  on candidate.checklist_templates (client_name);

drop trigger if exists checklist_templates_set_updated_at on candidate.checklist_templates;
create trigger checklist_templates_set_updated_at
  before update on candidate.checklist_templates
  for each row execute function candidate.set_updated_at();

-- ── checklist_fills: the append-only fill/send audit record ──────────────────
create table if not exists candidate.checklist_fills (
  id               uuid primary key default gen_random_uuid(),
  candidate_id     uuid not null references candidate.candidates(id) on delete cascade,
  template_id      uuid not null references candidate.checklist_templates(id) on delete restrict,
  template_version int  not null,                        -- frozen: which version was used
  bucket           text not null default 'checklist-outputs',
  output_path      text not null,                        -- generated .docx
  values_snapshot  jsonb not null,                       -- frozen passport values actually merged
  missing_fields   jsonb not null default '[]'::jsonb,   -- fields empty/needs-attention at fill time
  status           text not null default 'generated'
                   check (status in ('generated','needs_attention','sent')),
  generated_by     uuid references auth.users(id) on delete set null,
  generated_at     timestamptz not null default now(),
  sent_at          timestamptz,
  sent_by          uuid references auth.users(id) on delete set null
);
create index if not exists checklist_fills_candidate_idx
  on candidate.checklist_fills (candidate_id, generated_at desc);
create index if not exists checklist_fills_template_idx
  on candidate.checklist_fills (template_id);
create index if not exists checklist_fills_status_idx
  on candidate.checklist_fills (status);

-- ── RLS ─────────────────────────────────────────────────────────────────────
alter table candidate.checklist_templates enable row level security;
alter table candidate.checklist_fills     enable row level security;

-- Templates: officers read/create/edit; only admins retire (status='retired') or
-- delete. is_compliance_officer() already folds in is_admin, so admins are
-- covered by the officer policies for read/create/edit.
drop policy if exists "officer read templates"   on candidate.checklist_templates;
drop policy if exists "officer insert templates" on candidate.checklist_templates;
drop policy if exists "officer update templates" on candidate.checklist_templates;
drop policy if exists "admin delete templates"   on candidate.checklist_templates;

create policy "officer read templates" on candidate.checklist_templates
  for select to authenticated
  using (candidate.is_authorized_user() and candidate.is_compliance_officer());
create policy "officer insert templates" on candidate.checklist_templates
  for insert to authenticated
  with check (candidate.is_authorized_user() and candidate.is_compliance_officer());
-- Officers may edit drafts/active forms and activate them, but ONLY an admin may
-- flip a form to 'retired' (the WITH CHECK blocks a non-admin doing so).
create policy "officer update templates" on candidate.checklist_templates
  for update to authenticated
  using (candidate.is_authorized_user() and candidate.is_compliance_officer())
  with check (candidate.is_authorized_user() and candidate.is_compliance_officer()
              and (status <> 'retired' or candidate.is_admin()));
create policy "admin delete templates" on candidate.checklist_templates
  for delete to authenticated
  using (candidate.is_authorized_user() and candidate.is_admin());

-- Fills: officers READ only. NO insert/update/delete policy => not client-writable;
-- every write is via the SECURITY DEFINER RPCs below (un-forgeable audit).
drop policy if exists "officer read fills" on candidate.checklist_fills;
create policy "officer read fills" on candidate.checklist_fills
  for select to authenticated
  using (candidate.is_authorized_user() and candidate.is_compliance_officer());

grant select, insert, update, delete on candidate.checklist_templates to authenticated;
grant select on candidate.checklist_fills to authenticated;   -- writes are RPC-only

-- ── Storage object policies (officer read; service writes bypass RLS) ────────
-- Guarded: only run where the Supabase `storage.objects` table exists, so a bare
-- Postgres migration harness (no storage schema) applies this file clean. Bucket
-- CREATION is a deploy-time API action (see DEPLOY.md).
do $$
begin
  if to_regclass('storage.objects') is not null then
    execute $p$drop policy if exists "officer read checklist objects" on storage.objects$p$;
    execute $p$
      create policy "officer read checklist objects" on storage.objects
        for select to authenticated
        using (bucket_id in ('checklist-templates','checklist-outputs')
               and candidate.is_authorized_user() and candidate.is_compliance_officer())
    $p$;
    -- No INSERT/UPDATE/DELETE policy for authenticated: writes are performed by
    -- the service_role edge function, which bypasses storage RLS entirely.
  end if;
end $$;

-- ── record_checklist_fill: the ONLY writer of a fill row (service-or-officer) ─
-- Freezes template_version from the template, inserts the immutable fill record,
-- and — when the fill is created already 'sent' — stamps sent_at/sent_by and
-- cross-links a 'checklist_sent' audit event (so a SENT checklist is ALWAYS
-- audited exactly once, whichever path created it). A 'generated'/'needs_attention'
-- fill writes no audit verb; the send is audited later in mark_checklist_sent.
create or replace function candidate.record_checklist_fill(
    p_candidate_id    uuid,
    p_template_id     uuid,
    p_output_path     text,
    p_values_snapshot jsonb,
    p_missing_fields  jsonb default '[]'::jsonb,
    p_status          text  default 'generated')
returns uuid language plpgsql security definer
set search_path = candidate, public as $$
declare
  v_is_service boolean := candidate.is_service_role();
  v_actor      uuid    := auth.uid();
  v_tv         int;
  v_id         uuid;
begin
  if not ((candidate.is_authorized_user() and candidate.is_compliance_officer()) or v_is_service) then
    raise exception 'not authorized';
  end if;
  if p_status not in ('generated','needs_attention','sent') then
    raise exception 'invalid status: %', p_status;
  end if;
  if p_output_path is null or btrim(p_output_path) = '' then
    raise exception 'output_path is required';
  end if;

  select version into v_tv
  from candidate.checklist_templates where id = p_template_id;
  if not found then
    raise exception 'checklist template % not found', p_template_id;
  end if;

  insert into candidate.checklist_fills
    (candidate_id, template_id, template_version, output_path, values_snapshot,
     missing_fields, status, generated_by, sent_at, sent_by)
  values
    (p_candidate_id, p_template_id, v_tv, p_output_path, p_values_snapshot,
     coalesce(p_missing_fields, '[]'::jsonb), p_status, v_actor,
     case when p_status = 'sent' then now() end,
     case when p_status = 'sent' then v_actor end)
  returning id into v_id;

  -- A checklist created directly as 'sent' must still hit the audit timeline.
  if p_status = 'sent' then
    insert into candidate.verification_events
      (candidate_id, event_type, method, source_ref, notes, actor, actor_kind)
    values
      (p_candidate_id, 'checklist_sent',
       case when v_is_service then 'system' else 'human' end,
       v_id::text,
       format('client checklist sent (template v%s)', v_tv),
       v_actor, case when v_is_service then 'service' else 'human' end);
  end if;

  return v_id;
end;
$$;
revoke all on function candidate.record_checklist_fill(uuid, uuid, text, jsonb, jsonb, text) from public;
grant execute on function candidate.record_checklist_fill(uuid, uuid, text, jsonb, jsonb, text) to authenticated, service_role;

-- ── mark_checklist_sent: officer flips a fill to 'sent' + audits it ──────────
-- Refuses to send a 'needs_attention' fill (a compliance answer-blank is never
-- silently empty) UNLESS an admin explicitly overrides. Idempotent: a second call
-- on an already-sent fill is a no-op (no duplicate audit row).
create or replace function candidate.mark_checklist_sent(
    p_fill_id  uuid,
    p_override boolean default false)
returns void language plpgsql security definer
set search_path = candidate, public as $$
declare
  v_f candidate.checklist_fills;
begin
  if not (candidate.is_authorized_user() and candidate.is_compliance_officer()) then
    raise exception 'not authorized';
  end if;

  select * into v_f from candidate.checklist_fills where id = p_fill_id for update;
  if not found then
    raise exception 'checklist fill % not found', p_fill_id;
  end if;
  if v_f.status = 'sent' then
    return;                                    -- already sent: idempotent no-op
  end if;
  if v_f.status = 'needs_attention' and not (p_override and candidate.is_admin()) then
    raise exception 'checklist % needs attention — an admin override is required to send it', p_fill_id;
  end if;

  update candidate.checklist_fills
    set status = 'sent', sent_at = now(), sent_by = auth.uid()
    where id = p_fill_id;

  insert into candidate.verification_events
    (candidate_id, event_type, method, source_ref, notes, actor, actor_kind)
  values
    (v_f.candidate_id, 'checklist_sent', 'human', p_fill_id::text,
     format('client checklist marked sent%s',
            case when v_f.status = 'needs_attention' then ' (admin override — was needs_attention)' else '' end),
     auth.uid(), 'human');
end;
$$;
revoke all on function candidate.mark_checklist_sent(uuid, boolean) from public;
grant execute on function candidate.mark_checklist_sent(uuid, boolean) to authenticated;
