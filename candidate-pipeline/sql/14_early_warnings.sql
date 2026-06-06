-- ============================================================================
--  Day Webster — Candidate Pipeline · Early Warnings
--  File: candidate-pipeline/sql/14_early_warnings.sql
--  Run AFTER 10–13. Idempotent / additive.
--
--  STATUS: DRAFT — NOT YET APPLIED. For review only.
--
--  The assessment's highest-ROI loop (§6): the system already knows every
--  expiry date, so a human shouldn't be running queries and chasing by hand.
--  This adds:
--    - chased_at  : so the monitor doesn't re-chase the same item every run
--    - expiring_items view : the live worklist (expired + next 60 days, bucketed)
--  The `early-warnings` edge function sweeps these and auto-chases candidates.
-- ============================================================================

alter table candidate.compliance_items
  add column if not exists chased_at timestamptz;

-- Live worklist: anything expired or expiring within 60 days, with the same
-- buckets the assessment uses (expired / 1-7 / 8-14 / 15-30 / 31-60 days).
create or replace view candidate.expiring_items
with (security_invoker = true) as
select
  ci.id            as item_id,
  ci.candidate_id,
  c.first_name, c.last_name, c.email,
  d.name           as discipline,
  cr.name          as requirement,
  ci.status,
  ci.expires_at,
  ci.chased_at,
  (ci.expires_at::date - current_date) as days_left,
  case
    when ci.expires_at <  now()                       then 'expired'
    when ci.expires_at <  now() + interval '8 days'   then '1-7'
    when ci.expires_at <  now() + interval '15 days'  then '8-14'
    when ci.expires_at <  now() + interval '31 days'  then '15-30'
    else '31-60'
  end as bucket
from candidate.compliance_items ci
join candidate.candidates c               on c.id = ci.candidate_id
left join candidate.disciplines d         on d.id = c.discipline_id
left join candidate.compliance_requirements cr on cr.id = ci.requirement_id
where ci.expires_at is not null
  and ci.expires_at < now() + interval '60 days'
  and ci.status <> 'expired'  -- already-handled expiries drop off the worklist
order by ci.expires_at;
