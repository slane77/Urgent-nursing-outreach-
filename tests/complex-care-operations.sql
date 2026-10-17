-- Synthetic transaction only. No real nurse approvals or shifts are created.
begin;
select set_config('request.jwt.claim.sub',(select user_id::text from public.user_profiles where role='admin' limit 1),true);
select set_config('ops.candidate',gen_random_uuid()::text,true);
insert into public.candidates(id,first_name,last_name,email,sector,specialty,status,unsubscribed) values(current_setting('ops.candidate')::uuid,'Synthetic','Operations test','ops-test@example.invalid','nursing_urgent','Paediatrics','requires_update',false);
create function pg_temp.expect_failure(q text,pattern text) returns void language plpgsql as $$begin
 begin execute q;exception when others then if sqlerrm ~* pattern then return;else raise;end if;end;
 raise exception 'Expected failure not raised: %',pattern;
end$$;
set local role authenticated;
with p as(insert into public.cc_packages(provider,reference,postcode,population,skills,requirements) values('Synthetic provider','OPS TEST','CM1 1AA','adults',array['tracheostomy'],'Controlled plan TEST; tracheostomy competency required') returning id) select set_config('ops.package',id::text,true) from p;
with s as(insert into public.cc_shifts(package_id,starts_at,ends_at,request_reference,pay_rate,charge_rate) values(current_setting('ops.package')::uuid,now()+interval '1 day',now()+interval '1 day 10 hours','TEST REQUEST',30,45) returning id) select set_config('ops.shift',id::text,true) from s;
with s as(insert into public.cc_shifts(package_id,starts_at,ends_at,request_reference,pay_rate,charge_rate) values(current_setting('ops.package')::uuid,now()+interval '1 day 2 hours',now()+interval '1 day 8 hours','TEST OVERLAP',30,45) returning id) select set_config('ops.overlap',id::text,true) from s;
with a as(insert into public.cc_package_approvals(candidate_id,package_id,clinical_approver,clinical_reference,clinical_until,compliance_reviewer,compliance_reference,compliance_until,provider_reference) values(current_setting('ops.candidate')::uuid,current_setting('ops.package')::uuid,'Synthetic clinician','TEST CLINICAL',now()+interval '10 days','Synthetic compliance','TEST COMPLIANCE',now()+interval '10 days','TEST ACCEPTANCE') returning id) select set_config('ops.approval',id::text,true) from a;
with v as(insert into public.cc_availability(candidate_id,starts_at,ends_at,confirmed_at,confirmation) values(current_setting('ops.candidate')::uuid,now()+interval '1 day',now()+interval '2 days',now()-interval '8 days','TEST STALE') returning id) select set_config('ops.stale',id::text,true) from v;
select pg_temp.expect_failure(format('insert into public.cc_bookings(shift_id,candidate_id,approval_id,availability_id,nurse_confirmation,provider_confirmation) values(%L,%L,%L,%L,''TEST'',''TEST'')',current_setting('ops.shift'),current_setting('ops.candidate'),current_setting('ops.approval'),current_setting('ops.stale')),'within 7 days');
with v as(insert into public.cc_availability(candidate_id,starts_at,ends_at,confirmation) values(current_setting('ops.candidate')::uuid,now()+interval '1 day',now()+interval '2 days','TEST FRESH') returning id) select set_config('ops.availability',id::text,true) from v;
do $$declare r jsonb;begin
 r=public.cc_shift_shortlist(current_setting('ops.shift')::uuid,'ops-test@example.invalid');
 if (r->>'eligible')::int<>1 then raise exception 'Eligible shortlist failed: %',r;end if;
