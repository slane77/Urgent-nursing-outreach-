-- ============================================================================
--  Day Webster — Candidate Pipeline · consent state + suppression (Phase 2)
--  File: candidate-pipeline/sql/20_consent_suppression.sql
--  Run AFTER 10–19. Idempotent / additive.
--
--  STATUS: DRAFT — NOT YET APPLIED. For review only.
--
--  Fixes the PECR / UK-GDPR consent-withdrawal defect: `candidate.consent` is
--  append-only (one row per grant/withdraw), so "has any granted row" is NOT
--  the same as "currently consents". This adds:
--    - consent_current      : the LATEST consent state per (candidate, purpose)
--    - email_suppression     : a hard do-not-contact list (STOP replies/bounces)
--    - campaign_targets()    : the ONLY sanctioned recipient source for outreach
--                              — latest consent granted for the given purpose,
--                              minus anyone suppressed, deduped to one row each.
-- ============================================================================

-- LATEST consent state per (candidate, purpose) -----------------------------
create or replace view candidate.consent_current
with (security_invoker = true) as
select distinct on (candidate_id, purpose)
  candidate_id,
  purpose,
  granted,
  basis,
  occurred_at
from candidate.consent
-- id desc breaks ties when two rows share the exact occurred_at, so "latest"
-- is deterministic (the most recently inserted event wins).
order by candidate_id, purpose, occurred_at desc, id desc;

-- HARD suppression list (opt-outs, unsubscribe clicks, hard bounces) ---------
create table if not exists candidate.email_suppression (
  email       text primary key,
  reason      text,
  created_at  timestamptz not null default now(),
  created_by  uuid references auth.users(id) on delete set null
);
alter table candidate.email_suppression enable row level security;

do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'candidate' and tablename = 'email_suppression'
      and policyname = 'auth read suppression'
  ) then
    -- Staff may read the list; all WRITES go through service-role functions.
    create policy "auth read suppression" on candidate.email_suppression
      for select to authenticated using (candidate.is_authorized_user());
  end if;
end $$;

-- PECR-safe recipient list for outreach-campaign ----------------------------
--   Only candidates whose MOST RECENT consent for p_purpose is granted, who
--   have an email, are in one of p_statuses, and are NOT on the suppression
--   list. One row per candidate. Cap hard-limited to 500.
create or replace function candidate.campaign_targets(
  p_purpose    text,
  p_statuses   text[],
  p_discipline uuid default null,
  p_limit      int  default 200
) returns table (id uuid, first_name text, email text)
language sql
security definer
set search_path = candidate, public
as $$
  select c.id, c.first_name, c.email
  from candidate.candidates c
  join candidate.consent_current cc
    on cc.candidate_id = c.id
   and cc.purpose = p_purpose
   and cc.granted
  where c.email is not null
    and c.status = any (p_statuses)
    and (p_discipline is null or c.discipline_id = p_discipline)
    and not exists (
      select 1 from candidate.email_suppression s
      where lower(s.email) = lower(c.email)
    )
  order by c.id
  limit greatest(1, least(coalesce(p_limit, 200), 500));
$$;

-- Lock the function down: only the service role (used by the edge functions)
-- may execute it; never anon/authenticated directly.
revoke all on function candidate.campaign_targets(text, text[], uuid, int) from public;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function candidate.campaign_targets(text, text[], uuid, int) to service_role';
  end if;
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on function candidate.campaign_targets(text, text[], uuid, int) from anon';
  end if;
end $$;
