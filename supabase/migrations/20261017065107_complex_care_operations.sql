-- Internal operational records. No patient identities or documents belong here.
create table public.cc_packages (
 id uuid primary key default gen_random_uuid(),
 provider text not null check(length(trim(provider)) between 1 and 160),
 reference text not null check(length(trim(reference)) between 1 and 100),
 postcode text not null check(length(trim(postcode)) between 5 and 10),
 population text not null check(population in ('adults','children')),
 skills text[] not null default '{}' check(skills <@ array['tracheostomy','invasive_ventilation','noninvasive_ventilation','suction','peg','neurological','seizures','home_care']::text[]),
 requirements text not null check(length(trim(requirements)) between 1 and 2000),
 active boolean not null default true,
 created_by uuid not null default auth.uid(),created_at timestamptz not null default now()
);
create table public.cc_availability (
 id uuid primary key default gen_random_uuid(),candidate_id uuid not null references public.candidates(id),
 starts_at timestamptz not null,ends_at timestamptz not null,
 confirmed_at timestamptz not null default now(),confirmation text not null check(length(trim(confirmation)) between 1 and 300),
 withdrawn boolean not null default false,
 created_by uuid not null default auth.uid(),created_at timestamptz not null default now(),
 check(ends_at>starts_at and ends_at<=starts_at+interval '31 days')
);
create index on public.cc_availability(candidate_id,starts_at,ends_at);
create table public.cc_package_approvals (
 id uuid primary key default gen_random_uuid(),candidate_id uuid not null references public.candidates(id),
 package_id uuid not null references public.cc_packages(id),
 clinical_approver text not null check(length(trim(clinical_approver)) between 1 and 160),
 clinical_reference text not null check(length(trim(clinical_reference)) between 1 and 300),
 clinical_until timestamptz not null,
 compliance_reviewer text not null check(length(trim(compliance_reviewer)) between 1 and 160),
 compliance_reference text not null check(length(trim(compliance_reference)) between 1 and 300),
 compliance_until timestamptz not null,
 provider_reference text not null check(length(trim(provider_reference)) between 1 and 300),
 revoked boolean not null default false,revocation_reason text not null default '' check(length(revocation_reason)<=500),
 revoked_by uuid,revoked_at timestamptz,
 created_by uuid not null default auth.uid(),created_at timestamptz not null default now()
);
create index on public.cc_package_approvals(candidate_id,package_id);
create index on public.cc_package_approvals(package_id);
create table public.cc_shifts (
 id uuid primary key default gen_random_uuid(),package_id uuid not null references public.cc_packages(id),
 starts_at timestamptz not null,ends_at timestamptz not null,
 request_reference text not null check(length(trim(request_reference)) between 1 and 300),
 pay_rate numeric(8,2) not null check(pay_rate>=0),charge_rate numeric(8,2) not null check(charge_rate>=0),
 closed boolean not null default false,created_by uuid not null default auth.uid(),created_at timestamptz not null default now(),
 check(ends_at>starts_at and ends_at<=starts_at+interval '24 hours')
);
create index on public.cc_shifts(starts_at);
create index on public.cc_shifts(package_id);
create table public.cc_bookings (
 id uuid primary key default gen_random_uuid(),shift_id uuid not null references public.cc_shifts(id),
 candidate_id uuid not null references public.candidates(id),approval_id uuid not null references public.cc_package_approvals(id),
 availability_id uuid not null references public.cc_availability(id),
 nurse_confirmation text not null check(length(trim(nurse_confirmation)) between 1 and 300),
 provider_confirmation text not null check(length(trim(provider_confirmation)) between 1 and 300),
 status text not null default 'booked' check(status in ('booked','cancelled','completed')),
 outcome_note text not null default '' check(length(outcome_note)<=500),
 created_by uuid not null default auth.uid(),created_at timestamptz not null default now(),
 updated_by uuid,updated_at timestamptz
);
create unique index cc_one_assignment_per_shift on public.cc_bookings(shift_id) where status<>'cancelled';
create index on public.cc_bookings(candidate_id,status);
create index on public.cc_bookings(approval_id);
create index on public.cc_bookings(availability_id);

