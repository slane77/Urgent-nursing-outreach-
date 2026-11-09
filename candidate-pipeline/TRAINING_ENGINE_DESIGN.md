# Mandatory Training + Assessment (LMS-lite) — design & scoping

Scoping deliverable (architecture + schema/signature sketches, no production code).
Builds on the committed candidate/compliance spine: `candidate.candidates`,
`compliance_requirements` + `compliance_items`, the versioned `requirement_sets`,
the `recompute_candidate_status` work-ready gate (`sql/23`/`25`), the append-only
`verification_events` audit spine (`sql/22`), the private `candidate-docs` bucket +
`candidate_evidence` (`sql/28`), the pre-expiry reminder ladder (`sql/41`), and the
fail-closed RLS helpers `is_authorized_user()` / `is_admin()` /
`is_compliance_officer()` / `is_service_role()`. Mirrors the tone/`[DECISION]`
markers of `COMPLIANCE_PHASE1_DESIGN.md`, `CLIENT_CHECKLIST_DESIGN.md` and
`CANDIDATE_EXPERIENCE_DESIGN.md`.

## 0. The headline insight (what we are actually building)

> The compliance spine already has a `mandatory_training` requirement per
> discipline (`sql/13`), and the passport vocabulary already reserves
> `training.<module>.status/.expiry` (`CLIENT_CHECKLIST_DESIGN §1`). **The slot
> exists; nothing fills it.** This feature is the engine that fills it — it
> *produces verified, expiring `compliance_items`* the gate and the ladder already
> know how to consume.

So the LMS-lite is **not** a bolt-on parallel system. It is a **producer of
`compliance_items`**. Every other subsystem (`recompute_candidate_status`,
`due_expiry_reminders`, `compliance_passport`, the client-checklist auto-fill) then
works unchanged. Getting the *integration contract* right (§7) is the load-bearing
decision; the LMS mechanics are conventional.

Three constraints, locked by the user, shape everything:
- **Content is accreditation-bearing** → AI may *draft* but a **human approval gate
  is mandatory before publish**, and content is **immutably versioned**; a training
  record **freezes the `module_version` it was assessed against**.
- **Delivery is passwordless magic-link, no account** → reuse the exact
  **function-as-trust-boundary** model from `CANDIDATE_EXPERIENCE_DESIGN §3`:
  candidate holds only an opaque, hashed, short-TTL, single-use token and talks
  *only* to a `training-portal` edge function; tables stay **default-deny to
  non-staff** (no anon RLS at all).
- **Answer keys are server-side only** → the candidate client is served questions
  with correct answers stripped; grading happens inside the edge function; the key
  never reaches the browser.

## 1. The real auth/role model — what "managers only" and "approver" map to

Confirmed from the live schema (not assumed):
- `candidate.staff` (`sql/18`) has exactly two capability flags: **`is_admin`** and
  **`is_compliance`** (added in `sql/22`). **There is no `is_manager` role.**
- `is_admin()` = `staff.is_admin` (bootstrap-allows when no staff exist).
- `is_compliance_officer()` = `staff.is_compliance OR staff.is_admin` — so **admins
  are automatically officers**; an officer-gated policy already covers admins.
- `is_service_role()` (`sql/38`) = the edge-function/cron identity.

**[DECISION R1 — "managers only" = `is_admin()`]** The user's "managers only can
manually enter training dates" maps to **`is_admin()`** for Phase 1 (already the
app's manager-tier privilege — it gates set editing, overrides, deletes). Author
drafts on `is_compliance_officer()`; **approve + publish + manual entry on
`is_admin()`**. If Day Webster's "managers" are a distinct population from system
admins, the clean fix is a new `staff.is_manager` flag + `is_manager()` helper —
flagged as an open decision (§10); do not invent it speculatively.

| Action | Gate |
|---|---|
| Author/draft KB + questions, edit a draft, AI-draft | `is_compliance_officer()` |
| **Approve + publish** a version (accreditation gate) | `is_admin()` |
| Assign training to a candidate (send magic link) | `is_compliance_officer()` |
| **Manual training entry** (record-elsewhere + DW cert) | `is_admin()` |
| Read modules/attempts/records/certs | `is_authorized_user()` |
| Read raw **correct-answer keys** | `is_admin()` only (never served to candidates) |
| Take training / submit answers | **no DB role** — `training-portal` (service), token-scoped |

