-- Recruitment progress is not clinical or package approval.
alter table public.candidate_complex_care add column screening_details jsonb not null default '{}' check(jsonb_typeof(screening_details)='object' and octet_length(screening_details::text)<=8000);
create table public.complex_care_screening_events (
 id uuid primary key default gen_random_uuid(),
 candidate_id uuid not null references public.candidates(id) on delete cascade,
 stage text not null check(stage in ('to_contact','screening','compliance_review','clinical_review','paused')),
 follow_up date,
 notes text not null default '' check(length(notes)<=1000),
 created_by uuid not null default auth.uid(),
 created_at timestamptz not null default now()
);
create index on public.complex_care_screening_events(candidate_id,created_at desc,id desc);
alter table public.complex_care_screening_events enable row level security;
revoke all on public.complex_care_screening_events from public,anon,authenticated;
grant select on public.complex_care_screening_events to authenticated;
grant insert(candidate_id,stage,follow_up,notes) on public.complex_care_screening_events to authenticated;
grant all on public.complex_care_screening_events to service_role;
create policy cc_screen_read on public.complex_care_screening_events for select to authenticated using
 (exists(select 1 from public.candidates c where c.id=candidate_id and c.sector='nursing_urgent' and public.can_access_candidate_sector(c.sector)));
create policy cc_screen_insert on public.complex_care_screening_events for insert to authenticated with check
 (created_by=auth.uid() and exists(select 1 from public.candidates c where c.id=candidate_id and c.sector='nursing_urgent' and public.can_access_candidate_sector(c.sector)));
create or replace function public.submit_complex_care(p_hash text,p_answers jsonb,p_contact jsonb)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare inv public.complex_care_invitations; c public.candidates; rid uuid; skills text[]; shifts text[];
begin
 select * into inv from public.complex_care_invitations where token_hash=p_hash for update;
 if not found or inv.revoked or inv.expires_at<=now() then raise exception 'Invalid or expired invitation'; end if;
 if inv.submitted_at is not null then return jsonb_build_object('ok',true,'already_submitted',true); end if;
 select * into c from public.candidates where id=inv.candidate_id for update;
 if not found or c.sector<>'nursing_urgent' or c.status='do_not_use' or c.unsubscribed then raise exception 'Invitation unavailable'; end if;
 if jsonb_typeof(p_answers)<>'object' or jsonb_typeof(p_contact)<>'object' then raise exception 'Invalid response'; end if;
 if exists(select 1 from jsonb_object_keys(p_contact) k where k not in ('email','phone','town','postcode')) then raise exception 'Invalid contact field'; end if;
 select coalesce(array_agg(v),'{}') into skills from jsonb_array_elements_text(p_answers->'skills') v;
 select coalesce(array_agg(v),'{}') into shifts from jsonb_array_elements_text(p_answers->'shifts') v;
 insert into public.complex_care_responses(invitation_id,candidate_id,answers,proposed_contact,original_contact,review_status)
 values(inv.id,c.id,p_answers,p_contact,jsonb_build_object('email',c.email,'phone',c.phone,'town',c.town,'postcode',c.postcode),
 case when p_contact='{}'::jsonb then 'not_needed' else 'pending' end) returning id into rid;
 insert into public.candidate_complex_care(candidate_id,interest,experience,skills,population,shifts,availability,preferred_locations,travel_miles,contact_preference,notes,screening_details)
 values(c.id,p_answers->>'interest',p_answers->>'experience',skills,p_answers->>'population',shifts,
 coalesce(p_answers->>'availability',''),coalesce(p_answers->>'preferred_locations',''),(p_answers->>'travel_miles')::integer,p_answers->>'contact_preference',coalesce(p_answers->>'notes',''),coalesce(p_answers->'screening_details','{}'::jsonb))
 on conflict(candidate_id) do update set interest=excluded.interest,experience=excluded.experience,skills=excluded.skills,population=excluded.population,
 shifts=excluded.shifts,availability=excluded.availability,preferred_locations=excluded.preferred_locations,travel_miles=excluded.travel_miles,
 contact_preference=excluded.contact_preference,notes=excluded.notes,screening_details=excluded.screening_details,responded_at=now();
 update public.complex_care_invitations set submitted_at=now() where id=inv.id;
 return jsonb_build_object('ok',true);
end $$;
revoke all on function public.submit_complex_care(text,jsonb,jsonb) from public,anon,authenticated;
grant execute on function public.submit_complex_care(text,jsonb,jsonb) to service_role;

