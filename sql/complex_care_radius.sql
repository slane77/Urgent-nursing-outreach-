-- Adds a separate RPC; existing searches remain available.
create function public.search_complex_care_radius(p_search text default '',p_experience text default '',p_interest text default '',p_skills text[] default '{}',p_all_skills boolean default true,p_locations text[] default '{}',p_offset integer default 0,p_lat double precision default null,p_lng double precision default null,p_radius double precision default null)
returns jsonb language sql stable security invoker set search_path='' as $$
 with matched as (
 select c.id,c.first_name,c.last_name,c.email,c.phone,c.town,c.county,c.postcode,c.status,c.unsubscribed,c.geo_precision,
 case when c.lat is null or c.lng is null or p_lat is null or p_lng is null then null else 3958.8 * acos(least(1.0,greatest(-1.0,cos(radians(p_lat))*cos(radians(c.lat))*cos(radians(c.lng)-radians(p_lng))+sin(radians(p_lat))*sin(radians(c.lat))))) end as distance_miles,
 to_jsonb(p) as complex_care,
 exists(select 1 from public.complex_care_responses r where r.candidate_id=c.id and r.review_status='pending') as pending_contact
 from public.candidates c left join public.candidate_complex_care p on p.candidate_id=c.id
 where c.sector='nursing_urgent' and (c.specialty='ITU COMPLEX CARE' or p.candidate_id is not null)
 and (p_search='' or strpos(lower(concat_ws(' ',c.first_name,c.last_name,c.email,c.phone)),lower(p_search))>0)
 and (p_experience='' or (p_experience='experienced' and p.experience in ('current','previous')) or p.experience=p_experience or (p_experience='no_response' and p.candidate_id is null))
 and (p_interest='' or p.interest=p_interest)
 and (cardinality(p_skills)=0 or case when p_all_skills then p.skills @> p_skills else p.skills && p_skills end)
 and (cardinality(p_locations)=0 or exists(select 1 from unnest(p_locations) loc where length(trim(loc))>0 and
 (strpos(lower(coalesce(c.town,'')),lower(trim(loc)))>0 or strpos(lower(coalesce(c.county,'')),lower(trim(loc)))>0
 or replace(lower(coalesce(c.postcode,'')),' ','') like replace(lower(trim(loc)),' ','')||'%')))
 ), within_radius as (select * from matched where (p_lat is null and p_lng is null and p_radius is null) or (p_lat between -90 and 90 and p_lng between -180 and 180 and p_radius between 1 and 100 and distance_miles is not null and distance_miles<=p_radius)), page as (select * from within_radius order by distance_miles asc nulls last, (complex_care->>'experience' in ('current','previous')) desc nulls last,last_name,first_name,id limit 50 offset greatest(0,p_offset))
 select jsonb_build_object('unmapped',(select count(*) from matched where p_lat is not null and distance_miles is null),'total',(select count(*) from within_radius),'rows',coalesce((select jsonb_agg(to_jsonb(page)) from page),'[]'::jsonb));
$$;
revoke all on function public.search_complex_care_radius(text,text,text,text[],boolean,text[],integer,double precision,double precision,double precision) from public,anon;
grant execute on function public.search_complex_care_radius(text,text,text,text[],boolean,text[],integer,double precision,double precision,double precision) to authenticated;
