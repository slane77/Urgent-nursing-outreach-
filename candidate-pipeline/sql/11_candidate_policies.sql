-- ============================================================================
--  Day Webster — Candidate Pipeline  ·  Row Level Security
--  File: candidate-pipeline/sql/11_candidate_policies.sql
--  Run AFTER 10_candidate_schema.sql.
--
--  STATUS: DRAFT — NOT YET APPLIED. For review only.
--
--  Self-contained: defines its own authorisation helper in the `candidate`
--  schema so it does not couple to the public outreach system's policies.
--  Same allowed domains for now; change here independently if candidate-side
--  access should ever differ from outreach-side access.
-- ============================================================================

create or replace function candidate.is_authorized_user()
returns boolean
language sql stable security definer
set search_path = public
as $$
  select coalesce(
    lower(auth.jwt() ->> 'email') like '%@daywebster.com'
      or lower(auth.jwt() ->> 'email') like '%@daywebstergroup.com'
      or lower(auth.jwt() ->> 'email') like '%@homecare-providers.com'
      or lower(auth.jwt() ->> 'email') like '%@homecareproviders.co.uk',
    false
  );
$$;
grant execute on function candidate.is_authorized_user() to authenticated;

-- Schema usage
grant usage on schema candidate to authenticated;

-- Enable RLS on every table
alter table candidate.disciplines             enable row level security;
alter table candidate.specialties             enable row level security;
alter table candidate.sources                 enable row level security;
alter table candidate.candidates              enable row level security;
alter table candidate.employment              enable row level security;
alter table candidate.messages                enable row level security;
alter table candidate.consent                 enable row level security;
alter table candidate.compliance_requirements enable row level security;
alter table candidate.compliance_items        enable row level security;

-- One uniform policy set: authorised staff get full CRUD; everyone else nothing.
-- (Granularity per-role can come later; this matches the existing app's model.)
do $$
declare t text;
begin
  foreach t in array array[
    'disciplines','specialties','sources','candidates','employment',
    'messages','consent','compliance_requirements','compliance_items'
  ]
  loop
    execute format(
      'create policy "auth read %1$s"   on candidate.%1$s for select to authenticated using (candidate.is_authorized_user());', t);
    execute format(
      'create policy "auth insert %1$s" on candidate.%1$s for insert to authenticated with check (candidate.is_authorized_user());', t);
    execute format(
      'create policy "auth update %1$s" on candidate.%1$s for update to authenticated using (candidate.is_authorized_user()) with check (candidate.is_authorized_user());', t);
    execute format(
      'create policy "auth delete %1$s" on candidate.%1$s for delete to authenticated using (candidate.is_authorized_user());', t);
  end loop;
end $$;

-- NOTE (Supabase): to query schema `candidate` from supabase-js, either expose
-- it under Dashboard → Settings → API → "Exposed schemas", or create the client
-- with { db: { schema: 'candidate' } }. The existing app keeps using `public`
-- and is unaffected.