## 2. Data model

Highest applied migration is `42`; the checklist scoping reserved `43`/`44` (not yet
built). This feature claims **`45`–`50`** — renumber at build time to sit after the
last actually-applied migration. All files idempotent/additive,
`set search_path = candidate, public`, house style.

### 2.1 `45_training_catalogue.sql` — module catalogue + framework/accreditation

```sql
create table candidate.training_modules (
  id                uuid primary key default gen_random_uuid(),
  code              text not null unique,          -- 'moving_handling','bls','safeguarding_adults_l2'
  title             text not null,
  framework         text,                          -- 'CSTF'
  framework_subject text,                          -- 'Moving and Handling'
  sfh_accreditation_ref text,                      -- Skills for Health ref (see honesty note)
  validity_months   int not null default 12 check (validity_months > 0),
  pass_threshold    numeric not null default 75 check (pass_threshold between 0 and 100),
  question_count    int not null default 10 check (question_count > 0),
  requirement_code  text not null unique,          -- 1:1 into compliance_requirements (§7)
  current_version_id uuid,                          -- the PUBLISHED version; null until first publish
  status            text not null default 'active' check (status in ('active','retired')),
  created_by        uuid references auth.users(id) on delete set null,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
```

**Honesty note (in the file header):** `sfh_accreditation_ref` is a value **we store
and render** — it does **not** make the content accredited. Skills for Health
accreditation is **Day Webster's business/legal fact**, obtained out-of-band. The
system records and displays it (on certs, in the catalogue); it never fabricates
accreditation it wasn't given. Starts null; an admin populates it once real
accreditation is confirmed.

**Per-module validity → expiry.** `validity_months` is authoritative: a completion
writes `expires_at = completion_date + validity_months`. CSTF subjects are mostly
annual (`12`); a few 2–3yr — per-module, so each renews on its own clock. This is
what the pre-expiry ladder chases per-subject.

### 2.2 `46_training_versions.sql` — versioned content + question bank + approval

```sql
create table candidate.module_versions (
  id            uuid primary key default gen_random_uuid(),
  module_id     uuid not null references candidate.training_modules(id) on delete cascade,
  version       int  not null,
  status        text not null default 'draft'
                check (status in ('draft','in_review','approved','published','retired')),
  content       jsonb not null default '{}'::jsonb,  -- KB: [{heading, body_md}, ...]
  ai_generated  boolean not null default false,
  ai_model      text,
  authored_by   uuid references auth.users(id) on delete set null,
  reviewed_by   uuid references auth.users(id) on delete set null,
  approved_by   uuid references auth.users(id) on delete set null,   -- the human approval-gate signer (admin)
  approved_at   timestamptz,
  published_at  timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (module_id, version)
);

create table candidate.training_questions (
  id                uuid primary key default gen_random_uuid(),
  module_version_id uuid not null references candidate.module_versions(id) on delete cascade,
  stem              text not null,
  options           jsonb not null,        -- [{key:'a', text:'...'}, ...]
  correct_keys      jsonb not null,        -- ['a'] or ['a','c'] — NEVER served to candidates
  explanation       text,
  sort_order        int not null default 100,
  created_at        timestamptz not null default now()
);
```

**Immutability rule (accreditation integrity).** A `published` version is
**immutable** (a `BEFORE UPDATE` trigger rejects content mutation / backward status
when `status='published'`, mirroring `verification_events`/`checklist_fills`).
Editing a published module = a **new `module_versions` row** (`version+1`, draft).
Publishing sets `training_modules.current_version_id` and retires the prior. Existing
attempts/records keep pointing at the version they froze — a cert always states the
content it was earned against.

**Approval workflow (RPCs, SECURITY DEFINER):** `save_module_version` (officer,
draft only), `submit_module_for_review` (officer, draft→in_review),
`approve_module_version` (**admin only**, in_review→approved, stamps
`approved_by/at`; refuses if fewer than `question_count` questions),
`publish_module_version` (**admin only**, approved→published, sets
`current_version_id`, retires prior). A draft/in_review version can never be assigned
or served. Every transition appends a `verification_events` row.
**[DECISION A1]** widen the event_type check to add `'training_published'` (small
migration) so the audit reads cleanly.

### 2.3 `47_training_delivery.sql` — assignment, magic links, attempts

