-- ============================================================================
--  Day Webster — Candidate Pipeline · Pre-expiry reminder ladder
--  File: candidate-pipeline/sql/41_pre_expiry_ladder.sql
--  Run AFTER 22–25 and 40. Idempotent / additive.  STATUS: DRAFT — NOT YET APPLIED.
--
--  [DECISION E1] CANDIDATE_EXPERIENCE_DESIGN §2a — "nothing ever expires
--  unnoticed". Every time-bound item drives an escalating, expiry-anchored nudge
--  sequence off its own expires_at at T-90/60/30/14/7/1 days (configurable,
--  per-requirement override optional). Each rung fires ONCE per item per expiry
--  and RESETS automatically on renewal (the tracking key includes expires_at, so
--  a renewed item — a NEW expiry — starts a fresh ladder, and an unchanged item
--  is never double-sent).
--
--  Adds:
--    · pre_expiry_offsets            — the configurable ladder (seeded 90..1)
--    · expiry_reminders_sent         — per-(item,expiry,offset) once-only ledger
--    · compliance_requirements.candidate_label / candidate_help — candidate-facing
--    · messages.template             — comms template tag (multi-channel ready)
--    · due_expiry_reminders()        — the send worklist (nearest due rung/item)
--
--  The edge sweep (functions/early-warnings) reads due_expiry_reminders(), sends
--  the email, then records expiry_reminders_sent + a candidate.messages row.
-- ============================================================================

-- ── Candidate-facing renewal copy (optional; null => generic fallback) ──────
alter table candidate.compliance_requirements
  add column if not exists candidate_label text,   -- friendly name, e.g. "your DBS"
  add column if not exists candidate_help  text;    -- plain renewal advice

-- ── Comms template tag on the message log (future multi-channel engine) ─────
alter table candidate.messages
  add column if not exists template text;

-- ── Configurable ladder offsets (T-minus days before expiry) ────────────────
-- requirement_code NULL = applies to ALL requirements (global). A row WITH a
-- requirement_code is a per-requirement OVERRIDE: when any active override rows
-- exist for a requirement, ONLY those apply to it (the global ladder is ignored
-- for that requirement) — see due_expiry_reminders().
create table if not exists candidate.pre_expiry_offsets (
  id               uuid primary key default gen_random_uuid(),
  offset_days      int  not null check (offset_days > 0),
  requirement_code text,                          -- null = all requirements
  active           boolean not null default true,
  created_at       timestamptz not null default now()
);
-- Null-collapsing uniqueness so re-seeding is a true no-op (D5 pattern, file 13).
create unique index if not exists pre_expiry_offsets_key_uniq
  on candidate.pre_expiry_offsets (offset_days, coalesce(requirement_code, '*'));

insert into candidate.pre_expiry_offsets (offset_days, requirement_code)
values (90, null), (60, null), (30, null), (14, null), (7, null), (1, null)
on conflict (offset_days, coalesce(requirement_code, '*')) do nothing;

-- ── Once-only send ledger — resets on renewal via the expires_at in the key ─
create table if not exists candidate.expiry_reminders_sent (
  id           uuid primary key default gen_random_uuid(),
  item_id      uuid not null references candidate.compliance_items(id) on delete cascade,
  candidate_id uuid not null references candidate.candidates(id) on delete cascade,
  expires_at   timestamptz not null,             -- the expiry this ladder anchors on
  offset_days  int not null,
  channel      text not null default 'email',    -- multi-channel ready (email now)
  message_id   uuid references candidate.messages(id) on delete set null,
  sent_at      timestamptz not null default now(),
  unique (item_id, expires_at, offset_days)
);
create index if not exists expiry_reminders_sent_item_idx
  on candidate.expiry_reminders_sent (item_id);
create index if not exists expiry_reminders_sent_candidate_idx
  on candidate.expiry_reminders_sent (candidate_id);

-- ── The send worklist: the NEAREST due, unsent rung per current item ────────
-- For each candidate's CURRENT (latest) verified blocking/standard item on an
-- active set with a FUTURE expiry, pick the tightest ladder rung whose window is
-- open (offset_days >= days_left) and that has not yet been sent for this exact
-- expiry. Sending only the nearest due rung (rather than every passed rung)
-- keeps each rung firing exactly once on its day and prevents a burst when an
-- item is added late. A renewed item (new expiry) or a superseded old instance
-- simply no longer matches, so no chase goes out for a renewed item.
create or replace function candidate.due_expiry_reminders(
  p_now timestamptz default now(), p_limit int default 1000)
