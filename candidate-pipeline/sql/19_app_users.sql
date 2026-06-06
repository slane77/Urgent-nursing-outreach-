-- ============================================================================
--  Day Webster — Candidate Pipeline · People directory (for the admin UI)
--  File: candidate-pipeline/sql/19_app_users.sql
--  Run AFTER 10–18. Idempotent / additive.
--
--  STATUS: DRAFT — NOT YET APPLIED. For review only.
--
--  So admins can assign desks/roles by clicking (not SQL), staff pages record
--  the logged-in user here on sign-in. The admin screen lists this directory
--  and writes to `staff` (admin flag) and `desk_members` (desk assignment).
-- ============================================================================

create table if not exists candidate.app_users (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  email      text,
  full_name  text,
  last_seen  timestamptz not null default now()
);

alter table candidate.app_users enable row level security;

-- A user may upsert/see their own row; admins may see everyone.
drop policy if exists "self read app_users"   on candidate.app_users;
drop policy if exists "admin read app_users"  on candidate.app_users;
drop policy if exists "self write app_users"   on candidate.app_users;
drop policy if exists "self update app_users"  on candidate.app_users;
create policy "self read app_users"  on candidate.app_users for select to authenticated using (user_id = auth.uid());
create policy "admin read app_users" on candidate.app_users for select to authenticated using (candidate.is_authorized_user() and candidate.is_admin());
create policy "self write app_users"  on candidate.app_users for insert to authenticated with check (user_id = auth.uid());
create policy "self update app_users" on candidate.app_users for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
