-- ============================================================================
--  Day Webster — Candidate Pipeline · Desks & co-pilot (multi-desk)
--  File: candidate-pipeline/sql/18_desks.sql
--  Run AFTER 10–17. Idempotent / additive.
--
--  STATUS: DRAFT — NOT YET APPLIED. For review only.
--
--  Desks are a SEPARATE organisational layer from the discipline/specialty
--  taxonomy. A desk covers a set of specialties (optionally by region), so
--  candidates AUTO-ROUTE to the right desk on qualification. Visibility is
--  SILOED: recruiters see only their desk(s); admins see everything; unassigned
--  candidates are visible to admins (the "to route" queue).
--
--  SAFE BOOTSTRAP: until you populate `staff`, everyone on an authorised domain
--  is treated as admin (sees all) — so applying this never locks anyone out.
--  Siloing switches on once you add staff + desk_members.
-- ============================================================================

-- ── Extra nursing specialties to match the real desks ──────────────────────
insert into candidate.specialties (discipline_id, code, name, sort_order)
select d.id, v.code, v.name, v.so from candidate.disciplines d,
 (values
   ('ward','Ward Nursing',12),('ae','A&E Nursing',13),('itu','ITU/ICU Nursing',14),
   ('hca','Healthcare Assistant',15),('rmn','RMN (Mental Health)',16),
   ('neonatal','Neonatal',32),('paediatrics','Paediatrics',33),
   ('anp','Advanced Nurse Practitioner',42),('enp','Emergency Nurse Practitioner',43)
 ) as v(code,name,so)
where d.code='nursing'
on conflict (discipline_id, code) do nothing;

-- ── Desks ──────────────────────────────────────────────────────────────────
create table if not exists candidate.desks (
  id        uuid primary key default gen_random_uuid(),
  code      text not null unique,
  name      text not null,
  region    text,                       -- informational (routing uses coverage.region)
  active    boolean not null default true,
  created_at timestamptz not null default now()
);

insert into candidate.desks (code, name, region) values
  ('theatres',      'Theatres',                 null),
  ('midwifery',     'Midwifery (+ Neonatal & Paeds)', null),
  ('nursing_north', 'Nursing — North',          'North'),
  ('nursing_south', 'Nursing — South',          'South'),
  ('primary_care',  'Primary Care (ANP/ENP)',   null),
  ('ahp',           'AHP',                      null),
  ('doctors',       'Doctors',                  null),
  ('complex_care',  'Complex Care',             null),
  ('care_homes',    'Care Homes',               null),
  ('childrens',     'Children''s Services',     null),
  ('insurance',     'Insurance — John Williams',null)
on conflict (code) do nothing;

-- ── Coverage rules: (discipline, specialty, region) -> desk ────────────────
create table if not exists candidate.desk_coverage (
  id            uuid primary key default gen_random_uuid(),
  desk_id       uuid not null references candidate.desks(id) on delete cascade,
  discipline_id uuid references candidate.disciplines(id) on delete cascade,
  specialty_id  uuid references candidate.specialties(id) on delete cascade,
  region        text
);

-- nursing specialty-based desks
insert into candidate.desk_coverage (desk_id, discipline_id, specialty_id, region)
select dk.id, d.id, s.id, v.region
from candidate.desks dk
join candidate.disciplines d on d.code = 'nursing'
join (values
  ('theatres',      'theatres',     null), ('theatres',      'theatres_odp', null),
  ('midwifery',     'midwifery',    null), ('midwifery',     'neonatal',     null), ('midwifery','paediatrics',null),
  ('nursing_north', 'ward','North'),('nursing_north','ae','North'),('nursing_north','itu','North'),('nursing_north','hca','North'),('nursing_north','rmn','North'),
  ('nursing_south', 'ward','South'),('nursing_south','ae','South'),('nursing_south','itu','South'),('nursing_south','hca','South'),('nursing_south','rmn','South'),
  ('primary_care',  'primary_care', null), ('primary_care', 'anp', null), ('primary_care','enp',null)
) as v(desk_code, spec_code, region) on v.desk_code = dk.code
join candidate.specialties s on s.discipline_id = d.id and s.code = v.spec_code
on conflict do nothing;

-- discipline-level desks (whole discipline -> one desk)
insert into candidate.desk_coverage (desk_id, discipline_id)
select dk.id, d.id
from candidate.desks dk
join candidate.disciplines d on d.code = dk.code
where dk.code in ('ahp','doctors','complex_care','care_homes','childrens','insurance')
on conflict do nothing;