-- Existing administrators can record documentary sign off, not self certify nurses.
create function public.cc_operations_admin() returns boolean language sql stable security invoker set search_path='' as $$
 select public.can_access_candidate_sector('nursing_urgent') and exists(select 1 from public.user_profiles where user_id=(select auth.uid()) and role='admin');
$$;
revoke all on function public.cc_operations_admin() from public,anon;
grant execute on function public.cc_operations_admin() to authenticated;

do $$declare t text;begin
 foreach t in array array['cc_packages','cc_availability','cc_package_approvals','cc_shifts','cc_bookings'] loop
 execute format('alter table public.%I enable row level security',t);
 execute format('revoke all on public.%I from public,anon,authenticated',t);
 execute format('grant select on public.%I to authenticated',t);
 execute format('grant all on public.%I to service_role',t);
 end loop;
end$$;
create policy cc_package_read on public.cc_packages for select to authenticated using((select public.can_access_candidate_sector('nursing_urgent')));
create policy cc_package_insert on public.cc_packages for insert to authenticated with check((select public.can_access_candidate_sector('nursing_urgent')) and created_by=(select auth.uid()));
create policy cc_package_update on public.cc_packages for update to authenticated using((select public.can_access_candidate_sector('nursing_urgent'))) with check((select public.can_access_candidate_sector('nursing_urgent')));
grant insert(provider,reference,postcode,population,skills,requirements),update(active) on public.cc_packages to authenticated;
create policy cc_shift_read on public.cc_shifts for select to authenticated using((select public.can_access_candidate_sector('nursing_urgent')));
create policy cc_shift_insert on public.cc_shifts for insert to authenticated with check((select public.can_access_candidate_sector('nursing_urgent')) and created_by=(select auth.uid()));
create policy cc_shift_update on public.cc_shifts for update to authenticated using((select public.can_access_candidate_sector('nursing_urgent'))) with check((select public.can_access_candidate_sector('nursing_urgent')));
grant insert(package_id,starts_at,ends_at,request_reference,pay_rate,charge_rate),update(closed) on public.cc_shifts to authenticated;
do $$declare t text;begin
 foreach t in array array['cc_availability','cc_package_approvals','cc_bookings'] loop
 execute format('create policy cc_read on public.%I for select to authenticated using(exists(select 1 from public.candidates c where c.id=candidate_id and c.sector=''nursing_urgent'' and public.can_access_candidate_sector(c.sector)))',t);
 execute format('create policy cc_insert on public.%I for insert to authenticated with check(created_by=(select auth.uid()) and exists(select 1 from public.candidates c where c.id=candidate_id and c.sector=''nursing_urgent'' and public.can_access_candidate_sector(c.sector)))',t);
 execute format('create policy cc_update on public.%I for update to authenticated using(exists(select 1 from public.candidates c where c.id=candidate_id and c.sector=''nursing_urgent'' and public.can_access_candidate_sector(c.sector))) with check(exists(select 1 from public.candidates c where c.id=candidate_id and c.sector=''nursing_urgent'' and public.can_access_candidate_sector(c.sector)))',t);
 end loop;
end$$;
grant insert(candidate_id,starts_at,ends_at,confirmed_at,confirmation),update(withdrawn) on public.cc_availability to authenticated;
grant insert(candidate_id,package_id,clinical_approver,clinical_reference,clinical_until,compliance_reviewer,compliance_reference,compliance_until,provider_reference),update(revoked,revocation_reason) on public.cc_package_approvals to authenticated;
create policy cc_approval_admin on public.cc_package_approvals as restrictive for insert to authenticated with check((select public.cc_operations_admin()));
create policy cc_revoke_admin on public.cc_package_approvals as restrictive for update to authenticated using((select public.cc_operations_admin())) with check((select public.cc_operations_admin()));
grant insert(shift_id,candidate_id,approval_id,availability_id,nurse_confirmation,provider_confirmation),update(status,outcome_note) on public.cc_bookings to authenticated;

