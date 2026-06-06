-- ============================================================================
--  Day Webster — Candidate Pipeline · Inbound email
--  File: candidate-pipeline/sql/15_inbound_email.sql
--  Run AFTER 10–14. Idempotent / additive.
--
--  STATUS: DRAFT — NOT YET APPLIED. For review only.
--
--  Supports the inbound-email pipeline. Documents and references arrive by
--  email; to link an email back to the right candidate (and requirement) when
--  the sender is a referee — not the candidate — we issue a correlation TOKEN
--  embedded in the reply-to / plus-address / subject when we request a doc.
--
--  The `inbound-email` edge function looks the token up; if there's no token it
--  falls back to matching the sender's email to a candidate. Ingested files go
--  to a private Storage bucket `candidate-docs` (create it at deploy time) and
--  land on a compliance_item as status='received' — never auto-verified.
-- ============================================================================

create table if not exists candidate.email_tokens (
  token          text primary key,
  candidate_id   uuid not null references candidate.candidates(id) on delete cascade,
  requirement_id uuid references candidate.compliance_requirements(id) on delete set null,
  purpose        text not null default 'document'
                 check (purpose in ('document','reference')),
  created_at     timestamptz not null default now(),
  expires_at     timestamptz
);
create index if not exists email_tokens_candidate_idx on candidate.email_tokens (candidate_id);

alter table candidate.email_tokens enable row level security;

do $$
begin
  if not exists (select 1 from pg_policies where schemaname='candidate' and tablename='email_tokens' and policyname='auth read email_tokens') then
    execute 'create policy "auth read email_tokens"   on candidate.email_tokens for select to authenticated using (candidate.is_authorized_user())';
    execute 'create policy "auth insert email_tokens" on candidate.email_tokens for insert to authenticated with check (candidate.is_authorized_user())';
    execute 'create policy "auth update email_tokens" on candidate.email_tokens for update to authenticated using (candidate.is_authorized_user()) with check (candidate.is_authorized_user())';
    execute 'create policy "auth delete email_tokens" on candidate.email_tokens for delete to authenticated using (candidate.is_authorized_user())';
  end if;
end $$;