end$$;
reset role;
select set_config('request.jwt.claim.sub',(select user_id::text from public.user_profiles where role='user' and 'nursing_urgent'=any(candidate_sectors) limit 1),true);
set local role authenticated;
select pg_temp.expect_failure(format('insert into public.cc_package_approvals(candidate_id,package_id,clinical_approver,clinical_reference,clinical_until,compliance_reviewer,compliance_reference,compliance_until,provider_reference) values(%L,%L,''TEST'',''TEST'',now()+interval ''10 days'',''TEST'',''TEST'',now()+interval ''10 days'',''TEST'')',current_setting('ops.candidate'),current_setting('ops.package')),'administrator|row.level security');
with b as(insert into public.cc_bookings(shift_id,candidate_id,approval_id,availability_id,nurse_confirmation,provider_confirmation) values(current_setting('ops.shift')::uuid,current_setting('ops.candidate')::uuid,current_setting('ops.approval')::uuid,current_setting('ops.availability')::uuid,'TEST NURSE ACCEPTANCE','TEST PROVIDER ACCEPTANCE') returning id) select set_config('ops.booking',id::text,true) from b;
select pg_temp.expect_failure(format('insert into public.cc_bookings(shift_id,candidate_id,approval_id,availability_id,nurse_confirmation,provider_confirmation) values(%L,%L,%L,%L,''TEST'',''TEST'')',current_setting('ops.overlap'),current_setting('ops.candidate'),current_setting('ops.approval'),current_setting('ops.availability')),'Overlapping booking');
select pg_temp.expect_failure(format('update public.cc_bookings set status=''completed'',outcome_note=''TEST'' where id=%L',current_setting('ops.booking')),'before it ends');
select pg_temp.expect_failure(format('update public.cc_shifts set closed=true where id=%L',current_setting('ops.shift')),'Cancel the active booking');
select pg_temp.expect_failure(format('update public.cc_packages set requirements=''changed'' where id=%L',current_setting('ops.package')),'permission denied');
select pg_temp.expect_failure(format('update public.cc_bookings set created_by=gen_random_uuid() where id=%L',current_setting('ops.booking')),'permission denied');
update public.cc_availability set withdrawn=true where id=current_setting('ops.availability')::uuid;
do $$begin
 if cardinality(public.cc_booking_issues(current_setting('ops.shift')::uuid,current_setting('ops.candidate')::uuid,current_setting('ops.approval')::uuid,current_setting('ops.availability')::uuid,current_setting('ops.booking')::uuid))=0 then raise exception 'Withdrawal failed to flag booking';end if;
end$$;
update public.cc_bookings set status='cancelled',outcome_note='TEST CANCELLATION' where id=current_setting('ops.booking')::uuid;
select pg_temp.expect_failure(format('update public.cc_bookings set status=''booked'' where id=%L',current_setting('ops.booking')),'Record a cancellation');
reset role;
select set_config('request.jwt.claim.sub',(select user_id::text from public.user_profiles where role='admin' limit 1),true);
set local role authenticated;
update public.cc_package_approvals set revoked=true,revocation_reason='TEST REVOCATION' where id=current_setting('ops.approval')::uuid;
select pg_temp.expect_failure(format('insert into public.cc_bookings(shift_id,candidate_id,approval_id,availability_id,nurse_confirmation,provider_confirmation) values(%L,%L,%L,%L,''TEST'',''TEST'')',current_setting('ops.shift'),current_setting('ops.candidate'),current_setting('ops.approval'),current_setting('ops.availability')),'approval required');
reset role;
select set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
set local role authenticated;
do $$begin
 if exists(select 1 from public.cc_packages) or exists(select 1 from public.cc_availability) or exists(select 1 from public.cc_package_approvals) or exists(select 1 from public.cc_shifts) or exists(select 1 from public.cc_bookings) then raise exception 'Unauthorised cross sector access';end if;
 if (public.cc_shift_shortlist(current_setting('ops.shift')::uuid)->>'total')::int<>0 then raise exception 'Shortlist leak';end if;
end$$;
select pg_temp.expect_failure(format('insert into public.cc_availability(candidate_id,starts_at,ends_at,confirmation) values(%L,now(),now()+interval ''1 day'',''TEST'')',current_setting('ops.candidate')),'access required');
reset role;
set local role anon;
select pg_temp.expect_failure('select * from public.cc_packages','permission denied');
select pg_temp.expect_failure('select public.cc_shift_shortlist(gen_random_uuid())','permission denied');
reset role;
rollback;
select 'Operations workflow and access assertions passed; fixtures rolled back' as result;
