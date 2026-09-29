-- Executed in a transaction; synthetic records and all changes are rolled back.
begin;
select set_config('request.jwt.claim.sub',(select user_id::text from public.user_profiles where role='admin' limit 1),true);
select set_config('cc.test_id',gen_random_uuid()::text,true);
insert into public.candidates(id,first_name,last_name,email,town,county,postcode,sector,specialty,status,unsubscribed)
values(current_setting('cc.test_id')::uuid,'Synthetic','CC test','cc-test@example.invalid','Chelmsford','Essex','CM1 1AA','nursing_urgent','ITU COMPLEX CARE','available',false);
set local role authenticated;
insert into public.complex_care_invitations(candidate_id,token_hash) values(current_setting('cc.test_id')::uuid,repeat('a',64));
reset role;
set local role service_role;
select public.submit_complex_care(repeat('a',64),'{"interest":"now","experience":"current","skills":["tracheostomy","invasive_ventilation"],"population":"adults","shifts":["nights"],"availability":"now","preferred_locations":"London","travel_miles":30,"contact_preference":"email"}','{"phone":"07000000000"}');
select public.submit_complex_care(repeat('a',64),'{"interest":"not_interested"}','{}');
reset role;
do $$begin
 if (select count(*) from public.complex_care_responses where candidate_id=current_setting('cc.test_id')::uuid)<>1 then raise exception 'Replay created duplicate';end if;
 if (select phone from public.candidates where id=current_setting('cc.test_id')::uuid) is not null then raise exception 'Contact automatically changed';end if;
 if (select interest from public.candidate_complex_care where candidate_id=current_setting('cc.test_id')::uuid)<>'now' then raise exception 'Replay overwrote profile';end if;
end$$;
set local role authenticated;
do $$declare result jsonb;rid uuid;begin
 result=public.search_complex_care('cc-test@example.invalid','experienced','now',array['tracheostomy','invasive_ventilation'],true,array['Essex'],0);
 if (result->>'total')::int<>1 then raise exception 'Combined search failed';end if;
 result=public.search_complex_care('cc-test@example.invalid','','',array['tracheostomy','peg'],true,'{}',0);
 if (result->>'total')::int<>0 then raise exception 'ALL skills failed';end if;
 result=public.search_complex_care('cc-test@example.invalid','','',array['tracheostomy','peg'],false,array['Kent','CM1'],0);
 if (result->>'total')::int<>1 then raise exception 'ANY skills / multiple locations failed';end if;
 result=public.search_complex_care('cc-test@example.invalid','','','{}',true,array['London'],0);
 if (result->>'total')::int<>0 then raise exception 'Preferred work location wrongly used as residence';end if;
 select id into rid from public.complex_care_responses where candidate_id=current_setting('cc.test_id')::uuid;
 perform public.review_complex_care_contact(rid,true);
 if (select phone from public.candidates where id=current_setting('cc.test_id')::uuid)<>'07000000000' then raise exception 'Approval failed';end if;
 if (select status from public.candidates where id=current_setting('cc.test_id')::uuid)<>'available' then raise exception 'Status changed';end if;
end$$;
reset role;
update public.candidates set status='do_not_use',unsubscribed=true where id=current_setting('cc.test_id')::uuid;
set local role authenticated;
do $$begin
 begin
  insert into public.complex_care_invitations(candidate_id,token_hash) values(current_setting('cc.test_id')::uuid,repeat('b',64));
  raise exception 'Suppression bypass';
 exception when insufficient_privilege then null;end;
end$$;
reset role;
select set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
set local role authenticated;
do $$begin
 if (public.search_complex_care('cc-test@example.invalid')->>'total')::int<>0 then raise exception 'Cross-sector leak';end if;
 if exists(select 1 from public.complex_care_responses where candidate_id=current_setting('cc.test_id')::uuid) then raise exception 'Response leak';end if;
 if exists(select 1 from public.complex_care_invitations where candidate_id=current_setting('cc.test_id')::uuid) then raise exception 'Invitation leak';end if;
 begin
  perform public.submit_complex_care(repeat('a',64),'{}','{}');raise exception 'Authenticated submit bypass';
 exception when insufficient_privilege then null;end;
end$$;
reset role;
set local role anon;
do $$begin
 begin perform public.search_complex_care();raise exception 'Anonymous search leak';exception when insufficient_privilege then null;end;
 begin perform public.submit_complex_care(repeat('a',64),'{}','{}');raise exception 'Anonymous submit bypass';exception when insufficient_privilege then null;end;
end$$;
reset role;
rollback;
select 'All complex care database assertions passed; fixtures rolled back' as result;