```sql
create table candidate.training_assignments (
  id            uuid primary key default gen_random_uuid(),
  candidate_id  uuid not null references candidate.candidates(id) on delete cascade,
  module_id     uuid not null references candidate.training_modules(id) on delete restrict,
  module_version_id uuid not null references candidate.module_versions(id) on delete restrict,
  status        text not null default 'assigned'
                check (status in ('assigned','in_progress','passed','failed','expired','cancelled')),
  assigned_by   uuid references auth.users(id) on delete set null,
  assigned_at   timestamptz not null default now(),
  completed_at  timestamptz,
  unique (candidate_id, module_id, module_version_id)
);

create table candidate.training_magic_links (   -- hashed, short-TTL, single-use
  token_hash    text primary key,               -- sha256(raw); raw emailed, NEVER stored
  assignment_id uuid not null references candidate.training_assignments(id) on delete cascade,
  candidate_id  uuid not null references candidate.candidates(id) on delete cascade,
  expires_at    timestamptz not null,
  consumed_at   timestamptz,
  created_at    timestamptz not null default now()
);

create table candidate.training_sessions (      -- short-lived post-consume session
  token_hash    text primary key,
  assignment_id uuid not null references candidate.training_assignments(id) on delete cascade,
  candidate_id  uuid not null references candidate.candidates(id) on delete cascade,
  expires_at    timestamptz not null,           -- ~60 min
  created_at    timestamptz not null default now()
);

create table candidate.training_attempts (
  id                uuid primary key default gen_random_uuid(),
  assignment_id     uuid not null references candidate.training_assignments(id) on delete cascade,
  candidate_id      uuid not null references candidate.candidates(id) on delete cascade,
  module_version_id uuid not null references candidate.module_versions(id) on delete restrict,
  served_question_ids jsonb not null,            -- exact set + order served (integrity)
  answers           jsonb,
  score             numeric,                     -- % computed server-side
  passed            boolean,
  started_at        timestamptz not null default now(),
  submitted_at      timestamptz
);
```

### 2.4 `48_training_records.sql` — training record + certificate + compliance hook

```sql
create table candidate.training_records (
  id                uuid primary key default gen_random_uuid(),
  candidate_id      uuid not null references candidate.candidates(id) on delete cascade,
  module_id         uuid not null references candidate.training_modules(id) on delete restrict,
  module_version_id uuid not null references candidate.module_versions(id) on delete restrict, -- FROZEN
  source            text not null check (source in ('assessment','manual')),
  score             numeric,
  attempt_id        uuid references candidate.training_attempts(id) on delete set null,
  provider          text,                          -- manual: where it was done elsewhere
  completion_date   date not null,
  expiry_date       date not null,                 -- completion + validity_months
  certificate_id    text not null unique,          -- 'DW-TRN-2026-3F9K2A'
  certificate_path  text,                          -- private bucket 'training-certs'
  compliance_item_id uuid references candidate.compliance_items(id) on delete set null,
  recorded_by       uuid references auth.users(id) on delete set null,  -- manual: the manager
  created_at        timestamptz not null default now()
);
```

One cert per record (fields fold onto `training_records`). External evidence for
manual entries reuses `candidate_evidence` + `candidate-docs` (`sql/28`).

### 2.5 RLS (enforced in the DB)

All new tables `enable row level security`. Candidates have **no DB identity** → no
anon/candidate policy anywhere; `training-portal` reaches tables via service role
only (default-deny to the world, same as `provider_jobs`/`verification_events`).

| Table | SELECT | INSERT | UPDATE | DELETE |
|---|---|---|---|---|
| `training_modules` | `is_authorized_user()` | `is_admin()` | `is_admin()` | `is_admin()` |
| `module_versions` | `is_authorized_user()` | `is_compliance_officer()` | via RPCs only | `is_admin()` |
| `training_questions` | **`is_admin()` only** (answer keys) | via RPCs | via RPCs | via RPCs |
| `training_assignments` | `is_authorized_user()` | `is_compliance_officer()` | via RPC | `is_admin()` |
| `training_magic_links` | **no policy** (service only) | — | — | — |
| `training_sessions` | **no policy** (service only) | — | — | — |
| `training_attempts` | `is_authorized_user()` | **no policy** (RPC) | **no policy** | — |
| `training_records` | `is_authorized_user()` | **no policy** (RPC) | **no policy** (append-only) | `is_admin()` |

