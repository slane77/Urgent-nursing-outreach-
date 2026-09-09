-- ============================================================================
--  Day Webster — Candidate Pipeline · Division taxonomy (top of the tree)
--  File: candidate-pipeline/sql/30_divisions.sql
--  Run AFTER 10-29. Idempotent / additive.  STATUS: DRAFT — NOT YET APPLIED.
--
--  Adds the DIVISION layer above disciplines: divisions -> disciplines ->
--  specialties. A division is the business-unit grouping (Nursing, Doctors,
--  AHP & HSS, Social Care, Other) the cockpit filters and reports on. Purely a
--  parent grouping — the compliance engine still resolves sets from
--  (discipline, specialty); divisions never change what a candidate needs.
--
--  RLS mirrors 22/26: authorised staff READ; admins WRITE (is_admin()).
-- ============================================================================

-- ── Divisions table ─────────────────────────────────────────────────────────
create table if not exists candidate.divisions (
  id          uuid primary key default gen_random_uuid(),
  code        text not null unique,          -- machine key, e.g. 'nursing'
  name        text not null,                 -- display, e.g. 'Nursing Division'
  sort_order  int  not null default 100,
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

-- ── disciplines.division_id FK (+ lookup index) ─────────────────────────────
alter table candidate.disciplines
  add column if not exists division_id uuid references candidate.divisions(id) on delete set null;
create index if not exists disciplines_division_idx
  on candidate.disciplines (division_id);

-- ── RLS: auth read, admin write (mirror 22/26) ──────────────────────────────
alter table candidate.divisions enable row level security;
drop policy if exists "auth read divisions"  on candidate.divisions;
drop policy if exists "admin write divisions" on candidate.divisions;
create policy "auth read divisions" on candidate.divisions
  for select to authenticated using (candidate.is_authorized_user());
create policy "admin write divisions" on candidate.divisions
  for all to authenticated
  using (candidate.is_authorized_user() and candidate.is_admin())
  with check (candidate.is_authorized_user() and candidate.is_admin());

-- ── Seed the day-one divisions ──────────────────────────────────────────────
insert into candidate.divisions (code, name, sort_order) values
  ('nursing',     'Nursing Division',     10),
  ('doctors',     'Doctors Division',     20),
  ('ahp_hss',     'AHP & HSS Division',   30),
  ('social_care', 'Social Care',          40),
  ('other',       'Other / Non-clinical', 50)
on conflict (code) do nothing;

-- ── Map existing disciplines -> divisions ───────────────────────────────────
-- Deterministic Phase-1b mapping. `is distinct from` makes the re-run a no-op
-- and avoids clobbering a division that already matches.
update candidate.disciplines d
set division_id = dv.id
from (values
  ('nursing',      'nursing'),
  ('doctors',      'doctors'),
  ('ahp',          'ahp_hss'),
  ('complex_care', 'social_care'),
  ('care_homes',   'social_care'),
  ('childrens',    'social_care'),
  ('insurance',    'other')
) as m(disc_code, div_code)
join candidate.divisions dv on dv.code = m.div_code
where d.code = m.disc_code
  and d.division_id is distinct from dv.id;
