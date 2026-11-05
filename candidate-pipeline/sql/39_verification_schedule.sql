-- ============================================================================
--  Day Webster — Candidate Pipeline · Compliance Phase 2: verification schedule
--  File: candidate-pipeline/sql/39_verification_schedule.sql
--  Run AFTER 38. Idempotent / additive.  STATUS: DRAFT — NOT YET APPLIED.
--
--  Two pg_cron jobs that drive the queue via the `verification` edge function
--  (extends the early-warnings cron pattern), plus a raw-response retention
--  purge (§2.6 data-protection):
--    · verification-drain  — every 10 min: process queued jobs (mode=drain).
--    · verification-sweep  — daily: top up annual/expiry re-checks (mode=sweep)
--                            and purge stale raw provider responses.
--
--  The net.http_post call is COMMENTED with a <FUNCTIONS_BASE_URL> placeholder
--  (same convention as DEPLOY.md §5) — set the two GUCs below (or edit the command)
--  before relying on it. The whole block is guarded on pg_cron being installed, so
--  this migration still applies clean on a vanilla Postgres (it just NOTICEs).
-- ============================================================================

-- ── Retention purge: null out stale raw provider payloads ────────────────────
-- provider_jobs.response can hold third-party PII (§2.6). Once a job is finalised
-- and older than the retention window, drop the raw payload but KEEP the audit
-- skeleton (status/outcome/source_ref + the immutable verification_events). The
-- append-only audit spine is untouched — only the transient raw body is cleared.
create or replace function candidate.purge_provider_job_responses(p_days int default 90)
returns int language plpgsql security definer
set search_path = candidate, public as $$
declare v_count int;
begin
  with purged as (
    update candidate.provider_jobs
    set response = null,
        request  = null
    where status in ('succeeded','failed','needs_human','cancelled')
      and response is not null
      and updated_at < now() - make_interval(days => greatest(coalesce(p_days, 90), 1))
    returning 1
  )
  select count(*) into v_count from purged;
  return coalesce(v_count, 0);
end;
$$;
revoke all on function candidate.purge_provider_job_responses(int) from public;
grant execute on function candidate.purge_provider_job_responses(int) to service_role;

-- ── pg_cron schedules (guarded — apply-safe without the extension) ───────────
-- Configure once (per project) so the commands resolve:
--   alter database postgres set app.functions_base_url = 'https://<ref>.functions.supabase.co';
--   alter database postgres set app.cron_secret        = '<CRON_SECRET>';
-- (Coalesced to visible <PLACEHOLDER> tokens if unset, so an unconfigured job
--  is obviously-broken rather than silently pointing somewhere wrong.)
do $$
declare
  v_base   text := coalesce(current_setting('app.functions_base_url', true), '<FUNCTIONS_BASE_URL>');
  v_secret text := coalesce(current_setting('app.cron_secret', true), '<CRON_SECRET>');
  v_drain  text;
  v_sweep  text;
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice 'pg_cron not installed — skipping verification-drain / verification-sweep. Schedule them in the Supabase dashboard or after `create extension pg_cron;` (see DEPLOY.md §5).';
    return;
  end if;

  -- Mirror DEPLOY.md §5: net.http_post to the function with ?mode=&secret=.
  v_drain := format(
    $cmd$select net.http_post(url := '%s/verification?mode=drain&secret=%s', headers := '{"Content-Type":"application/json"}'::jsonb)$cmd$,
    v_base, v_secret);
  v_sweep := format(
    $cmd$select net.http_post(url := '%s/verification?mode=sweep&secret=%s', headers := '{"Content-Type":"application/json"}'::jsonb)$cmd$,
    v_base, v_secret);

  -- Idempotent: drop any prior job of the same name, then (re)schedule.
  perform cron.unschedule(jobid) from cron.job
    where jobname in ('verification-drain','verification-sweep');

  perform cron.schedule('verification-drain', '*/10 * * * *', v_drain);
  perform cron.schedule('verification-sweep', '30 6 * * *',   v_sweep);
  raise notice 'scheduled verification-drain (*/10) + verification-sweep (daily 06:30).';
end $$;

-- Note: the daily sweep (mode=sweep) in functions/verification calls
-- enqueue_due_rechecks() and MAY also call purge_provider_job_responses() to
-- enforce retention. To run the purge purely in-DB instead, add a third cron:
--   select cron.schedule('verification-purge','0 3 * * *',
--     $$ select candidate.purge_provider_job_responses(90) $$);
