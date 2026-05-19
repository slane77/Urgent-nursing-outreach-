-- ============================================================================
--  Urgent Nursing Outreach Manager — Row Level Security Policies
--  File: 02_policies.sql
--  Run this SECOND, after 01_schema.sql.
--  Locks the database down so only authenticated users with an allowed email
--  domain can read or modify any data. Even if someone got hold of the public
--  Supabase URL and anon key, they would hit the login screen and could not
--  bypass these policies.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Helper function: is_authorized_user()
--    Returns true if the current logged-in user's email matches one of the
--    allowed domains. Edit the domain list below to control who can use the
--    system. The function is marked SECURITY DEFINER so it runs with elevated
--    privileges (needed to read the JWT).
--
--    >>> EDIT THIS LIST if you need to add/remove allowed domains <<<
-- ----------------------------------------------------------------------------
create or replace function public.is_authorized_user()
returns boolean
language sql
stable
security definer
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

-- Grant the function so any authenticated request can call it
grant execute on function public.is_authorized_user() to authenticated;


-- ----------------------------------------------------------------------------
-- 2. Enable RLS on all tables
--    Until policies are added, this locks the tables to NO ACCESS for
--    non-superuser roles. The policies below open up access selectively.
-- ----------------------------------------------------------------------------
alter table public.contacts    enable row level security;
alter table public.templates   enable row level security;
alter table public.email_sends enable row level security;


-- ----------------------------------------------------------------------------
-- 3. CONTACTS — policies (SELECT / INSERT / UPDATE / DELETE)
-- ----------------------------------------------------------------------------
create policy "Authorized users can view contacts"
  on public.contacts for select
  to authenticated
  using (public.is_authorized_user());

create policy "Authorized users can insert contacts"
  on public.contacts for insert
  to authenticated
  with check (public.is_authorized_user());

create policy "Authorized users can update contacts"
  on public.contacts for update
  to authenticated
  using (public.is_authorized_user())
  with check (public.is_authorized_user());

create policy "Authorized users can delete contacts"
  on public.contacts for delete
  to authenticated
  using (public.is_authorized_user());


-- ----------------------------------------------------------------------------
-- 4. TEMPLATES — policies
-- ----------------------------------------------------------------------------
create policy "Authorized users can view templates"
  on public.templates for select
  to authenticated
  using (public.is_authorized_user());

create policy "Authorized users can insert templates"
  on public.templates for insert
  to authenticated
  with check (public.is_authorized_user());

create policy "Authorized users can update templates"
  on public.templates for update
  to authenticated
  using (public.is_authorized_user())
  with check (public.is_authorized_user());

create policy "Authorized users can delete templates"
  on public.templates for delete
  to authenticated
  using (public.is_authorized_user());


-- ----------------------------------------------------------------------------
-- 5. EMAIL_SENDS — policies
-- ----------------------------------------------------------------------------
create policy "Authorized users can view sends"
  on public.email_sends for select
  to authenticated
  using (public.is_authorized_user());

create policy "Authorized users can insert sends"
  on public.email_sends for insert
  to authenticated
  with check (public.is_authorized_user());

create policy "Authorized users can update sends"
  on public.email_sends for update
  to authenticated
  using (public.is_authorized_user())
  with check (public.is_authorized_user());

create policy "Authorized users can delete sends"
  on public.email_sends for delete
  to authenticated
  using (public.is_authorized_user());


-- ----------------------------------------------------------------------------
-- 6. Sanity check — should return 12 rows (4 policies × 3 tables)
-- ----------------------------------------------------------------------------
-- select schemaname, tablename, policyname from pg_policies
--   where schemaname = 'public'
--   order by tablename, policyname;
