-- Additive release. No candidate contact or sending-status backfill.
create table public.complex_care_invitations (
 id uuid primary key default gen_random_uuid(),
 candidate_id uuid not null references public.candidates(id) on delete cascade,
 token_hash text not null unique check (token_hash ~ '^[a-f0-9]{64}$'),
 created_by uuid not null default auth.uid(),
 created_at timestamptz not null default now(),
 expires_at timestamptz not null default now() + interval '30 days',
 revoked boolean not null default false,
 submitted_at timestamptz,
 check (expires_at > created_at and expires_at <= created_at + interval '30 days')
);
create index on public.complex_care_invitations(candidate_id);
create table public.candidate_complex_care (
 candidate_id uuid primary key references public.candidates(id) on delete cascade,
 interest text not null check (interest in ('now','later','discuss','not_interested')),
 experience text not null check (experience in ('current','previous','none','unknown')),
 skills text[] not null default '{}',
 population text not null check (population in ('adults','children','both','unsure','unknown')),
 shifts text[] not null default '{}',
 availability text not null default '',
 preferred_locations text not null default '',
 travel_miles integer check (travel_miles between 0 and 500),
 contact_preference text not null check (contact_preference in ('phone_email','phone','email','none')),
 notes text not null default '',
 responded_at timestamptz not null default now(),
 check (skills <@ array['tracheostomy','invasive_ventilation','noninvasive_ventilation','suction','peg','neurological','seizures','home_care']::text[]),
 check (shifts <@ array['days','nights','weekends']::text[])
);
create index on public.candidate_complex_care using gin(skills);
create index on public.candidate_complex_care(experience,interest);
create table public.complex_care_responses (
 id uuid primary key default gen_random_uuid(),
 invitation_id uuid not null unique references public.complex_care_invitations(id),
 candidate_id uuid not null references public.candidates(id) on delete cascade,
 answers jsonb not null,
 proposed_contact jsonb not null default '{}',
 original_contact jsonb not null,
 review_status text not null check (review_status in ('not_needed','pending','accepted','rejected')),
 submitted_at timestamptz not null default now(),
 reviewed_at timestamptz,
 reviewed_by uuid
);
create index on public.complex_care_responses(candidate_id,submitted_at desc);
alter table public.complex_care_invitations enable row level security;
alter table public.candidate_complex_care enable row level security;
alter table public.complex_care_responses enable row level security;
revoke all on public.complex_care_invitations,public.candidate_complex_care,public.complex_care_responses from anon,authenticated;
grant select,insert on public.complex_care_invitations to authenticated;
grant update(revoked) on public.complex_care_invitations to authenticated;
grant select on public.candidate_complex_care,public.complex_care_responses to authenticated;
grant update(review_status,reviewed_at,reviewed_by) on public.complex_care_responses to authenticated;
grant all on public.complex_care_invitations,public.candidate_complex_care,public.complex_care_responses to service_role;
create policy cc_inv_read on public.complex_care_invitations for select to authenticated using
 (exists(select 1 from public.candidates c where c.id=candidate_id and public.can_access_candidate_sector(c.sector)));
create policy cc_inv_insert on public.complex_care_invitations for insert to authenticated with check
 (created_by=auth.uid() and submitted_at is null and not revoked and exists(select 1 from public.candidates c where c.id=candidate_id and c.sector='nursing_urgent' and c.status<>'do_not_use' and not c.unsubscribed and public.can_access_candidate_sector(c.sector)));
create policy cc_inv_revoke on public.complex_care_invitations for update to authenticated using
 (exists(select 1 from public.candidates c where c.id=candidate_id and public.can_access_candidate_sector(c.sector))) with check
 (exists(select 1 from public.candidates c where c.id=candidate_id and public.can_access_candidate_sector(c.sector)));
create policy cc_profile_read on public.candidate_complex_care for select to authenticated using
 (exists(select 1 from public.candidates c where c.id=candidate_id and public.can_access_candidate_sector(c.sector)));
create policy cc_response_read on public.complex_care_responses for select to authenticated using
 (exists(select 1 from public.candidates c where c.id=candidate_id and public.can_access_candidate_sector(c.sector)));
create policy cc_response_review on public.complex_care_responses for update to authenticated using
 (exists(select 1 from public.candidates c where c.id=candidate_id and public.can_access_candidate_sector(c.sector))) with check
 (reviewed_by=auth.uid() and exists(select 1 from public.candidates c where c.id=candidate_id and public.can_access_candidate_sector(c.sector)));

