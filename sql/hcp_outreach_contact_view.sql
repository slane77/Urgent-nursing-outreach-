-- Applied through Supabase migration expose_hcp_audience_in_contact_history_view.
-- Preserve existing column order, privileges and invoker-based row security.
create or replace view public.contacts_with_last_email with (security_invoker = true) as
select c.id,c.created_at,c.updated_at,c.status,c.org,c.title,c.first_name,c.last_name,c.job_title,c.email,c.phone,c.add1,c.add2,c.town,c.postcode,c.region,c.country,c.notes,c.created_by,c.stage,c.follow_up_date,c.contact_notes,c.department,c.band_requested,c.source_url,
case when c.email ilike '%@pending.%' or c.email='' or c.email is null then true else false end as email_pending,
max(es.sent_at) as last_emailed_at,count(es.id) as total_emails_sent,c.vacancy_title,c.care_group,c.group_name
from public.contacts c left join public.email_sends es on es.contact_id=c.id group by c.id;
notify pgrst, 'reload schema';