create function public.cc_guard_records() returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if auth.uid() is null or not public.can_access_candidate_sector('nursing_urgent') then raise exception 'Urgent Nursing access required';end if;
 if tg_table_name='cc_availability' then
  if tg_op='INSERT' and (new.confirmed_at>now() or new.ends_at<=now()) then raise exception 'Record a past confirmation and future availability';end if;
  if tg_op='UPDATE' and old.withdrawn and not new.withdrawn then raise exception 'Record a fresh availability confirmation instead';end if;
 elsif tg_table_name='cc_package_approvals' then
  if not public.cc_operations_admin() then raise exception 'An administrator must record the clinical and compliance sign off';end if;
  if tg_op='INSERT' then
   if new.clinical_until<=now() or new.compliance_until<=now() then raise exception 'Approval dates must be in the future';end if;
   if not exists(select 1 from public.cc_packages where id=new.package_id and active) then raise exception 'Package is inactive';end if;
  else
   if old.revoked or not new.revoked or length(trim(new.revocation_reason))=0 then raise exception 'Revocation needs a reason; create a new record to renew approval';end if;
   new.revoked_by=auth.uid();new.revoked_at=now();
  end if;
 elsif tg_table_name='cc_shifts' then
  if tg_op='INSERT' and (new.starts_at<=now() or not exists(select 1 from public.cc_packages where id=new.package_id and active)) then raise exception 'Select an active package and a future shift';end if;
  if tg_op='UPDATE' and new.closed and exists(select 1 from public.cc_bookings where shift_id=new.id and status='booked') then raise exception 'Cancel the active booking before closing the shift';end if;
 end if;
 return new;
end$$;
revoke all on function public.cc_guard_records() from public,anon,authenticated;
create trigger cc_availability_guard before insert or update on public.cc_availability for each row execute function public.cc_guard_records();
create trigger cc_approval_guard before insert or update on public.cc_package_approvals for each row execute function public.cc_guard_records();
create trigger cc_shift_guard before insert or update on public.cc_shifts for each row execute function public.cc_guard_records();

-- The same validation drives the shortlist and booking confirmation.
create function public.cc_booking_issues(p_shift uuid,p_candidate uuid,p_approval uuid,p_availability uuid,p_ignore_booking uuid default null)
returns text[] language plpgsql volatile security invoker set search_path='' as $$
declare s public.cc_shifts;c public.candidates;p public.cc_packages;a public.cc_package_approvals;v public.cc_availability;issues text[]='{}';
begin
 select * into s from public.cc_shifts where id=p_shift;
 select * into c from public.candidates where id=p_candidate and sector='nursing_urgent';
 if s.id is null or c.id is null then return array['Shift or candidate unavailable'];end if;
 select * into p from public.cc_packages where id=s.package_id;
 select * into a from public.cc_package_approvals where id=p_approval and candidate_id=c.id and package_id=p.id;
 select * into v from public.cc_availability where id=p_availability and candidate_id=c.id;
 if c.status='do_not_use' or c.unsubscribed then issues=array_append(issues,'Candidate restriction requires review');end if;
 if exists(select 1 from public.candidate_complex_care where candidate_id=c.id and interest='not_interested') then issues=array_append(issues,'Candidate has declined complex care');end if;
 if p.id is null or not p.active or s.closed then issues=array_append(issues,'Package or shift closed');end if;
 if a.id is null or a.revoked or least(a.clinical_until,a.compliance_until)<s.ends_at then issues=array_append(issues,'Current package clinical and compliance approval required through shift end');end if;
 if v.id is null or v.withdrawn or v.starts_at>s.starts_at or v.ends_at<s.ends_at or v.confirmed_at<now()-interval '7 days' then issues=array_append(issues,'Availability covering the full shift must be confirmed within 7 days');end if;
 if exists(select 1 from public.cc_bookings b join public.cc_shifts other on other.id=b.shift_id where b.candidate_id=c.id and b.status<>'cancelled' and b.id is distinct from p_ignore_booking and other.starts_at<s.ends_at and other.ends_at>s.starts_at) then issues=array_append(issues,'Overlapping booking');end if;
 return issues;
