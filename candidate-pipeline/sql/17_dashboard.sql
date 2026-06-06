-- ============================================================================
--  Day Webster — Candidate Pipeline · Control-tower views (Phase 3)
--  File: candidate-pipeline/sql/17_dashboard.sql
--  Run AFTER 10–16. Idempotent.
--
--  STATUS: DRAFT — NOT YET APPLIED. For review only.
--
--  Oversight metrics for dashboard.html:
--    - campaign_performance : spend + candidates + cost-per-candidate per campaign
--    - channel_spend        : advert spend rolled up by channel
--  (intake_by_channel already exists from sql/16; pipeline counts + needs-review
--   + expiring + unassigned-discipline are simple counts done in the dashboard.)
-- ============================================================================

create or replace view candidate.campaign_performance
with (security_invoker = true) as
select
  sc.id, sc.name, sc.kind, sc.channel, sc.status,
  sc.budget, sc.spend,
  d.name as discipline,
  count(c.id)                                              as candidates,
  count(c.id) filter (where c.status = 'qualified')        as qualified,
  count(c.id) filter (where c.status in ('ready','placed')) as ready_or_placed,
  case when count(c.id) > 0 then round(sc.spend / count(c.id), 2) end as cost_per_candidate
from candidate.sourcing_campaigns sc
left join candidate.candidates c   on c.campaign_id = sc.id
left join candidate.disciplines d  on d.id = sc.discipline_id
group by sc.id, d.name
order by candidates desc;

create or replace view candidate.channel_spend
with (security_invoker = true) as
select
  a.channel,
  count(*)                          as adverts,
  count(*) filter (where a.status='posted') as posted,
  coalesce(sum(a.cost), 0)          as spend
from candidate.adverts a
group by a.channel
order by spend desc;
