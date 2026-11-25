-- Contact ownership and a compact shared directory. No contact or account records are deleted.
alter table public.contacts add column if not exists owner_user_id uuid references auth.users(id) on delete set null;
create index if not exists contacts_owner_user_id_idx on public.contacts(owner_user_id);

-- Expand the existing invoker view without changing its existing column order or send totals.
create or replace view public.contacts_with_last_email with (security_invoker=true) as
select c.id,c.created_at,c.updated_at,c.status,c.org,c.title,c.first_name,c.last_name,c.job_title,
 c.email,c.phone,c.add1,c.add2,c.town,c.postcode,c.region,c.country,c.notes,c.created_by,c.stage,
 c.follow_up_date,c.contact_notes,c.department,c.band_requested,c.source_url,
 case when c.email ilike '%@pending.%' or c.email='' or c.email is null then true else false end as email_pending,
 max(es.sent_at) as last_emailed_at,count(es.id) as total_emails_sent,
 c.vacancy_title,c.care_group,c.group_name,c.hcp_pathway,c.hcp_outreach_status,c.hcp_qualification_notes,c.hcp_reviewed_at,
 c.owner_user_id,
 (select s.sent_by from public.email_sends s where s.contact_id=c.id and s.status='sent' order by s.sent_at desc,s.id desc limit 1) as last_sent_by,
 (select max(s.sent_at) from public.email_sends s where s.contact_id=c.id and s.status='sent') as last_recorded_send_at
from public.contacts c left join public.email_sends es on es.contact_id=c.id group by c.id;

-- Deliberately exposes only work-display names and IDs to existing application users.
-- Definer access is necessary because profile RLS otherwise limits consultants to their own profile.
create or replace function public.outreach_team_directory() returns table(user_id uuid,full_name text,activity_archived boolean)
language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or not exists(select 1 from public.user_profiles p where p.user_id=auth.uid()) then
  raise exception 'Application access is required' using errcode='42501';
 end if;
 return query select p.user_id,coalesce(nullif(trim(p.full_name),''),'Team member'),p.activity_archived
 from public.user_profiles p order by p.full_name,p.user_id;
end $$;
revoke all on function public.outreach_team_directory() from public,anon;
grant execute on function public.outreach_team_directory() to authenticated;

-- HCP's generic review queue is retired. Unknown service classifications remain unknown.
-- This changes outreach workflow only, never email verification or suppression status.
create or replace function public.hcp_lead_workflow() returns trigger
language plpgsql security invoker set search_path='' as $$
begin
 if coalesce(new.notes,'') ilike '%Source: HCP Complex Care%'
    and new.status in ('lead','live') and new.hcp_outreach_status='needs_review' then
  new.hcp_outreach_status:='ready';
 end if;
 return new;
end $$;
revoke all on function public.hcp_lead_workflow() from public,anon,authenticated;
drop trigger if exists hcp_lead_workflow on public.contacts;
create trigger hcp_lead_workflow before insert or update of notes,status,hcp_outreach_status on public.contacts
for each row execute function public.hcp_lead_workflow();
