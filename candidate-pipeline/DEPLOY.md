# Deployment runbook — Candidate Pipeline

Stand the whole pipeline up **on an isolated Supabase dev branch first**, prove
it on synthetic data, then promote to production. Nothing here touches the
existing outreach system (it's a separate `candidate` schema).

> **Order matters.** Do the steps top to bottom. ☐ = tick as you go.

---

## 0. Before you start — gather

- ☐ **Anthropic API key** + confirm data-handling terms (DPA / no-training-by-default / zero-data-retention). *Use synthetic candidates on dev until this is signed off (§11).*
- ☐ **Brevo account** + API key (transactional email).
- ☐ A **sending domain/subdomain** you control (e.g. `candidates.daywebster.com`) for `From` and `Reply-To`.
- ☐ (Later) Indeed / Reed / CV-Library recruiter **API credentials**.

---

## 1. Create the dev environment

**Option A — Supabase Branching** (Pro plan): Dashboard → Branches → create branch `candidate-dev`. You get an isolated DB + its own URL/keys.
**Option B — a second free Supabase project** named `candidate-dev` as your sandbox.

☐ Note the dev project's **Project URL**, **anon (publishable) key**, and **service-role key**.

---

## 2. Apply the schema (in order)

In the dev project's **SQL Editor**, run each file in order:

☐ `sql/10_candidate_schema.sql`
☐ `sql/11_candidate_policies.sql`
☐ `sql/12_candidate_seed.sql`
☐ `sql/13_compliance_requirements.sql`
☐ `sql/14_early_warnings.sql`
☐ `sql/15_inbound_email.sql`
☐ `sql/16_sourcing.sql`
☐ `sql/17_dashboard.sql`
☐ `sql/18_desks.sql`
☐ `sql/19_app_users.sql`

☐ **Expose the schema:** Settings → API → *Exposed schemas* → add `candidate`.
☐ **Storage:** create a **private** bucket named `candidate-docs`.

---

## 3. Set function secrets

In the dev project: Edge Functions → Secrets (or `supabase secrets set`). Set:

| Secret | Example / note |
|---|---|
| `ANTHROPIC_API_KEY` | `sk-ant-…` |
| `BREVO_API_KEY` | from Brevo |
| `CANDIDATE_SENDER_EMAIL` | `candidates@candidates.daywebster.com` |
| `CANDIDATE_SENDER_NAME` | `Day Webster` |
| `REPLY_DOMAIN` | `candidates.daywebster.com` |
| `REPLY_LOCAL` | `compliance` |
| `INBOUND_SECRET` | any random string |
| `CRON_SECRET` | any random string |
| `WORK_READY_TOKEN` | any random string — shared bearer the external booking system sends to the `work-ready` gate; the function returns 401 until this is set |
| `VERIFICATION_TOKEN` | any random string — bearer for automation calling `verification?mode=check` (officers use their own JWT instead) |
| `NMC_API_KEY` / `GMC_API_KEY` / `HCPC_API_KEY` | per-regulator register-check credential (the `secret_ref` each provider row names). **Leave UNSET until you actually hold the credential** — the adapter then returns `needs_human`, never a pass. |
| `DBS_API_KEY` / `RTW_API_KEY` | DBS Update Service / Right-to-Work (IDSP/aggregator) credential. Leave unset until contracted; adapter stays fail-closed. |
| `PUBLIC_SITE_URL` | where `intake.html` is hosted (see step 6) |
| `ORG_NAME` / `ORG_URL` | `Day Webster` / `https://www.daywebster.com` |

`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are injected automatically — don't set them.

---

## 4. Deploy the edge functions

The functions import a shared folder, so deploy them with `_shared` alongside.
Place them under `supabase/functions/` like this (copy from
`candidate-pipeline/functions/`):

```
supabase/functions/_shared/{email.ts,jobposting.ts}
supabase/functions/candidate-agent/index.ts
supabase/functions/<each other function>/index.ts
```

Deploy (`supabase functions deploy <name>` for each, or the dashboard editor),
with these JWT settings:

| Function | verify_jwt | Who calls it |
|---|---|---|
| `candidate-agent` | **true** | staff (cockpit) |
| `csv-import` | **true** | staff (importer) |
| `compliance-import` | **true** | staff (compliance bulk migration) |
| `reference-request` | **true** | staff |
| `job-advert` | **true** | staff (vacancies) |
| `outreach-campaign` | **true** | staff |
| `candidate-intake` | **false** | public form |
| `inbound-email` | **false** | email provider (`?secret=`) |
| `early-warnings` | **false** | cron (`?secret=`) |
| `jobs` | **false** | public (Google) |
| `work-ready` | **false** | external booking system (Bearer `WORK_READY_TOKEN`) — compliance gate; returns 401 until the token is set |
| `verification` | **false** | officers (`mode=check`, their JWT) + cron (`mode=drain`/`mode=sweep`, `?secret=CRON_SECRET`) + automation (Bearer `VERIFICATION_TOKEN`). Deploy with the `adapters/` folder alongside `index.ts`. |

> **Compliance Phase 0 migrations** — apply `sql/22_compliance_sets.sql`,
> `sql/23_work_ready_gate.sql`, then `sql/24_seed_nhs_rn_set.sql` (after 10–21).
> They add versioned requirement sets, the `is_compliance` staff flag, the
> append-only `verification_events` audit table, and the computed work-ready
> gate (`is_work_ready()` / `work_ready_status()`), plus a seeded NHS Registered
> Nurse set. The external booking system calls the `work-ready` function to gate
> placement (fail-closed: unreachable / red ⇒ do not place).
>
> Note on set versions: candidates are pinned to the set *version* they were
> assigned. Publishing a new active version (e.g. `NHS_RN` v2) does not move v1
> candidates automatically — reassign them to the new version so the gate
> recomputes; until then the booking system (which resolves `set_code` to the
> latest active version) reads them as red (fail-closed, not fail-open).
>
> **Compliance Phase 1 migrations** — after 22–24, apply in order:
> `sql/25_compliance_scale.sql` (adds `'waived'` + `migrated` to
> `compliance_items`, the `candidate.bulk_load` trigger guard, the
> `needs_human_count`/`expiring_count` scalars + waived-caps-at-amber recompute,
> `recompute_candidate_status_bulk()`, the compliance-officer desk-read exemption,
> and the scale indexes), `sql/26_requirement_set_map.sql` (the
> `requirement_set_map` table + `assign_requirement_sets()` / `materialize_items()`
> + the auto-assign trigger), `sql/27_seed_requirement_sets.sql` (composes
> NHS_HCA / NHS_DOCTOR / AHP_HCPC / COMPLEX_CARE / CARE_HOME / CHILDRENS /
> INSURANCE + the REG_MGR_* add-ons and seeds the map; adds a nursing-scoped
> `care_certificate`), `sql/28_evidence.sql` (`candidate_evidence` + RLS), and
> `sql/29_compliance_ops.sql` (the `compliance_worklist` view + the
> `compliance_dashboard` / `decide_item` / `bulk_assign_set` / `bulk_request` /
> `import_compliance_bulk` RPCs). Then deploy the `compliance-import` edge
> function (verify_jwt=true, staff): `map` mode uses Claude to map spreadsheet
> headers to `req:<code>:<field>` targets; `commit` mode batches to
> `import_compliance_bulk` (service_role). Migrated items import as
> `verified`+`migrated` with a 90-day grace expiry and one provenance
> `verification_events` row each.
>
> **Compliance Phase 1b migrations (division taxonomy)** — after 30–33, apply in
> order: `sql/30_divisions.sql` (adds `candidate.divisions` + a
> `disciplines.division_id` FK/index, RLS = auth read / admin write, seeds the
> five divisions and maps existing disciplines to them),
> `sql/31_role_taxonomy.sql` (adds specialties: nursing `hca`/`enp`/`anp`,
> doctors `psychiatry`; `enp`/`anp`/`psychiatry` inherit their discipline's base
> set), `sql/32_seed_role_sets.sql` (adds the `performers_list` catalogue
> requirement; composes `NHS_MIDWIFE` / `NHS_ODP` / `NHS_GP`; **fixes the Phase-1
> map bug** where NHS_HCA was mapped discipline-wide because the `hca` specialty
> did not yet exist — a plain nurse now correctly resolves to NHS_RN; then wires
> the specialty→set map rows), and `sql/33_worklist_division.sql`
> (`create or replace` on `compliance_worklist` adding
> `division_id`/`division_code`/`division_name`). Migrations are SQL-only (no UI)
> and idempotent — 30–33 re-run to a no-op.
>
> **Compliance Phase 1c migrations (officer assignment + reporting)** — after
> 34–36, apply in order: `sql/34_compliance_officer.sql` (adds
> `candidates.compliance_officer`; the append-only `officer_assignments` history
> table — compliance-officer read+insert, NO update/delete = immutable; the
> `assign_officer` / `bulk_assign_officer` / `auto_assign_officers_by_division`
> RPCs, gated `is_compliance_officer()`, validating the target is staff with
> `is_compliance`/`is_admin`; extends `compliance_worklist` with
> `compliance_officer`). Assignment is ON-DEMAND ONLY — no trigger — and the new
> column is absent from the set-assign / autoroute trigger `OF (...)` lists, so
> writing it never fans out. Visibility stays open (all officers see the bench;
> "my candidates" is a client-side filter, not RLS).
> `sql/35_overseeing_hierarchy.sql` (adds `staff.overseen_by` + `my_reports()` /
> `is_overseeing_officer()`). `sql/36_compliance_reporting.sql` (the
> `candidate_overall_status` view — one fail-closed overall RAG per in-pipeline
> candidate; the `compliance_officer_report` and `compliance_exec_overview`
> report RPCs, gated `is_compliance_officer()`). Migrations are SQL-only (no UI)
> and idempotent — 34–36 re-run to a no-op.
>
> **Compliance Phase 2 migrations (automated verification)** — after 36, apply in
> order: `sql/37_verification_providers.sql` (the `verification_providers`
> registry — NON-SECRET config only; a `secret_ref` NAMES an env var, credentials
> never live in the DB or client — `provider_jobs` fail-closed queue with an
> in-flight UNIQUE guard for idempotency, and `verification_consent`; adds the
> deferred `regulator`/`provider_key`/`verification_method` columns to
> `compliance_requirements` + wires the NMC/GMC/HCPC/DBS/RTW codes; the
> **load-bearing** switch of the register codes to
> `expiry_rule = '{"type":"regulator_driven"}'` so the provider writes the
> regulator's renewal date into `expires_at` and the existing expiry sweep + amber
> window start working; seeds the Phase-2a providers incl. a `sim` provider for
> the POC; RLS = providers read-officer/write-admin, `provider_jobs` read-officer
> with **NO client write policy** (service-role + definer RPCs only), consent
> read/insert-officer). `sql/38_verification_rpcs.sql` (SECURITY DEFINER RPCs:
> `enqueue_verification` [officer/service, idempotent, sets `verifying` only if not
> already `verified`], `claim_provider_jobs` [service, `FOR UPDATE SKIP LOCKED`],
> `apply_verification_result` [service, only a `verified` outcome credits the gate;
> one immutable result event], `fail_provider_job` [service, backoff retry then
> `needs_human` — never a pass], `enqueue_due_rechecks` [service, set-based
> rate-spread sweep], `verification_counts` [officer], the actor-resolved read-only
> `verification_history` view, and the `is_service_role()` helper).
> `sql/39_verification_schedule.sql` (the `purge_provider_job_responses()`
> retention purge + guarded pg_cron `verification-drain` (*/10) and
> `verification-sweep` (daily) — apply-safe without pg_cron; it just NOTICEs).
> Then deploy the `verification` edge function (verify_jwt=false) **with its
> `adapters/` folder**. Migrations are additive + idempotent — 37–39 re-run to a
> no-op (the `regulator_driven` fix is `where expiry_rule is null` so it never
> re-fires). **POC framing:** we hold no real regulator credentials yet, so the
> real adapters are credential-gated (unset `secret_ref` env ⇒ `needs_human`,
> never a pass) and the `sim` provider demonstrates the full pipeline end-to-end.

> **Continuous compliance — shift-date gate + pre-expiry ladder (migrations 40–41).**
> `sql/40_shift_compliance_gate.sql`: `compliance_settings` (single-row config;
> `booking_buffer_days` default 3, admin-writable) + `booking_buffer_days()`;
> `work_ready_status_on()` / `is_work_ready_on()` — the SHIFT-DATE gate that
> evaluates compliance AS-OF a shift date + buffer (a blocking item must stay
> valid past `shift_date + buffer`), fail-closed like `is_work_ready`; and the
> manager **override** — `compliance_overrides` (RLS: officer **read only**, **NO
> client write policy**; writes ONLY via `grant_compliance_override` /
> `revoke_compliance_override`, both `is_compliance_officer()`-gated, reason
> MANDATORY, time-bounded, and each appends an immutable `verification_events`
> row). An override PERMITS booking but never auto-verifies — the traffic light
> stays red so the override is visible in the audit. `sql/41_pre_expiry_ladder.sql`:
> `pre_expiry_offsets` (seeded T-90/60/30/14/7/1, per-requirement override
> supported), `expiry_reminders_sent` (once-only ledger keyed on
> `(item, expires_at, offset)` so a renewal auto-resets the ladder and nothing is
> double-sent), `candidate_help`/`candidate_label` on `compliance_requirements`,
> a `template` tag on `messages`, and `due_expiry_reminders()` (the send worklist
> — nearest due, unsent rung per current verified item). Both files are additive +
> idempotent (re-run to a no-op). The **`work-ready`** function gains optional
> `shift_date` + `buffer_days` inputs and returns `via_override`; the
> **`early-warnings`** function gains a fail-closed `?secret=CRON_SECRET` gate
> (now DEAD unless the secret is set AND matches) and a pre-expiry ladder step
> that replaces the old ad-hoc weekly chase (the expired→`expired`+needs_human
> step is unchanged). No new function or secret is required — `PUBLIC_SITE_URL`
> (already listed) is used as the portal deep-link, and `CRON_SECRET` (already
> listed) is now MANDATORY for `early-warnings` to run.

---

## 5. Schedule + inbound

☐ **Cron:** schedule `early-warnings` daily — Dashboard → Cron, or pg_cron:
`select cron.schedule('early-warnings','0 8 * * *', $$ select net.http_post('https://<dev>.functions.supabase.co/early-warnings?secret=<CRON_SECRET>') $$);`
☐ **Verification cron (Phase 2):** `sql/39_verification_schedule.sql` schedules
these for you IF pg_cron is installed and you set the two GUCs first:
`alter database postgres set app.functions_base_url = 'https://<ref>.functions.supabase.co';`
and `alter database postgres set app.cron_secret = '<CRON_SECRET>';` then re-run 39.
Otherwise schedule them manually:
`select cron.schedule('verification-drain','*/10 * * * *', $$ select net.http_post('https://<dev>.functions.supabase.co/verification?mode=drain&secret=<CRON_SECRET>') $$);`
`select cron.schedule('verification-sweep','30 6 * * *', $$ select net.http_post('https://<dev>.functions.supabase.co/verification?mode=sweep&secret=<CRON_SECRET>') $$);`
The daily sweep enqueues due annual/expiry re-checks and purges stale raw
`provider_jobs.response` payloads (retention). `mode=check` is called on demand by
compliance officers ("Verify now") under their own JWT.
☐ **Inbound email:** in your email provider (Brevo Inbound Parsing / SendGrid
Inbound Parse / Mailgun Routes), point inbound to
`https://<dev>.functions.supabase.co/inbound-email?secret=<INBOUND_SECRET>` and
map its payload to `{from,to,subject,text,html,attachments[]}`.
☐ **Deliverability:** in Brevo, verify the sending domain and add **SPF, DKIM,
DMARC** records. Don't send volume until this is green.

---

## 6. Host the front-end (pointed at the dev branch)

The pages (`dashboard.html`, `candidates.html`, `vacancies.html`,
`candidate-import.html`, `intake.html`) are static and read `js/config.js`.

☐ For dev testing, set `js/config.js` to the **dev** project's URL + anon key
(keep a copy of the prod values). Set `PUBLIC_SITE_URL` (step 3) to wherever
these are served (Vercel preview, a dev Pages site, or even local `file://`
for the staff pages — though Storage/login work best over http).

---

## 6a. Desks & roles (co-pilot)

Visibility is **siloed by desk**. Until you populate `staff`, *everyone on an
authorised domain is treated as admin and sees all* (safe bootstrap). To switch
on siloing once people have logged in once (so they exist in `auth.users`):

```sql
-- 1. make yourself admin (see everything + the control tower)
insert into candidate.staff (user_id, full_name, is_admin)
select id, 'Scott Lane', true from auth.users where email = 'you@daywebster.com';

-- 2. add a recruiter to one or more desks (they then see only those desks)
insert into candidate.staff (user_id, is_admin)
select id, false from auth.users where email = 'recruiter@daywebster.com';
insert into candidate.desk_members (desk_id, user_id)
select dk.id, u.id from candidate.desks dk, auth.users u
where dk.code = 'theatres' and u.email = 'recruiter@daywebster.com';
```

Candidates **auto-route** to a desk on qualification (Theatres → Theatres desk,
ward/A&E/ITU/HCA/RMN → Nursing North/South by region, neonatal/paeds →
Midwifery, ANP/ENP → Primary Care, etc.). Anything that can't be matched stays
**Unrouted** and shows in the dashboard + the cockpit's "Unassigned (to route)"
filter for an admin to place. (North/South routing needs the candidate's
`region` to read "North"/"South" — normalise region for full auto-split, or
route those manually for now.)

**Easier:** once deployed, use **`admin.html`** to do all of this by clicking —
toggle who's an admin, put recruiters on desks, create desks, and edit routing
rules. (The SQL above is just the manual fallback.) Staff appear in the admin
people list automatically after they've signed into any staff page once.

---

## 7. Smoke test (synthetic data only)

Work through the loop and watch the **dashboard** populate:

1. ☐ Open `intake.html` → register a fake candidate → appears in `candidates.html` as `sourced`.
2. ☐ In the cockpit, open them → **Run agent** → it replies + fills fields + requests docs.
3. ☐ `candidate-import.html` → import a tiny synthetic spreadsheet → rows land as `sourced`, deduped.
4. ☐ `vacancies.html` → create a vacancy → advert generates → open the public **jobs** page (`/functions/v1/jobs?slug=…`) and check it renders + has JSON-LD (view source).
5. ☐ Cockpit → send a **reference request** (via `reference-request`) to a test inbox; reply to it; confirm `inbound-email` ingests it and it shows in the review queue.
6. ☐ Manually hit `early-warnings?secret=…` → check it returns counts.
7. ☐ Run an `outreach-campaign` (referral/reengagement) against the synthetic bench.
8. ☐ Dashboard: KPIs, funnel, intake-by-channel, campaign cost-per-candidate, activity feed all populate.

Validate JSON-LD at search.google.com/test/rich-results before relying on Google for Jobs.

---

## 8. Promote to production

When dev is proven and the §11 terms are signed off:

1. ☐ Run `sql/10 → 19` on the **production** project (or merge the branch).
2. ☐ Expose `candidate` schema; create the `candidate-docs` bucket.
3. ☐ Set the same secrets with **production** values.
4. ☐ Deploy the functions to production; schedule cron; point the inbound webhook.
5. ☐ Restore `js/config.js` to production URL/anon key; set `PUBLIC_SITE_URL` to the live host.
6. ☐ Go live with inbound + Google for Jobs first; turn on paid channels once connectors + budgets are set.

---

## Data protection (Phase 2 verification)

Automated register/DBS/RTW checks transmit candidate PII to third parties, so
before turning any REAL adapter on (i.e. before setting its `secret_ref` env):

- ☐ **UK/EU region.** Confirm the Supabase project is hosted in a UK/EU region;
  keep candidate PII in-region.
- ☐ **DPA per provider.** Each regulator facility / aggregator / IDSP must be a
  **UK/EU processor under a signed DPA** (an aggregator is a disclosed
  sub-processor). No credential goes in `verification_providers` — only the
  `secret_ref` env name; the key lives in Function env / Supabase Vault.
- ☐ **Consent for DBS + RTW.** Those two are lawful only with recorded candidate
  consent + identifiers (`verification_consent`). Capture is stubbed in this POC —
  wire the capture policy before enabling `DBS_API_KEY` / `RTW_API_KEY`.
- ☐ **Retention.** The daily sweep purges raw `provider_jobs.response`/`request`
  payloads after 90 days (`purge_provider_job_responses`); the immutable
  `verification_events` audit skeleton (who/when/outcome/source_ref) is kept.
- ☐ **Fail-closed guarantee.** Until a real key is set, every real adapter returns
  `needs_human` (never a pass); the `sim` provider is for non-production demos only.

## Rollback

Everything is additive and isolated. To remove it entirely:
`drop schema candidate cascade;` (dev), delete the functions, delete the
`candidate-docs` bucket. The outreach system is untouched throughout.