returns table(
  item_id          uuid,
  candidate_id     uuid,
  requirement_id   uuid,
  requirement_code text,
  requirement_name text,
  candidate_label  text,
  candidate_help   text,
  expires_at       timestamptz,
  days_left        int,
  offset_days      int,
  first_name       text,
  email            text,
  buffer_days      int)
language sql stable security definer
set search_path = candidate, public as $$
  with current_item as (
    -- latest item per (candidate, requirement) within active sets, blocking/standard.
    select distinct on (ci.candidate_id, ci.requirement_id)
      ci.id            as item_id,
      ci.candidate_id,
      ci.requirement_id,
      ci.status,
      ci.expires_at,
      cr.code          as requirement_code,
      cr.name          as requirement_name,
      cr.candidate_label,
      cr.candidate_help
    from candidate.compliance_items ci
    join candidate.candidate_requirement_sets crs
      on crs.candidate_id = ci.candidate_id and crs.active
    join candidate.requirement_set_items rsi
      on rsi.set_id = crs.set_id and rsi.requirement_id = ci.requirement_id
    join candidate.compliance_requirements cr on cr.id = ci.requirement_id
    where coalesce(rsi.criticality, cr.criticality) in ('blocking','standard')
      and coalesce(rsi.required_override, cr.required)   -- only chase REQUIRED items (an optional doc never blocks the gate)
    order by ci.candidate_id, ci.requirement_id,
             (ci.status = 'verified') desc, ci.updated_at desc
  ),
  live as (
    select ci.*,
           c.first_name, c.email,
           greatest(0, ceil(extract(epoch from (ci.expires_at - p_now)) / 86400.0))::int as days_left
    from current_item ci
    join candidate.candidates c on c.id = ci.candidate_id
    where ci.status = 'verified'                 -- only a live, verified doc has a ladder
      and ci.expires_at is not null
      and ci.expires_at > p_now                  -- future expiry (expired => early-warnings path)
  ),
  rung as (
    select l.*,
      -- the tightest applicable rung whose window is open. Per-requirement
      -- overrides win: if the requirement has its own rows, ignore the global set.
      (select min(o.offset_days)
         from candidate.pre_expiry_offsets o
         where o.active
           and o.offset_days >= l.days_left
           and case
                 when exists (select 1 from candidate.pre_expiry_offsets o2
                              where o2.active and o2.requirement_code = l.requirement_code)
                   then o.requirement_code = l.requirement_code
                 else o.requirement_code is null
               end
      ) as offset_days
    from live l
  )
  select r.item_id, r.candidate_id, r.requirement_id, r.requirement_code,
         r.requirement_name, r.candidate_label, r.candidate_help,
         r.expires_at, r.days_left, r.offset_days, r.first_name, r.email,
         candidate.booking_buffer_days()
  from rung r
  where r.offset_days is not null
    and not exists (
      select 1 from candidate.expiry_reminders_sent s
      where s.item_id     = r.item_id
        and s.expires_at  = r.expires_at
        and s.offset_days = r.offset_days
    )
  order by r.expires_at
  limit greatest(coalesce(p_limit, 1000), 0);
$$;
revoke all on function candidate.due_expiry_reminders(timestamptz, int) from public;
grant execute on function candidate.due_expiry_reminders(timestamptz, int) to authenticated, service_role;

-- ── RLS ─────────────────────────────────────────────────────────────────────
alter table candidate.pre_expiry_offsets      enable row level security;
alter table candidate.expiry_reminders_sent   enable row level security;

-- Ladder config: authorised staff read; admins write.
drop policy if exists "auth read offsets"  on candidate.pre_expiry_offsets;
drop policy if exists "admin write offsets" on candidate.pre_expiry_offsets;
create policy "auth read offsets" on candidate.pre_expiry_offsets
  for select to authenticated using (candidate.is_authorized_user());
create policy "admin write offsets" on candidate.pre_expiry_offsets
  for all to authenticated
  using (candidate.is_authorized_user() and candidate.is_admin())
  with check (candidate.is_authorized_user() and candidate.is_admin());

-- Send ledger: authorised staff read. No client write policy — the sweep writes
-- it via service_role (bypasses RLS); no logged-in user forges a "sent" row.
drop policy if exists "auth read reminders_sent" on candidate.expiry_reminders_sent;
create policy "auth read reminders_sent" on candidate.expiry_reminders_sent
  for select to authenticated using (candidate.is_authorized_user());
