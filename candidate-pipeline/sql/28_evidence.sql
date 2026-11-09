-- ============================================================================
--  Day Webster — Candidate Pipeline · Compliance Phase 1: evidence store
--  File: candidate-pipeline/sql/28_evidence.sql
--  Run AFTER 22-27. Idempotent / additive.  STATUS: DRAFT — NOT YET APPLIED.
--
--  compliance_items.artefact_path holds a single document; the portal needs
--  multiple docs per requirement (+ audit-pack compilation). This table records
--  every uploaded artefact in the private `candidate-docs` bucket. RLS: any
--  authorised staff may READ (to build audit packs / preview signed URLs);
--  only compliance officers may INSERT; only admins may DELETE.
-- ============================================================================

create table if not exists candidate.candidate_evidence (
  id             uuid primary key default gen_random_uuid(),
  candidate_id   uuid not null references candidate.candidates(id) on delete cascade,
  item_id        uuid references candidate.compliance_items(id) on delete set null,
  requirement_id uuid references candidate.compliance_requirements(id) on delete set null,
  bucket         text not null default 'candidate-docs',
  path           text not null,               -- object path within the bucket
  filename       text,
  content_type   text,
  size_bytes     bigint,
  sha256         text,
  uploaded_by    uuid references auth.users(id) on delete set null,
  uploaded_at    timestamptz not null default now()
);
create index if not exists candidate_evidence_candidate_idx
  on candidate.candidate_evidence (candidate_id);
create index if not exists candidate_evidence_item_idx
  on candidate.candidate_evidence (item_id);
create index if not exists candidate_evidence_requirement_idx
  on candidate.candidate_evidence (requirement_id);

alter table candidate.candidate_evidence enable row level security;

drop policy if exists "auth read evidence"          on candidate.candidate_evidence;
drop policy if exists "compliance insert evidence"  on candidate.candidate_evidence;
drop policy if exists "admin delete evidence"       on candidate.candidate_evidence;

create policy "auth read evidence" on candidate.candidate_evidence
  for select to authenticated
  using (candidate.is_authorized_user());

create policy "compliance insert evidence" on candidate.candidate_evidence
  for insert to authenticated
  with check (candidate.is_authorized_user() and candidate.is_compliance_officer());

create policy "admin delete evidence" on candidate.candidate_evidence
  for delete to authenticated
  using (candidate.is_authorized_user() and candidate.is_admin());
-- (No UPDATE policy: evidence rows are write-once; correct a mistake by
--  deleting [admin] and re-inserting.)