`training_questions` SELECT is admin-only — officers edit questions *through the
RPCs*, but a raw read of `correct_keys` is admin-only (a staff-token leak can't dump
the answer bank). `training_attempts`/`training_records` have no client write — only
SECURITY DEFINER RPCs write them, so a pass/cert can't be forged.
`training_magic_links`/`training_sessions` have no policy at all (service only); raw
tokens never stored (only `sha256`).

## 3. Assessment engine (integrity-first)

**The critical invariant: the correct-answer key never reaches the browser, and
scoring happens server-side.** The candidate client is a dumb renderer.

Inside `training-portal` (service role):
1. **`start`** — verify session → resolve assignment → load
   `training_modules.current_version_id` → **randomly select N = `question_count`**
   from that version's bank → insert a `training_attempts` row storing
   `served_question_ids` (exact IDs + order → deterministic grading + audit) →
   return `{ attempt_id, questions:[{id,stem,options}] }` — **`correct_keys` +
   `explanation` stripped in code before serialization.**
2. **`submit`** — verify session → load the attempt's `served_question_ids` → fetch
   those questions' `correct_keys` **server-side** → grade (correct iff submitted
   set == `correct_keys` set) → `score = correct/N*100` →
   `passed = score >= pass_threshold` (default 75) → write
   `answers/score/passed/submitted_at`. Pass → `issue_training_record(...)`; fail →
   assignment `failed`, retake allowed.

**[DECISION AS1] Retakes** — mandatory training must eventually pass: **unlimited
retakes, every attempt persisted** (the audit trail), each retake **re-randomises**
the served subset. Optional small cooldown (default 0); no attempt cap.
**[DECISION AS2] Threshold** — per-module `pass_threshold`, seeded + locked at 75.
**[DECISION AS3] Bank size** — bank ≥ 2×`question_count` so retakes vary.

## 4. Magic-link candidate delivery — `training-portal` edge function

