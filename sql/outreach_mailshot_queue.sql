-- Durable outreach delivery. No changes to existing consultant sector policies.
create table public.outreach_mailshots (
 id uuid primary key, owner_id uuid not null references auth.users(id),
 audience text not null check (audience in ('contacts','candidates')),
 template_name text not null, payload jsonb not null,
 created_at timestamptz not null default now()
);
create table public.outreach_mailshot_items (
 id bigint generated always as identity primary key,
 mailshot_id uuid not null references public.outreach_mailshots(id) on delete cascade,
 recipient_id uuid not null, status text not null default 'queued'
 check(status in ('queued','processing','sent','failed','skipped','uncertain','cancelled')),
 claimed_at timestamptz, finished_at timestamptz, detail text,
 unique(mailshot_id,recipient_id)
);
create index outreach_queue_pending on public.outreach_mailshot_items(id) where status='queued';
create index outreach_queue_campaign on public.outreach_mailshot_items(mailshot_id,status);
alter table public.outreach_mailshots enable row level security;
alter table public.outreach_mailshot_items enable row level security;
revoke all on public.outreach_mailshots, public.outreach_mailshot_items from anon,authenticated;
grant select on public.outreach_mailshots, public.outreach_mailshot_items to authenticated;
grant all on public.outreach_mailshots, public.outreach_mailshot_items to service_role;
grant usage,select on sequence public.outreach_mailshot_items_id_seq to service_role;
create policy own_mailshots on public.outreach_mailshots for select to authenticated using(owner_id=(select auth.uid()));
create policy own_mailshot_items on public.outreach_mailshot_items for select to authenticated using(exists(select 1 from public.outreach_mailshots m where m.id=mailshot_id and m.owner_id=(select auth.uid())));
create schema if not exists outreach_private;
revoke all on schema outreach_private from public,anon,authenticated;
create table outreach_private.worker_config (id boolean primary key default true check(id), secret text not null default (gen_random_uuid()::text || gen_random_uuid()::text), last_claim timestamptz, enabled boolean not null default false);
insert into outreach_private.worker_config(id) values(true);

create or replace function public.queue_outreach_mailshot(p_id uuid,p_audience text,p_template uuid,p_recipients uuid[],p_options jsonb default '{}'::jsonb)
returns uuid language plpgsql security definer set search_path='' as $$
declare u uuid:=auth.uid(); prof public.user_profiles; t public.templates; ids uuid[]; existing public.outreach_mailshots;
begin
 if u is null then raise exception 'Sign in to queue a mailshot'; end if;
 select * into prof from public.user_profiles where user_id=u;
 if not found then raise exception 'Authorised profile required'; end if;
 select * into existing from public.outreach_mailshots where id=p_id;
 if found then
  if existing.owner_id<>u then raise exception 'Request ID already used'; end if;
  return p_id;
 end if;
 if p_audience not in ('contacts','candidates') then raise exception 'Invalid audience'; end if;
 if coalesce(cardinality(p_recipients),0)=0 or cardinality(p_recipients)>50000 then raise exception 'Choose between 1 and 50000 recipients'; end if;
 if array_position(p_recipients,null) is not null then raise exception 'Invalid recipient'; end if;
 select array_agg(distinct x) into ids from unnest(p_recipients) x;
 select * into t from public.templates where id=p_template;
 if not found then raise exception 'Template not found'; end if;
 if p_audience='candidates' then
  if (select count(*) from public.candidates c where c.id=any(ids) and (prof.role='admin' or c.sector=any(coalesce(prof.candidate_sectors,'{}')))) <> cardinality(ids) then raise exception 'Candidate missing or outside your permitted sectors'; end if;
 else
  if (select count(*) from public.contacts c where c.id=any(ids)) <> cardinality(ids) then raise exception 'One or more contacts no longer exists'; end if;
 end if;
 insert into public.outreach_mailshots(id,owner_id,audience,template_name,payload)
 values(p_id,u,p_audience,t.name,jsonb_build_object('templateId',p_template,'template',jsonb_build_object('subject',t.subject,'body',t.body),'source',p_options->>'source','subSource',p_options->>'subSource','jobDetails',p_options->'jobDetails'));
 insert into public.outreach_mailshot_items(mailshot_id,recipient_id) select p_id,x from unnest(ids) x;
 return p_id;
end $$;
revoke all on function public.queue_outreach_mailshot(uuid,text,uuid,uuid[],jsonb) from public,anon;
grant execute on function public.queue_outreach_mailshot(uuid,text,uuid,uuid[],jsonb) to authenticated;

create or replace function public.outreach_mailshot_status()
returns table(id uuid,template_name text,audience text,created_at timestamptz,total bigint,queued bigint,processing bigint,sent bigint,failed bigint,skipped bigint,uncertain bigint,cancelled bigint)
language sql security invoker set search_path='' as $$
 select m.id,m.template_name,m.audience,m.created_at,count(i.id),count(*) filter(where i.status='queued'),count(*) filter(where i.status='processing'),count(*) filter(where i.status='sent'),count(*) filter(where i.status='failed'),count(*) filter(where i.status='skipped'),count(*) filter(where i.status='uncertain'),count(*) filter(where i.status='cancelled')
 from (select * from public.outreach_mailshots order by created_at desc limit 10) m join public.outreach_mailshot_items i on i.mailshot_id=m.id group by m.id,m.template_name,m.audience,m.created_at order by m.created_at desc;
$$;
revoke all on function public.outreach_mailshot_status() from public,anon;
grant execute on function public.outreach_mailshot_status() to authenticated;

create or replace function public.cancel_outreach_mailshot(p_id uuid) returns void language plpgsql security definer set search_path='' as $$
begin
 if not exists(select 1 from public.outreach_mailshots where id=p_id and owner_id=auth.uid()) then raise exception 'Mailshot not found'; end if;
 update public.outreach_mailshot_items set status='cancelled',finished_at=now() where mailshot_id=p_id and status='queued';
end $$;
revoke all on function public.cancel_outreach_mailshot(uuid) from public,anon;
grant execute on function public.cancel_outreach_mailshot(uuid) to authenticated;

create or replace function public.claim_outreach_mailshot(p_secret text)
returns setof public.outreach_mailshot_items language plpgsql security definer set search_path='' as $$
declare cfg outreach_private.worker_config;
begin
 select * into cfg from outreach_private.worker_config where id=true for update;
 if p_secret is null or cfg.secret<>p_secret then raise exception 'Invalid worker credentials'; end if;
 if not cfg.enabled or cfg.last_claim > now()-interval '55 seconds' then return; end if;
 update outreach_private.worker_config set last_claim=now() where id=true;
 -- Never automatically resend a request whose provider outcome is unknown.
 update public.outreach_mailshot_items set status='uncertain',finished_at=now(),detail='Worker interrupted; review delivery before sending again' where status='processing' and claimed_at<now()-interval '10 minutes';
 return query update public.outreach_mailshot_items set status='processing',claimed_at=now()
 where id in (select id from public.outreach_mailshot_items where status='queued' order by id for update skip locked limit 100) returning *;
end $$;
revoke all on function public.claim_outreach_mailshot(text) from public,anon,authenticated;
grant execute on function public.claim_outreach_mailshot(text) to service_role;
