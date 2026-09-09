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
| `CHAT_PII_MODE` | `aggregate` (default) or `identifying` — used by `compliance-chat`. **Leave `aggregate` until the Anthropic DPA / zero-retention terms are recorded**: in aggregate mode candidate names/emails are stripped before any data reaches Anthropic (counts + coded reasons only). Switch to `identifying` only after the DPA is in place. |
| `BREVO_API_KEY` | from Brevo |
| `CANDIDATE_SENDER_EMAIL` | `candidates@candidates.daywebster.com` |
| `CANDIDATE_SENDER_NAME` | `Day Webster` |
| `REPLY_DOMAIN` | `candidates.daywebster.com` |
| `REPLY_LOCAL` | `compliance` |
| `INBOUND_SECRET` | any random string |
| `CRON_SECRET` | any random string |
| `WORK_READY_TOKEN` | any random string — shared bearer the external booking system sends to the `work-ready` gate AND the `booking-breach` recorder; both functions return 401 until this is set |
| `COMPLIANCE_ALERT_EMAIL` | central compliance mailbox for breach alerts + the daily breach digest — used by `booking-breach` and `early-warnings` when `compliance_settings.compliance_alert_email` is null |
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
| `booking-breach` | **false** | external booking system / officer (Bearer `WORK_READY_TOKEN`) — records a confirmed non-compliant booking + alerts; returns 401 until the token is set |
| `verification` | **false** | officers (`mode=check`, their JWT) + cron (`mode=drain`/`mode=sweep`, `?secret=CRON_SECRET`) + automation (Bearer `VERIFICATION_TOKEN`). Deploy with the `adapters/` folder alongside `index.ts`. |
| `checklist-fill` | **true** | officers (candidate panel) — Client Checklist Auto-Fill; resolves the passport (service role) + merges the client `.docx`. No new secrets. |
| `checklist-onboard` | **true** | officers (`admin.html` → **Checklist library** → *Onboard with AI*) — turns a raw client `.docx` into a tokenized template + field-map. Modes `detect`/`map`/`save`. Reuses **`ANTHROPIC_API_KEY`** (no new secret). The AI sees ONLY the blank template's label/context text — never candidate data. `save` writes `checklist_templates` with a **caller-JWT** data client (officer create/edit RLS), not the service role. |
| `compliance-chat` | **true** | officers/managers/admins (Compliance → **Assistant** tab) — Role-Scoped Compliance AI Chat. **Deliberately NOT service-role**: builds its data client with the ANON key + the caller's forwarded JWT so every `*_in_scope` RPC runs under the caller and RLS/scope apply. Secrets: `ANTHROPIC_API_KEY` + `CHAT_PII_MODE` (default `aggregate`). |
| `training-portal` | **false** | **candidate** (public `training.html`, no auth header — the opaque token IS the credential). Service-role trust boundary; token-scoped RPCs only; renders + stores the cert to `training-certs`. Never returns answer keys. Deploy with `_shared/cert.ts` alongside. |
| `training-authoring` | **true** | staff/officer (`training-admin.html` → **AI draft**). **Caller-JWT** data client (ANON + forwarded JWT, NOT service role). Reuses `ANTHROPIC_API_KEY`. Creates a **draft** module version only — never publishes; prompt sees no candidate data. |
| `certificate-verify` | **false** | **public** (`verify-cert.html`). Rate-limited; service role but ONLY calls `verify_certificate` (minimal whitelist). |

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
>
> **Compliance breach — record + alert + report (migration 42).**
> `sql/42_compliance_breach.sql` (after 34–40): makes a COMPLIANCE BREACH — a
> worker booked for a shift they are NOT compliant for (red, or bookable only via
> a manager override) — first-class. Adds:
> `noncompliant_items_on()` (the single source of WHICH required docs are elapsed
> as-of a date+buffer — mirrors the gate's math; used both to WARN and to snapshot);
> extends the append-only `verification_events` `event_type` CHECK (drop-then-add,
> strict superset) with `breach_logged`/`breach_acknowledged`/`breach_resolved`;
> adds `compliance_settings.compliance_alert_email` (the central mailbox);
> `compliance_breaches` (one row per booked-non-compliant placement, a JSONB
> snapshot of the elapsed docs, RLS = **officer read only, NO client write policy**
> — writes ONLY via the SECURITY DEFINER RPCs); `record_booking_breach()`
> (service-or-officer gated like the verification RPCs; NEVER logs a spurious
> breach — a genuinely compliant candidate RAISES `no breach`; idempotent on
> `(candidate,set,shift,booking_ref)`; appends one `breach_logged` audit event);
> `acknowledge_breach()` / `resolve_breach()` (officer lifecycle, idempotent,
> audited, core fields never rewritten); the `open_breaches` view + the
> `compliance_breach_report()` / `breach_exec_summary()` reporting RPCs (officer-
> gated, `rollup()` grand total via `is_total`). Additive + idempotent (re-run to
> a no-op). **New `booking-breach` edge function** (verify_jwt=false; reuses the
> **`WORK_READY_TOKEN`** bearer; add the **`COMPLIANCE_ALERT_EMAIL`** secret as the
> central-mailbox fallback): the booking system (or an officer) calls it when a
> flagged booking is CONFIRMED — it records the breach via `record_booking_breach`
> (service role) and sends ONE alert email to the DEDUPED recipient list (the
> candidate's compliance officer + that officer's overseeing manager via
> `staff.overseen_by` + the central mailbox), logging one `messages` row
> (`template='breach_alert'`). A clean 409 is returned if the candidate was
> actually compliant (nothing logged). The **`work-ready`** function (shift-date
> mode) now also returns `compliant` / `breach_if_booked` / `blocking_reasons` /
> `warning` (read-only — it logs nothing; the loud warning names the elapsed docs).
> The **`early-warnings`** cron gains a light **Step 3** daily backstop: if any
> breaches remain `open`, ONE digest email to the central mailbox summarising open
> breaches + DISTINCT candidates working non-compliant (`shift_date >= today`),
> logged as `template='breach_digest'` (skips silently if no mailbox or zero open;
> it does NOT re-alert per breach). **Config:** set the central mailbox once —
> `update candidate.compliance_settings set compliance_alert_email='compliance@daywebster.com' where id=true;`
> (or rely on the `COMPLIANCE_ALERT_EMAIL` secret). **Booking-system integration:**
> after `work-ready` returns `breach_if_booked:true` and the booker still confirms,
> the booking system POSTs the same identifiers to `booking-breach` (Bearer
> `WORK_READY_TOKEN`) to record + alert. **Data protection:** the breach alert
> email deliberately carries candidate-identifying compliance detail (full name,
> the elapsed documents + expiry dates, who booked) — necessary for the recipient
> to act — and is sent ONLY to authorised internal compliance staff (the assigned
> officer, their overseeing manager, and the central compliance mailbox). Keep
> that mailbox an internal, access-controlled address.

> **Client Checklist Auto-Fill — Phase 1 (after 42), apply in order:**
> `sql/43_candidate_attributes.sql`, `sql/43b_compliance_passport.sql`,
> `sql/44_checklist_templates.sql`. All additive + idempotent (re-run to a no-op).
>
> - **`sql/43` — fixes a live silent-drop bug + adds the KV overlay.**
>   `candidates.html` already renders and WRITES `address`, `ni_number`,
>   `compliance_status`, `audited_by`, `audited_at` (and `compliance_items.ai_review`)
>   but **no migration ever added those columns** — every one of those writes has
>   been silently no-oping. 43 adds them (`add column if not exists`, exact UI
>   names) plus the identity columns the passport needs (`nationality`, `gender`,
>   `place_of_birth`). It also adds `candidate.candidate_attributes` — the long-tail
>   key-value overlay (`dbs.number`, `rtw.share_code`, `training.<module>.expiry`, …)
>   the passport reads for any vocabulary key no first-class column/compliance_item
>   satisfies. RLS: officer read + officer upsert, no anon.
> - **`sql/43b` — `compliance_passport(candidate_id)`.** SECURITY DEFINER, gated
>   `(is_authorized_user() and is_compliance_officer()) or is_service_role()`.
>   Returns the versioned JSON token vocabulary — EVERY field an object
>   `{value, provenance, as_at, source_ref}`; a field with no data is returned
>   EXPLICITLY as `provenance:'missing'`, never omitted. Resolves identity from
>   columns, role from the division→discipline→specialty joins, and item-backed
>   fields from the latest `compliance_item` per requirement `code` (verified-wins
>   lateral), then overlays `candidate_attributes`. Grant execute to authenticated,
>   service_role.
> - **`sql/44` — the template library + fill audit.**
>   `checklist_templates` (one row per client-form VERSION: tokenized `.docx` path +
>   token→field map + per-template `missing_policy` DEFAULT `'block'`). RLS: officers
>   read/create/edit; **only admins retire** (the update `WITH CHECK` blocks a
>   non-admin flipping `status='retired'`) **or delete** (admin-only DELETE policy).
>   `checklist_fills` (the immutable "sent client X this file for candidate Y on Z"
>   record) has **officer SELECT only and NO insert/update/delete policy** — every
>   write is via the SECURITY DEFINER RPCs, so a fill can never be forged or
>   back-dated (same un-forgeable pattern as `verification_events`). Extends the
>   append-only `verification_events` `event_type` CHECK (drop-then-add, strict
>   superset) with **`checklist_sent`**. RPCs: `record_checklist_fill()`
>   (service-or-officer; freezes `template_version`; the SENT action is always
>   audited) and `mark_checklist_sent(fill_id, override)` (officer-gated; refuses a
>   `needs_attention` fill unless `override AND is_admin()`; appends ONE
>   `checklist_sent` audit event; idempotent). The file also adds officer-read
>   `storage.objects` policies for the two buckets — **guarded** so it applies clean
>   on a bare Postgres harness with no `storage` schema.
>
> **Storage — two PRIVATE buckets (EU/UK region), created at deploy time** (like
> `candidate-docs`, Supabase bucket creation is an API/dashboard action, not SQL):
> ☐ `checklist-templates` — blank tokenized templates + originals (officer read;
> service write). ☐ `checklist-outputs` — generated PII-bearing checklists (officer
> read via 300s signed URL; service write). The officer-read RLS object policies are
> installed by `sql/44`; the service-role edge function bypasses storage RLS for
> writes, so no write policy is needed. Create both via the dashboard (Storage → New
> bucket, **Private**) or `supabase storage` / the management API.
>
> **`checklist-fill` edge function** (`functions/checklist-fill/index.ts`,
> **verify_jwt=true**, officers): resolves `compliance_passport` (service role),
> downloads the tokenized `.docx` from `checklist-templates`, merges via
> `npm:docxtemplater` + `npm:pizzip` (client layout/branding byte-preserved outside
> the tokens), applies the safe transform allow-list
> (`date_uk`/`yes_no`/`upper`/`title`/`with_provenance`/`static`), and a `nullGetter`
> that renders a visible `«NEEDS ATTENTION: <label>»` sentinel + collects the gap. A
> required field left empty → `missing_policy='block'`: `status='needs_attention'`
> (mark-as-sent stays disabled until an admin override); `='annotate'`: renders the
> sentinel, `status='generated'`. `dry_run:true` returns the resolved values +
> missing list for the review view and **writes nothing**; a real run uploads to
> `checklist-outputs/<cand>/<template>/<uuid>.docx`, calls `record_checklist_fill`,
> and returns a 300s signed URL. Fail-closed: auth fail 401; any resolver/render/
> upload error 5xx and nothing recorded (`record_checklist_fill` runs only after a
> successful upload). No new secrets are needed (`SUPABASE_URL` /
> `SUPABASE_SERVICE_ROLE_KEY` are injected).
>
> **`checklist-onboard` edge function** (`functions/checklist-onboard/index.ts`,
> **verify_jwt=true**, officers — Phase 2, the AI auto-tokenizer). Three modes:
> **`detect`** downloads the raw client `.docx` from `checklist-templates`, unzips
> (`npm:pizzip`) and walks `word/document.xml` to find answer-blanks by four signals
> in priority order — content controls/form fields (`<w:sdt>`/`<w:fldSimple>`/legacy
> `FORMTEXT`), an empty `<w:tc>` cell adjacent to a label cell, underscore/dotted-leader
> runs, and a colon-terminated label followed by a blank — returning each with a
> STABLE positional anchor + a suggested token. **`map`** reuses the Anthropic stack
> (`claude-opus-4-8` + structured `json_schema`) to map each blank to a passport field
> key from the CLOSED vocabulary (enum-constrained + re-validated server-side, same
> closed-target trick as `compliance-import`'s `KNOWN_CODES`), `static`, or `unmapped`;
> **the prompt carries ONLY the blank labels/context — never candidate data** (it is a
> blank client form). **`save`** re-walks the ORIGINAL doc and splices a docxtemplater
> `{token}` at each confirmed anchor as a **single contiguous `<w:r>` run** (sidesteps
> the split-run failure), leaves all surrounding XML/branding untouched, uploads the
> tokenized `.docx` next to the untouched original, and INSERT/UPDATEs the
> `checklist_templates` row (`status='draft'`, with the `field_map`) using a
> **caller-JWT data client** (ANON key + forwarded JWT) so the officer create/edit RLS
> applies — NOT the service role for that write. Reuses the existing
> **`ANTHROPIC_API_KEY`** secret (no new secret). Fail-closed: auth fail 401; any
> parse/AI/storage/RLS error 4xx/5xx with a generic message and nothing partial left.
>
> **UI:** `candidates.html` gains a **Client checklists** card in the candidate
> slide-over (active-template dropdown → Generate/preview with provenance pills →
> Download real fill → Mark as sent, disabled while `needs_attention` → fill
> History; plus a drag-drop stub that uploads a new `.docx` to the inbox and hands off
> to the Admin AI onboarding).
> `admin.html` gains a **Checklist library** tab: **Onboard with AI** (drag-drop a raw
> client `.docx` → `detect` → `map` → a **mapping review** table where each detected
> blank shows its label, the AI-suggested passport field, a dropdown of the full
> passport catalog to correct — or `static`/`unmapped` — plus transform/required/static,
> with unmapped-but-required blanks flagged → **Save template** → `save`); the manual
> path (upload a pre-tokenized `.docx`) and the token→field map editor
> (passport vocabulary + transform + required + static + per-template `missing_policy`,
> activate/retire/new-version) still work. All reads run under the officer session +
> RLS; no secrets in the pages.
>
> **Data protection (UK GDPR):** generated checklists carry special-category-adjacent
> PII (NI number, DOB, DBS number, address). Keep both buckets **private, EU/UK
> region**; access ONLY via short-TTL (300s) signed URLs for an authenticated
> officer. NI number is a first-class `candidates` column and DBS number lives in
> `candidate_attributes` — both behind officer RLS, **never** returned to a
> non-officer, **never** logged to `provider_jobs` payloads, and **never** placed in
> any AI prompt. Outputs are subject to the same purge sweep as `candidate-docs`; the
> `checklist_fills` row is retained as the immutable audit record.

> **Role-Scoped Compliance AI Chat (v1)** — apply `sql/45_compliance_manager_role.sql`
> then `sql/46_compliance_chat.sql` (after 34/36/41/42). Both additive + idempotent
> (add-column-if-not-exists, create-or-replace, tables if-not-exists — re-run to a
> no-op). Do NOT touch the bodies of `sql/34/36/42`; the chat simply never calls the
> whole-bench RPCs.
> - **`sql/45` — the `is_manager` role (the THIRD compliance tier).** Adds
>   `staff.is_manager` + `candidate.is_manager()` (mirrors `is_admin()`, same
>   bootstrap-allow posture; admins are managers too). **Widens
>   `is_compliance_officer()`** to `is_compliance OR is_manager OR is_admin` (a
>   manager can do everything an officer can). Reusable by the training engine later.
>   Tiers: officer (`is_compliance`) → own candidates; manager (`is_manager`) → ALL
>   compliance data + manager-only actions; admin → everything.
> - **`sql/46` — the chat data layer.** `chat_scope()` (no args; reads `auth.uid()`;
>   `all_access = is_manager()`, else `officer_ids = {auth.uid()}`) + seven
>   SECURITY-DEFINER `*_in_scope` read RPCs (`chat_stats`, `chat_urgent`,
>   `chat_expiring`, `chat_breach_summary`, `chat_workready`, `chat_candidate_lookup`,
>   `chat_officer_breakdown` — the last **manager-only**, raises otherwise), each with
>   the `is_authorized_user() and is_compliance_officer()` gate and a scope WHERE
>   clause (`v_all or compliance_officer = any(v_ids)`) derived from `chat_scope()` —
>   **never** a model argument. These are thin projections over the EXISTING
>   `candidate_overall_status` / `open_breaches` / `compliance_worklist` views + the
>   `due_expiry_reminders` latest-item pattern; the leaky whole-bench
>   `compliance_officer_report` / `compliance_breach_report` / `compliance_dashboard`
>   (which take an arbitrary officer id) are **never** exposed to the chat.
>   `chat_candidate_lookup` returns zero rows identically for an unknown OR
>   out-of-scope candidate (never leaks existence). Plus `compliance_chat_log`
>   (append-only audit; officer reads OWN rows, manager/admin read all; NO client
>   write) + `log_compliance_chat()` (the sole, SECURITY DEFINER writer — stores tool
>   names+inputs+row-counts only, never candidate rows).
>
> **`compliance-chat` edge function** (`functions/compliance-chat/index.ts`,
> **verify_jwt=true**): domain-gate (401) → **caller-JWT data client (ANON key +
> forwarded `Authorization`, NOT service role)** → `chat_scope()` once (role label;
> 403 if not an officer) → tool array (`chat_officer_breakdown` only for
> manager/admin) → manual agentic loop (each `tool_use` → the matching `*_in_scope`
> RPC via the caller client) → `log_compliance_chat()` → `{answer}`. Single response,
> `max_tokens 1500`, effort `low`. **`CHAT_PII_MODE`** (default `aggregate` until the
> Anthropic DPA is recorded): aggregate strips candidate names/emails before any data
> reaches Anthropic; `identifying` surfaces names once the DPA is in place. The mode
> is stamped into every log row. Fail-closed throughout.
>
> **UI:** `compliance.html` gains an **Assistant** tab (shown to officers; extra
> manager/admin suggested prompts) — a scrolling thread + input + role-aware chips, a
> persistent "answers reflect only the candidates you're authorised to see" note and
> an aggregate-mode note. It reuses the page's `sb.auth.getSession()` +
> `fetch(SUPABASE_URL + '/functions/v1/compliance-chat')` with the caller's Bearer
> token; no secrets, no data beyond the caller's scope.

> **Mandatory-Training engine — Round 1 SQL (migrations 47–52).** Apply in order
> after 46: `sql/47_training_catalogue.sql` (the `training_modules` catalogue + the
> 1:1 `requirement_code` mirror trigger + `sync_training_requirements()` + demotes
> the legacy monolithic `mandatory_training` to advisory), `sql/48_training_versions.sql`
> (immutable, versioned `module_versions` + the server-side `training_questions`
> answer bank [SELECT is **manager-only**] + the authoring RPCs
> `save_module_version` / `add_training_question` / `submit_module_for_review` /
> `approve_module_version` [manager] / `publish_module_version` [manager] + the
> immutability triggers; widens the `verification_events` event_type/method CHECKs),
> `sql/49_training_delivery.sql` (assignments, hashed single-use magic-links +
> sessions, attempts; `assign_training` [returns the RAW token once, stores only
> sha256], `consume_training_link` / `start_training_attempt` [keys STRIPPED in SQL]
> / `submit_training_attempt` [grades server-side]), `sql/50_training_records.sql`
> (`issue_training_record` — the single choke point that mints the cert id + the
> verified/expiring compliance item hook + `verify_certificate`'s minimal whitelist),
> `sql/51_training_manual_entry.sql` (`record_manual_training`, **manager-only**),
> `sql/52_training_seed.sql` (the 14-module clinical catalogue + two fully-authored
> published seed modules). All additive + idempotent.
>
> **Mandatory-Training engine — Round 2 (delivery layer).** Storage + three edge
> functions + four pages. **All DRAFT — not yet deployed.**
> - ☐ **Storage — one PRIVATE bucket `training-certs`** (EU/UK region, created at
>   deploy time like `candidate-docs` — a dashboard/API action, not SQL). Holds the
>   branded HTML certificates at `<candidate_id>/<certificate_id>.html`; PII-bearing,
>   so **private + short-TTL (300s) signed URLs only**. The service-role functions
>   bypass storage RLS for writes; staff read via `createSignedUrl` under their
>   session — add an officer-read `storage.objects` policy for `training-certs` if you
>   want staff reads without the service role.
> - **`training-portal`** (`functions/training-portal/index.ts`, **verify_jwt=false**)
>   — the passwordless candidate delivery + assessment trust boundary. Called by the
>   public `training.html` with **no Authorization header**: the opaque magic-link /
>   session token IS the credential. Runs as **service role** but every action is a
>   token-scoped SECURITY DEFINER RPC (`consume`→`consume_training_link` after
>   sha256-hashing the raw link; `start`→`start_training_attempt` [keyless];
>   `submit`→`submit_training_attempt` [server-graded]; `status`). On a pass it renders
>   the branded HTML cert via `_shared/cert.ts`, uploads it to `training-certs`, writes
>   `training_records.certificate_path`, and returns a 300s signed URL. **Never returns
>   correct answers.** Best-effort per-isolate rate limit + generic errors (no
>   enumeration). No new secrets (`SUPABASE_URL` / `SUPABASE_SERVICE_ROLE_KEY` injected).
> - **`training-authoring`** (`functions/training-authoring/index.ts`,
>   **verify_jwt=true**, staff/officer) — AI-assisted drafting. Email-domain gate, then
>   a **caller-JWT** data client (ANON key + forwarded `Authorization`, NOT service
>   role) so `save_module_version` / `add_training_question` run under the officer's
>   `is_compliance_officer()` gate. Reuses the `compliance-import` Anthropic stack
>   (`claude-opus-4-8` + structured `json_schema`) and the existing **`ANTHROPIC_API_KEY`**
>   secret. Produces a **draft** `module_versions` (`ai_generated=true`, `ai_model`); it
>   **never** submits/approves/publishes (a human officer reviews, a manager
>   approves + publishes). The AI prompt is built from the module **subject/brief only —
>   never any candidate data**.
> - **`certificate-verify`** (`functions/certificate-verify/index.ts`,
>   **verify_jwt=false**, public) — GET `?certificate_id=` or POST `{certificate_id}`.
>   Rate-limited, generic errors. Service role, but its ONLY data path is
>   `verify_certificate(p_certificate_id)`, whose minimal whitelist (module, subject,
>   SfH ref, dates, status, initials — **no** name/DOB/score) is passed through
>   unchanged. Called by the public `verify-cert.html`. No new secrets.
> - **UI:** `training-admin.html` (new; in the staff topnav) — dark-theme authoring /
>   approval console (catalogue + KB/question editor + **AI draft** button →
>   `training-authoring` + the draft→submit→**approve**→**publish** pipeline
>   [approve/publish + **manual entry** render only for managers] + **assign training**
>   → magic link). `candidates.html` gains a **Training** card in the slide-over
>   (per-candidate records with status/score/completion/expiry, cert download via a
>   `training-certs` signed URL, **Assign training**, and attempt history). Both use the
>   anon key + officer session; the DB (RLS + RPCs) is the sole authority; no answer
>   keys leave the server (question SELECT is manager-only).
> - **Hosting the public pages:** `training.html` (candidate flow) and
>   `verify-cert.html` (certificate checker) are static, **light** (GOV.UK-style /
>   neutral), hold **no Supabase key** and talk only to their edge function. Host them
>   wherever `PUBLIC_SITE_URL` points (they only need the project's Functions base URL,
>   which is set inline near the top of each file — update the project ref on deploy).
>   `training-admin.html` builds the magic link as `PUBLIC_SITE_URL/training.html?token=…`
>   from `location.origin`, so serve `training.html` at the same origin as the staff
>   pages (or adjust the base).

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