-- ── Staff (roles) + desk membership ────────────────────────────────────────
create table if not exists candidate.staff (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  full_name  text,
  is_admin   boolean not null default false,
  created_at timestamptz not null default now()
);
create table if not exists candidate.desk_members (
  desk_id   uuid not null references candidate.desks(id) on delete cascade,
  user_id   uuid not null references auth.users(id) on delete cascade,
  role      text not null default 'recruiter',
  primary key (desk_id, user_id)
);

-- ── Attribution on candidates ──────────────────────────────────────────────
alter table candidate.candidates add column if not exists desk_id uuid references candidate.desks(id) on delete set null;
create index if not exists candidates_desk_idx on candidate.candidates (desk_id);

-- ── Role helpers (SECURITY DEFINER) ────────────────────────────────────────
create or replace function candidate.is_admin()
returns boolean language sql stable security definer set search_path = candidate, public as $$
  select coalesce(
    (select s.is_admin from candidate.staff s where s.user_id = auth.uid()),
    not exists (select 1 from candidate.staff)   -- bootstrap: no staff yet => admin
  );
$$;
grant execute on function candidate.is_admin() to authenticated;

create or replace function candidate.my_desk_ids()
returns setof uuid language sql stable security definer set search_path = candidate, public as $$
  select desk_id from candidate.desk_members where user_id = auth.uid();
$$;
grant execute on function candidate.my_desk_ids() to authenticated;

-- ── Routing: pick the best-matching desk for a candidate ───────────────────
create or replace function candidate.desk_for(p_disc uuid, p_spec uuid, p_region text)
returns uuid language sql stable set search_path = candidate, public as $$
  select dc.desk_id
  from candidate.desk_coverage dc
  where (dc.specialty_id  is null or dc.specialty_id  = p_spec)
    and (dc.discipline_id is null or dc.discipline_id = p_disc)
    and (dc.region is null or (p_region is not null and lower(dc.region) = lower(p_region)))
  order by (dc.specialty_id is not null) desc,
           (dc.region is not null) desc,
           (dc.discipline_id is not null) desc
  limit 1;
$$;

-- Auto-route on insert/update when a desk isn't already set.
create or replace function candidate.autoroute()
returns trigger language plpgsql as $$
begin
  if new.desk_id is null and (new.primary_specialty_id is not null or new.discipline_id is not null) then
    new.desk_id := candidate.desk_for(new.discipline_id, new.primary_specialty_id, new.region);
  end if;
  return new;
end;
$$;
drop trigger if exists candidates_autoroute on candidate.candidates;
create trigger candidates_autoroute
  before insert or update of discipline_id, primary_specialty_id, region, desk_id
  on candidate.candidates for each row execute function candidate.autoroute();

-- ── RLS ────────────────────────────────────────────────────────────────────
alter table candidate.desks         enable row level security;
alter table candidate.desk_coverage enable row level security;
alter table candidate.desk_members  enable row level security;
alter table candidate.staff         enable row level security;

-- Reference tables: any authorised staff may read; only admins may change.
do $$
declare t text;
begin
  foreach t in array array['desks','desk_coverage','desk_members','staff'] loop
    execute format('drop policy if exists "auth read %1$s" on candidate.%1$s', t);
    execute format('create policy "auth read %1$s" on candidate.%1$s for select to authenticated using (candidate.is_authorized_user());', t);
    execute format('drop policy if exists "admin write %1$s" on candidate.%1$s', t);
    execute format('create policy "admin write %1$s" on candidate.%1$s for all to authenticated using (candidate.is_authorized_user() and candidate.is_admin()) with check (candidate.is_authorized_user() and candidate.is_admin());', t);
  end loop;
end $$;

-- Candidates: SILOED. Replace the open read/update/delete with desk-scoped ones
-- (insert stays open so anyone can add; the trigger routes to a desk).
drop policy if exists "auth read candidates"   on candidate.candidates;
drop policy if exists "auth update candidates" on candidate.candidates;
drop policy if exists "auth delete candidates" on candidate.candidates;

create policy "desk read candidates" on candidate.candidates for select to authenticated
  using (candidate.is_authorized_user() and (candidate.is_admin() or desk_id in (select candidate.my_desk_ids())));
create policy "desk update candidates" on candidate.candidates for update to authenticated
  using (candidate.is_authorized_user() and (candidate.is_admin() or desk_id in (select candidate.my_desk_ids())))
  with check (candidate.is_authorized_user());
create policy "desk delete candidates" on candidate.candidates for delete to authenticated
  using (candidate.is_authorized_user() and candidate.is_admin());

-- NOTE: child tables (messages, employment, consent, compliance_items) keep the
-- open authorised-domain policies for now. With siloing on, tighten them to the
-- parent candidate's desk in a follow-up if strict isolation is required.