-- Only the token-authenticated edge endpoint may call this atomic writer.
create function public.submit_complex_care(p_hash text,p_answers jsonb,p_contact jsonb)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare inv public.complex_care_invitations; c public.candidates; rid uuid; skills text[]; shifts text[];
begin
 select * into inv from public.complex_care_invitations where token_hash=p_hash for update;
 if not found or inv.revoked or inv.expires_at<=now() then raise exception 'Invalid or expired invitation'; end if;
 if inv.submitted_at is not null then return jsonb_build_object('ok',true,'already_submitted',true); end if;
 select * into c from public.candidates where id=inv.candidate_id for update;
 if not found or c.sector<>'nursing_urgent' then raise exception 'Invitation unavailable'; end if;
 if jsonb_typeof(p_answers)<>'object' or jsonb_typeof(p_contact)<>'object' then raise exception 'Invalid response'; end if;
 if exists(select 1 from jsonb_object_keys(p_contact) k where k not in ('email','phone','town','postcode')) then raise exception 'Invalid contact field'; end if;
 select coalesce(array_agg(v),'{}') into skills from jsonb_array_elements_text(p_answers->'skills') v;
 select coalesce(array_agg(v),'{}') into shifts from jsonb_array_elements_text(p_answers->'shifts') v;
 insert into public.complex_care_responses(invitation_id,candidate_id,answers,proposed_contact,original_contact,review_status)
 values(inv.id,c.id,p_answers,p_contact,jsonb_build_object('email',c.email,'phone',c.phone,'town',c.town,'postcode',c.postcode),
 case when p_contact='{}'::jsonb then 'not_needed' else 'pending' end) returning id into rid;
 insert into public.candidate_complex_care(candidate_id,interest,experience,skills,population,shifts,availability,preferred_locations,travel_miles,contact_preference,notes)
 values(c.id,p_answers->>'interest',p_answers->>'experience',skills,p_answers->>'population',shifts,
 coalesce(p_answers->>'availability',''),coalesce(p_answers->>'preferred_locations',''),(p_answers->>'travel_miles')::integer,p_answers->>'contact_preference',coalesce(p_answers->>'notes',''))
 on conflict(candidate_id) do update set interest=excluded.interest,experience=excluded.experience,skills=excluded.skills,population=excluded.population,
 shifts=excluded.shifts,availability=excluded.availability,preferred_locations=excluded.preferred_locations,travel_miles=excluded.travel_miles,
 contact_preference=excluded.contact_preference,notes=excluded.notes,responded_at=now();
 update public.complex_care_invitations set submitted_at=now() where id=inv.id;
 return jsonb_build_object('ok',true);
end $$;
revoke all on function public.submit_complex_care(text,jsonb,jsonb) from public,anon,authenticated;
grant execute on function public.submit_complex_care(text,jsonb,jsonb) to service_role;

-- RLS applies to both response and candidate. Stale proposals never overwrite a newer edit.
create function public.review_complex_care_contact(p_response uuid,p_accept boolean)
returns void language plpgsql security invoker set search_path='' as $$
declare r public.complex_care_responses; c public.candidates; k text; snapshot jsonb;
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 select * into r from public.complex_care_responses where id=p_response for update;
 if not found or r.review_status<>'pending' then raise exception 'No pending review available'; end if;
 select * into c from public.candidates where id=r.candidate_id for update;
 if not found then raise exception 'Candidate unavailable'; end if;
 if p_accept then
  snapshot=jsonb_build_object('email',c.email,'phone',c.phone,'town',c.town,'postcode',c.postcode);
  for k in select jsonb_object_keys(r.proposed_contact) loop
   if snapshot->k is distinct from r.original_contact->k then raise exception 'Contact has changed since this response. Review manually.'; end if;
  end loop;
  update public.candidates set
   email=case when r.proposed_contact?'email' then r.proposed_contact->>'email' else email end,
   phone=case when r.proposed_contact?'phone' then r.proposed_contact->>'phone' else phone end,
   town=case when r.proposed_contact?'town' then r.proposed_contact->>'town' else town end,
   postcode=case when r.proposed_contact?'postcode' then r.proposed_contact->>'postcode' else postcode end,
   lat=case when r.proposed_contact?'postcode' or r.proposed_contact?'town' then null else lat end,
   lng=case when r.proposed_contact?'postcode' or r.proposed_contact?'town' then null else lng end,
   geocoded_at=case when r.proposed_contact?'postcode' or r.proposed_contact?'town' then null else geocoded_at end,
   normalized_postcode=case when r.proposed_contact?'postcode' or r.proposed_contact?'town' then null else normalized_postcode end,
   geo_precision=case when r.proposed_contact?'postcode' or r.proposed_contact?'town' then null else geo_precision end,
   geo_county=case when r.proposed_contact?'postcode' or r.proposed_contact?'town' then null else geo_county end,
   geo_district=case when r.proposed_contact?'postcode' or r.proposed_contact?'town' then null else geo_district end
  where id=c.id;
  if not found then raise exception 'Candidate update not permitted'; end if;
 end if;
 update public.complex_care_responses set review_status=case when p_accept then 'accepted' else 'rejected' end,reviewed_at=now(),reviewed_by=auth.uid() where id=r.id;
end $$;
revoke all on function public.review_complex_care_contact(uuid,boolean) from public,anon;
grant execute on function public.review_complex_care_contact(uuid,boolean) to authenticated;

create function public.search_complex_care(p_search text default '',p_experience text default '',p_interest text default '',p_skills text[] default '{}',p_all_skills boolean default true,p_locations text[] default '{}',p_offset integer default 0)
returns jsonb language sql stable security invoker set search_path='' as $$
 with matched as (
 select c.id,c.first_name,c.last_name,c.email,c.phone,c.town,c.county,c.postcode,c.status,c.unsubscribed,
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
 ), page as (select * from matched order by (complex_care->>'experience' in ('current','previous')) desc nulls last,last_name,first_name,id limit 50 offset greatest(0,p_offset))
 select jsonb_build_object('total',(select count(*) from matched),'rows',coalesce((select jsonb_agg(to_jsonb(page)) from page),'[]'::jsonb));
$$;
revoke all on function public.search_complex_care(text,text,text,text[],boolean,text[],integer) from public,anon;
grant execute on function public.search_complex_care(text,text,text,text[],boolean,text[],integer) to authenticated;
