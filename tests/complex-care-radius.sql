begin;
select set_config('request.jwt.claim.sub',(select user_id::text from public.user_profiles where role='admin' limit 1),true);
select set_config('cc.radius_key','radius-test-'||gen_random_uuid()::text,true);
insert into public.candidates(first_name,last_name,sector,specialty,status,unsubscribed,lat,lng,geo_precision)
select current_setting('cc.radius_key'),x.name,'nursing_urgent','ITU COMPLEX CARE','do_not_use',true,x.lat,x.lng,x.precision
from (values('Origin',51.5::double precision,0::double precision,'postcode'),('Near',51.55,0,'town'),('Far',52.5,0,'postcode'),('Unmapped',null,null,null)) x(name,lat,lng,precision);
insert into public.candidate_complex_care(candidate_id,interest,experience,skills,population,contact_preference)
select id,'now','current',array['tracheostomy','invasive_ventilation'],'adults','email' from public.candidates where first_name=current_setting('cc.radius_key') and last_name='Near';
set local role authenticated;
do $$declare r jsonb;begin
 r=public.search_complex_care_radius(p_search=>current_setting('cc.radius_key'));
 if (r->>'total')::int<>4 then raise exception 'No-radius search omitted records';end if;
 r=public.search_complex_care_radius(p_search=>current_setting('cc.radius_key'),p_lat=>51.5,p_lng=>0,p_radius=>10);
 if (r->>'total')::int<>2 or (r->>'unmapped')::int<>1 then raise exception 'Radius or missing-location count incorrect';end if;
 if r->'rows'->0->>'last_name'<>'Origin' then raise exception 'Distance sorting incorrect';end if;
 r=public.search_complex_care_radius(p_search=>current_setting('cc.radius_key'),p_lat=>51.5,p_lng=>0,p_radius=>1);
 if (r->>'total')::int<>1 then raise exception 'Slider threshold failed';end if;
 r=public.search_complex_care_radius(p_search=>current_setting('cc.radius_key'),p_experience=>'experienced',p_skills=>array['tracheostomy','invasive_ventilation'],p_lat=>51.5,p_lng=>0,p_radius=>10);
 if (r->>'total')::int<>1 or r->'rows'->0->>'last_name'<>'Near' then raise exception 'Combined radius / skill filter failed';end if;
end$$;
reset role;
select set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
set local role authenticated;
do $$begin
 if (public.search_complex_care_radius(p_search=>current_setting('cc.radius_key'),p_lat=>51.5,p_lng=>0,p_radius=>100)->>'total')::int<>0 then raise exception 'Unauthorised radius access';end if;
end$$;
reset role;
rollback;
select 'Radius, sorting, missing-location, combined skills and access tests passed; fixtures rolled back' as result;