Mirrors `CANDIDATE_EXPERIENCE_DESIGN §3` (function-as-trust-boundary, default-deny
tables, service role, every query scoped to the token's candidate/assignment). New
`candidate-pipeline/functions/training-portal/index.ts`, modes (POST JSON), **no
Authorization header** — the opaque token is the credential:
- **`consume`** `{token}` — `sha256` lookup where unconsumed + unexpired → set
  `consumed_at` (single-use), mint a session (~60 min), assignment→`in_progress`,
  return `{ session_token, module, content }` (the KB). Invalid → generic 401.
- **`start`** `{session_token}` — §3 step 1 → questions **without keys**.
- **`submit`** `{session_token, attempt_id, answers}` — §3 step 2 → grade →
  `{ passed, score, certificate_id?, retake_allowed }` (reveal only which items were
  wrong, **not** the key).
- **`status`** — progress/last result.

Every query `.eq('candidate_id', session.candidate_id)`; tokens single-use/short-TTL/
hashed/rate-limited; deploy `verify_jwt=false`; generic errors (no enumeration).

**[DECISION U1] Candidate page** `training.html` — public, **mobile-first**, a clean
**light** GOV.UK-style one-thing-per-screen flow (KB → Start → one question per
screen → result), NOT the staff dark theme (external users; higher completion). Talks
ONLY to `training-portal`; no anon key with table access; no answer key or other
candidate's data ever reaches the page.

## 5. Certificates (Day Webster + Skills for Health)

`issue_training_record(...)` (SECURITY DEFINER; service on the assessment path, or the
manager manual RPC): resolves the frozen `module_version` → mints `certificate_id`
(`'DW-TRN-'||year||'-'||6hex`) → computes `expiry_date = completion + validity_months`
→ inserts `training_records` → writes the compliance hook (§7) → appends a
`verification_events` row (`event_type='verified'`, `method='assessment'|'human'`,
`source_ref=certificate_id`) → renders + stores the certificate.

**[DECISION C1 — HTML cert now, PDF Phase 2]** No native Word/HTML→PDF in Deno.
Phase 1 renders a **branded HTML certificate** (DW logo, candidate name, module title,
framework/subject, **`sfh_accreditation_ref`**, completion + expiry, `certificate_id`)
into a **private `training-certs` bucket**, downloaded via a **300s signed URL**.
Phase 2 adds a Gotenberg PDF render (shared with the checklist-PDF work).

**[DECISION C2 — public certificate verification, recommended]**
`verify_certificate(p_certificate_id)` returns **minimal** validity only —
`{ valid, module_title, framework_subject, sfh_accreditation_ref, completion_date,
expiry_date, status, candidate_initials }`, **never** full name/DOB/score. Fronted by a
rate-limited `certificate-verify` function + a public `verify-cert.html`. Certs are
PII-bearing → private bucket, UK/EU, short-TTL signed URLs only.

## 6. Manager-only manual entry

`record_manual_training(p_candidate_id, p_module_id, p_completion_date, p_score,
p_provider, p_evidence_path)` — SECURITY DEFINER, **guarded `if not is_admin() then
raise 'not authorized'`**. Records the uploaded external cert to `candidate_evidence`
(the UI uploads to `candidate-docs`, passes the path) → calls `issue_training_record(
…, source='manual', recorded_by=auth.uid())` → issues the **DW cert** + record +
compliance hook. The `verification_events` row is `method='human'`,
`actor=<manager>`, notes naming the external provider → fully attributable. Ordinary
officers cannot manual-enter (RPC guard + no client write policy).

## 7. Compliance integration (the payoff) — the load-bearing decision

**[DECISION CI1 — one requirement PER CSTF SUBJECT, not sub-items under the monolith.
Forced by the gate's math.]** `recompute_candidate_status` (`sql/25`) resolves, per
requirement, the **single** latest item (`order by (status='verified') desc,
updated_at desc limit 1`). Filing many per-module items under the one existing
`mandatory_training` requirement → **the gate would see only one and silently ignore
the rest** (a safety hole); the ladder (`due_expiry_reminders`) collapses identically.
Therefore **each module maps 1:1 to its own `compliance_requirement`**
(`training_modules.requirement_code`), e.g. `train_moving_handling`, `train_bls`,
`train_safeguarding_adults_l2`, `train_ig`, `train_fire`, …

- each completion writes **one `compliance_item`** under that requirement,
  `status='verified'`, `expires_at = completion + validity_months`,
  `channel='assessment'|'manual'`, `source_ref`=`certificate_id`;
- the **existing** item trigger recomputes the gate (no new trigger);
- the **existing** ladder chases each subject on its own clock;
- the passport's `training.<module>.*` + generic `item.<code>.*` resolve for free.

`45_training_catalogue.sql` seeds a requirement per module + a
`sync_training_requirements()` helper that adds each active module's requirement to
the relevant `requirement_set(s)`. **[DECISION CI2]** core CSTF subjects
`criticality='blocking'` per set (configurable via `requirement_set_items` override).
**[DECISION CI3]** the legacy monolithic `mandatory_training` requirement is
**demoted to advisory** so it can't double-count. `issue_training_record` upserts the
latest item for `(candidate, requirement)`; a renewal's new `expires_at` starts a
fresh ladder automatically. If the module's requirement isn't in the candidate's
active set, the item is still written (feeds the passport) but doesn't move the gate —
no error. **Net: zero changes to the gate, ladder, or passport code.**

## 8. UI

Staff convention: vanilla HTML + `supabase-js@2` + `sb` client
`{ db:{ schema:'candidate' } }`, `.rpc()`, `createSignedUrl(path,300)`, dark
`dw-theme.css`. No secrets/answer keys in any page.
- **`training-admin.html`** (new; in topnav) — authoring/approval console: module
  catalogue; version editor (KB + question editor with stem/options/correct-key/
  explanation); **AI draft** button → `training-authoring` function; status pipeline
  draft→submit→**approve**→**publish** (approve/publish visible only when
  `is_admin()`); **assign training** (→ magic link); **manual entry** (rendered only
  when `is_admin()`).
- **`candidates.html` — new "Training" card** in `#detail`: per-candidate modules
  (status/score/completion/expiry), cert **download** (signed URL), **assign**, attempt
  history.
- **`training.html`** (candidate, §4) and **`verify-cert.html`** (public, §5).

**AI-draft function** `candidate-pipeline/functions/training-authoring/index.ts` —
reuses the exact `compliance-import` stack (`npm:@anthropic-ai/sdk`,
`claude-opus-4-8`, structured `json_schema`, staff-only email-domain gate). Output:
`{ content:[{heading,body_md}], questions:[{stem,options,correct_keys,explanation}] }`
→ saved as a **draft `module_versions`** (`ai_generated=true`). The AI never
publishes; an admin must approve. The AI sees only content/subject briefs, never
candidate data.

## 9. Data protection + audit + accreditation integrity (UK GDPR)

- **Answer keys server-side only** (admin-read RLS + stripped in the function).
- **Function-mediated candidate access** (default-deny tables); hashed, single-use,
  short-TTL magic-link + session tokens (raw never stored); rate-limited; generic
  errors.
- **Append-only in spirit**: attempts/records have no client write/update; all writes
  via SECURITY DEFINER RPCs; every publish/approval and manual entry appends an
  attributable `verification_events` row.
- **Frozen version on every record/attempt** — a cert is provably tied to the exact
  content+questions earned against.
- **PII**: certs in a private `training-certs` bucket (UK/EU, 300s signed URLs);
  external evidence in `candidate-docs`; public verification reveals minimal info +
  initials only. Anthropic under DPA before real PII (the authoring AI sees only
  content briefs, never candidate data).
- **Accreditation honesty**: `sfh_accreditation_ref` is recorded, not asserted; the
  system does not manufacture accreditation.

## 10. Phasing + open decisions

### Phase 1 — prove the engine end-to-end (with 1–2 fully-authored SEED modules)
1. `45_training_catalogue.sql` — modules + per-subject requirements +
   `sync_training_requirements()` + demote legacy `mandatory_training` + RLS.
2. `46_training_versions.sql` — versions, questions, approval RPCs, immutability
   trigger, event-type widening + RLS.
3. `47_training_delivery.sql` — assignments, hashed magic-links/sessions, attempts,
   `assign_training` + `consume/start/submit` RPCs + RLS.
4. `48_training_records.sql` — records, `issue_training_record` (+ compliance hook +
   recompute), `verify_certificate`, `training-certs` bucket.
5. `49_training_manual_entry.sql` — `record_manual_training` (`is_admin()`).
6. `50_training_seed.sql` — **1–2 fully human-authored SEED modules** (e.g. Moving &
   Handling + Safeguarding Adults L2), published, wired into the NHS set — proves
   assign → KB → assess → pass → cert → gate-flip end-to-end.
7. Edge functions `training-portal`, `training-authoring`; pages `training.html`,
   `training-admin.html`, `verify-cert.html`, the candidates.html Training card.

### Phase 2
- **Author the full CSTF suite** via AI-draft → human-approve.
- **PDF certs + polished public verification** (shared Gotenberg with the checklist).
- **Comms/reminders** ride the existing ladder (`sql/41`); add training copy.
- **Bulk-assign** a module to a cohort; WhatsApp/SMS link delivery.

### Open decisions for the user
1. **Exact CSTF subject list + per-subject validity** (which subjects; annual vs
   2–3yr) — drives the seed + `validity_months`.
2. **Which subjects blocking vs standard** per requirement set.
3. **Pass threshold** — fixed 75% (recommended) or per-module variation?
4. **Retake cooldown** — 0 (recommended) or a small delay? (no attempt cap).
5. **"Manager" = `is_admin()`** (recommended) or a dedicated `staff.is_manager`?
6. **Cert format Phase 1** — HTML now, PDF Phase 2 (recommended)?
7. **Public certificate-verification page** — wanted (recommended); confirm the
   minimal fields it may reveal (initials + dates + SfH ref, no full name).
8. **How framework tags + SfH accreditation refs are supplied**, and confirmation the
   system *records* not *asserts* accreditation.
9. **AI-draft scope** — acceptable given every draft is human-approved before publish
   and the AI never sees candidate data?

### Load-bearing facts that forced choices
- `recompute_candidate_status` + `due_expiry_reminders` both resolve **one latest item
  per requirement** → **one requirement per CSTF subject** is mandatory (CI1).
- `candidate.staff` has only `is_admin`/`is_compliance` — no manager role → "managers
  only" ⇒ `is_admin()` unless a new flag is added (R1).
- The spine already reserves `mandatory_training` + `training.<module>.*` — this
  feature is a **producer of `compliance_items`**; the gate/ladder/passport need no
  changes.
- Deno has no native Word/HTML→PDF → HTML cert Phase 1, PDF Phase 2.
- House pattern **no-client-write + SECURITY DEFINER RPCs = un-forgeable audit** →
  records/attempts/passes/certs follow it exactly.
