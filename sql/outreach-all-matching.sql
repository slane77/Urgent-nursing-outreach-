CREATE OR REPLACE FUNCTION public.queue_outreach_mailshot(p_id uuid, p_audience text, p_template uuid, p_recipients uuid[], p_options jsonb DEFAULT '{}'::jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
 if coalesce(cardinality(p_recipients),0)=0 then raise exception 'Choose at least one recipient'; end if;
 if array_position(p_recipients,null) is not null then raise exception 'Invalid recipient'; end if;
 select array_agg(distinct x) into ids from unnest(p_recipients) x;
 select * into t from public.templates where id=p_template;
 if not found then raise exception 'Template not found'; end if;
 if p_audience='candidates' then
  if (select count(*) from public.candidates c where c.id=any(ids) and (prof.role='admin' or c.sector=any(coalesce(prof.candidate_sectors,'{}')))) <> cardinality(ids) then raise exception 'Candidate missing or outside your permitted sectors'; end if;
 else
  if coalesce(p_options->>'source','') not in ('gp_surgery','children_homes','agency','private_theatre','ahp','nhs_scotland','hse','care_home','bms','sterile','nhs_staffbank','camhs','anp','enp','foi','hcp') then raise exception 'Choose one assigned contact database; all-database sending is disabled'; end if;
  if coalesce(prof.role,'')<>'admin' and not ((p_options->>'source')=any(coalesce(prof.allowed_sources,'{}'))) then raise exception 'No sending access to this database'; end if;
  if t.name ~* '^GP Surgery' and p_options->>'source'<>'gp_surgery' then raise exception 'GP Surgery templates require the GP Surgeries database'; end if;
  if (select count(*) from public.contacts c where c.id=any(ids) and c.status in ('lead','live') and c.email like '%@%' and (p_options->>'source'<>'hcp' or (c.status in ('lead','live') and c.hcp_outreach_status='ready')) and public.outreach_contact_matches_source(c,p_options->>'source',p_options->>'subSource')) <> cardinality(ids) then raise exception 'Every selected contact must belong to the chosen database and be emailable; HCP contacts must be qualified with no CQC or procurement hold'; end if;
 end if;
 insert into public.outreach_mailshots(id,owner_id,audience,template_name,payload)
 values(p_id,u,p_audience,t.name,jsonb_build_object('templateId',p_template,'template',jsonb_build_object('subject',t.subject,'body',t.body),'source',p_options->>'source','subSource',p_options->>'subSource','jobDetails',p_options->'jobDetails'));
 insert into public.outreach_mailshot_items(mailshot_id,recipient_id) select p_id,x from unnest(ids) x;
 return p_id;
end $function$;

revoke all on function public.queue_outreach_mailshot(uuid,text,uuid,uuid[],jsonb) from public,anon;
grant execute on function public.queue_outreach_mailshot(uuid,text,uuid,uuid[],jsonb) to authenticated;

