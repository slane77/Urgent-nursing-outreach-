-- Synthetic verification only: all inserted records are rolled back.
begin;
insert into public.contacts(email,status,org,notes,group_name,care_group) values
('hcp-audience-test-lead@example.invalid','lead','Synthetic HCP audience verification','Source: HCP Complex Care','HCP - Verification','Verification area'),
('hcp-audience-test-live@example.invalid','live','Synthetic HCP audience verification','Source: HCP Complex Care','HCP - Verification','Verification area'),
('hcp-audience-test-unsub@example.invalid','unsubscribed','Synthetic HCP audience verification','Source: HCP Complex Care','HCP - Verification','Verification area'),
('hcp-audience-test-bounced@example.invalid','bounced','Synthetic HCP audience verification','Source: HCP Complex Care','HCP - Verification','Verification area');
do $$
begin
 if (select count(*) from public.contacts_with_last_email where group_name='HCP - Verification' and care_group='Verification area' and status in ('lead','live')) <> 2 then
  raise exception 'Contact-history view must expose both emailable statuses and the audience field';
 end if;
 if not exists(select 1 from pg_class where oid='public.contacts_with_last_email'::regclass and 'security_invoker=true'=any(reloptions)) then
  raise exception 'Contact-history view must retain security_invoker';
 end if;
end $$;
set local role anon;
do $$
begin
 if exists(select 1 from public.contacts_with_last_email where group_name='HCP - Verification') then
  raise exception 'Anonymous role must not see contact audience records';
 end if;
end $$;
reset role;
rollback;