end$$;
revoke all on function public.cc_booking_issues(uuid,uuid,uuid,uuid,uuid) from public,anon;
grant execute on function public.cc_booking_issues(uuid,uuid,uuid,uuid,uuid) to authenticated;

create function public.cc_guard_booking() returns trigger language plpgsql security invoker set search_path='' as $$
declare s public.cc_shifts;issues text[];
begin
 if auth.uid() is null or not public.can_access_candidate_sector('nursing_urgent') then raise exception 'Urgent Nursing access required';end if;
 select * into s from public.cc_shifts where id=new.shift_id for update;
 if s.id is null then raise exception 'Shift unavailable';end if;
 -- Serialise concurrent bookings for the same nurse as well as the same shift.
 perform 1 from public.candidates where id=new.candidate_id and sector='nursing_urgent' for update;
 if not found then raise exception 'Candidate unavailable';end if;
 if tg_op='INSERT' then
  if new.status<>'booked' or s.starts_at<=now() then raise exception 'Only future shifts can be booked';end if;
  perform 1 from public.cc_packages where id=s.package_id for share;
  perform 1 from public.cc_package_approvals where id=new.approval_id for share;
  perform 1 from public.cc_availability where id=new.availability_id for share;
  issues=public.cc_booking_issues(new.shift_id,new.candidate_id,new.approval_id,new.availability_id);
  if cardinality(issues)>0 then raise exception '%',array_to_string(issues,'; ');end if;
 else
  if old.status<>'booked' or new.status not in ('cancelled','completed') or length(trim(new.outcome_note))=0 then raise exception 'Record a cancellation or completion with an outcome note';end if;
  if new.status='completed' and s.ends_at>now() then raise exception 'A shift cannot be completed before it ends';end if;
  new.updated_by=auth.uid();new.updated_at=now();
 end if;
 return new;
end$$;
revoke all on function public.cc_guard_booking() from public,anon,authenticated;
create trigger cc_booking_guard before insert or update on public.cc_bookings for each row execute function public.cc_guard_booking();

create function public.cc_shift_shortlist(p_shift uuid,p_search text default '') returns jsonb language sql stable security invoker set search_path='' as $$
 with selected as (select * from public.cc_shifts where id=p_shift), matched as (
 select c.id,c.first_name,c.last_name,c.town,c.postcode,a.id approval_id,v.id availability_id,
 public.cc_booking_issues(s.id,c.id,a.id,v.id) issues
 from selected s join public.candidates c on c.sector='nursing_urgent' and (c.specialty in ('ITU COMPLEX CARE','ITU / Critical Care','Paediatrics') or exists(select 1 from public.candidate_complex_care p where p.candidate_id=c.id))
 left join lateral(select x.id from public.cc_package_approvals x where x.candidate_id=c.id and x.package_id=s.package_id and not x.revoked order by least(x.clinical_until,x.compliance_until) desc limit 1) a on true
 left join lateral(select x.id from public.cc_availability x where x.candidate_id=c.id and not x.withdrawn and x.starts_at<=s.starts_at and x.ends_at>=s.ends_at order by x.confirmed_at desc limit 1) v on true
 where p_search='' or strpos(lower(concat_ws(' ',c.first_name,c.last_name,c.email)),lower(p_search))>0
 ), page as(select * from matched order by cardinality(issues),last_name,first_name,id limit 50)
 select jsonb_build_object('total',(select count(*) from matched),'eligible',(select count(*) from matched where cardinality(issues)=0),'rows',coalesce((select jsonb_agg(to_jsonb(page)) from page),'[]'::jsonb));
$$;
revoke all on function public.cc_shift_shortlist(uuid,text) from public,anon;
grant execute on function public.cc_shift_shortlist(uuid,text) to authenticated;