-- Adds a separate RPC; existing searches remain available.
create function public.search_complex_care_bank(p_search text default '',p_experience text default '',p_interest text default '',p_skills text[] default '{}',p_all_skills boolean default true,p_locations text[] default '{}',p_offset integer default 0,p_lat double precision default null,p_lng double precision default null,p_radius double precision default null,p_source text default '',p_stage text default '',p_eligible boolean default true,p_due boolean default false,p_population text default '',p_shift text default '',p_notice text default '')
returns jsonb language sql stable security invoker set search_path='' as $$
 with matched as (
 select c.id,c.first_name,c.last_name,c.email,c.phone,c.town,c.county,c.postcode,c.status,c.unsubscribed,c.geo_precision,c.specialty,to_jsonb(s) as screening,
 case when c.lat is null or c.lng is null or p_lat is null or p_lng is null then null else 3958.8 * acos(least(1.0,greatest(-1.0,cos(radians(p_lat))*cos(radians(c.lat))*cos(radians(c.lng)-radians(p_lng))+sin(radians(p_lat))*sin(radians(c.lat))))) end as distance_miles,
 to_jsonb(p) as complex_care,
 exists(select 1 from public.complex_care_responses r where r.candidate_id=c.id and r.review_status='pending') as pending_contact
 from public.candidates c left join public.candidate_complex_care p on p.candidate_id=c.id left join lateral (select e.* from public.complex_care_screening_events e where e.candidate_id=c.id order by e.created_at desc,e.id desc limit 1) s on true
 where c.sector='nursing_urgent' and (c.specialty in ('ITU COMPLEX CARE','ITU / Critical Care','Paediatrics') or p.candidate_id is not null)
 and (not p_eligible or (c.status<>'do_not_use' and not c.unsubscribed))
 and (p_source='' or (p_source='core' and c.specialty='ITU COMPLEX CARE') or (p_source='wider' and c.specialty in ('ITU / Critical Care','Paediatrics')) or (p_source='responders' and p.candidate_id is not null))
 and (p_stage='' or coalesce(s.stage,'to_contact')=p_stage)
 and (not p_due or s.follow_up<=current_date)
 and (p_population='' or p.screening_details->>'population_experience'=p_population or p.screening_details->>'population_experience'='both')
 and (p_shift='' or p_shift=any(p.shifts))
 and (p_notice='' or p.screening_details->>'notice'=p_notice)
 and (p_search='' or strpos(lower(concat_ws(' ',c.first_name,c.last_name,c.email,c.phone)),lower(p_search))>0)
 and (p_experience='' or (p_experience='experienced' and p.experience in ('current','previous')) or p.experience=p_experience or (p_experience='no_response' and p.candidate_id is null))
 and (p_interest='' or p.interest=p_interest)
 and (cardinality(p_skills)=0 or case when p_all_skills then p.skills @> p_skills else p.skills && p_skills end)
 and (cardinality(p_locations)=0 or exists(select 1 from unnest(p_locations) loc where length(trim(loc))>0 and
 (strpos(lower(coalesce(c.town,'')),lower(trim(loc)))>0 or strpos(lower(coalesce(c.county,'')),lower(trim(loc)))>0
 or replace(lower(coalesce(c.postcode,'')),' ','') like replace(lower(trim(loc)),' ','')||'%')))
 ), within_radius as (select * from matched where (p_lat is null and p_lng is null and p_radius is null) or (p_lat between -90 and 90 and p_lng between -180 and 180 and p_radius between 1 and 100 and distance_miles is not null and distance_miles<=p_radius)), page as (select * from within_radius order by distance_miles asc nulls last, (complex_care->>'experience' in ('current','previous')) desc nulls last,last_name,first_name,id limit 50 offset greatest(0,p_offset))
 select jsonb_build_object('stages',(select jsonb_object_agg(stage,n) from (select coalesce(screening->>'stage','to_contact') stage,count(*) n from within_radius group by 1) counts),'unmapped',(select count(*) from matched where p_lat is not null and distance_miles is null),'total',(select count(*) from within_radius),'rows',coalesce((select jsonb_agg(to_jsonb(page)) from page),'[]'::jsonb));
$$;
revoke all on function public.search_complex_care_bank(text,text,text,text[],boolean,text[],integer,double precision,double precision,double precision,text,text,boolean,boolean,text,text,text) from public,anon;
grant execute on function public.search_complex_care_bank(text,text,text,text[],boolean,text[],integer,double precision,double precision,double precision,text,text,boolean,boolean,text,text,text) to authenticated;
