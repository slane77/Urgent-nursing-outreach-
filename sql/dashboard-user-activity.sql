-- Aggregate recorded sends without exposing recipient records or changing table access.
create or replace function public.dashboard_user_activity(p_audience text default 'all')
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  report jsonb;
begin
  if auth.uid() is null or not exists (
    select 1 from public.user_profiles where user_id=auth.uid() and role='admin'
  ) then
    raise exception 'Administrator access is required' using errcode='42501';
  end if;
  if p_audience is null or p_audience not in ('all','contacts','candidates') then
    raise exception 'Invalid activity audience' using errcode='22023';
  end if;
  with boundaries as (
    select now() as as_of,
      date_trunc('day',now() at time zone 'Europe/London') at time zone 'Europe/London' as day_start,
      date_trunc('week',now() at time zone 'Europe/London') at time zone 'Europe/London' as week_start,
      date_trunc('month',now() at time zone 'Europe/London') at time zone 'Europe/London' as month_start
  ), sends as (
    select sent_by,sent_at from public.email_sends
    where status='sent' and p_audience in ('all','contacts')
    union all
    select sent_by,created_at as sent_at from public.candidate_sends
    where status='sent' and p_audience in ('all','candidates')
  ), activity as (
    select sent_by,
      count(*) filter(where sent_at>=day_start) as today,
      count(*) filter(where sent_at>=week_start) as this_week,
      count(*) filter(where sent_at>=month_start) as this_month,
      count(*) as all_time,max(sent_at) as last_sent_at
    from sends cross join boundaries where sent_at<=as_of group by sent_by
  ), people as (
    select coalesce(p.user_id,a.sent_by) as user_id,
      coalesce(nullif(trim(p.full_name),''),nullif(p.email,''),
        case when a.sent_by is null then 'Unattributed historical sends' else 'Former or unavailable user' end) as name,
      p.email,coalesce(a.today,0) as today,coalesce(a.this_week,0) as this_week,
      coalesce(a.this_month,0) as this_month,coalesce(a.all_time,0) as all_time,a.last_sent_at,
      p.user_id is null as unattributed
    from public.user_profiles p full join activity a on a.sent_by=p.user_id
  )
  select jsonb_build_object('audience',p_audience,'asOf',now(),'timezone','Europe/London',
    'rows',coalesce(jsonb_agg(to_jsonb(people) order by this_month desc,this_week desc,name,user_id),'[]'::jsonb))
  into report from people;
  return report;
end;
$$;
revoke all on function public.dashboard_user_activity(text) from public,anon;
grant execute on function public.dashboard_user_activity(text) to authenticated;
