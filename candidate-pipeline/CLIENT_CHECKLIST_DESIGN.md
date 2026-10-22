# Compliance Portal — Client Checklist Auto-Fill (design + scoping)

Scoping deliverable (architecture, no code yet). Builds on the committed
candidate/compliance spine: `candidate.candidates`, `compliance_requirements` +
`compliance_items`, the versioned `requirement_sets`, the append-only
`verification_events` audit spine, the `provider_jobs` verification layer, the
private `candidate-docs` Storage bucket, and the fail-closed RLS helpers
`is_authorized_user()` / `is_admin()` / `is_compliance_officer()` /
`is_service_role()`. Mirrors the tone/decisions of `COMPLIANCE_PHASE1_DESIGN.md`
and `COMPLIANCE_PHASE2_SCOPING.md`.

## 0. The headline insight (what we are actually building)

> "Almost every client's checklist is different, but the information isn't."

So we do **not** build a form per client. We build the **canonical answer once**
— a *Compliance Passport* resolved live from the candidate's file — and treat
each client checklist as a **thin template + token→field map** laid over the
client's exact `.docx`. Onboarding a new client is a **one-time mapping
exercise**; every subsequent candidate for that client auto-fills with zero
further work.

Two locked constraints shape everything:
- **`.docx` only.** The engine is a Word mail-merge, not a PDF form-filler.
- **The client's exact form, filled in place.** We never regenerate a
  Day-Webster-branded equivalent. Their layout/wording/branding is byte-preserved;
  only the answer-blanks get populated. This rules out "extract fields → render
  our own template" and forces a **tokenize-their-doc-in-place** approach.

---

## 1. The Compliance Passport (canonical resolver)

A single SECURITY DEFINER function, officer/service-gated:

```
candidate.compliance_passport(p_candidate_id uuid) returns jsonb
  -- language plpgsql, stable, security definer, set search_path = candidate, public
  -- guard: if not (is_authorized_user() and is_compliance_officer())
  --          and not is_service_role() then raise 'not authorized'
```

It returns a **stable, versioned** JSON document — the token vocabulary that
every client map targets. Every field is an object, never a bare scalar, carrying
`provenance ∈ {verified, self_declared, derived, missing}`, `as_at`, and
`source_ref`. This is load-bearing: a client checklist can then state provenance
("DBS verified 01/06/2026 via Update Service") and a *missing* field is explicit,
never a silent blank (§3).

```jsonc
{
  "passport_version": 1,
  "candidate_id": "…",
  "generated_at": "2026-07-25T…Z",
  "fields": {
    "identity.full_name": { "value": "Jane A. Smith", "provenance": "self_declared", "as_at": null,        "source_ref": null },
    "reg.number":         { "value": "12A3456E",       "provenance": "verified",      "as_at": "2026-06-01", "source_ref": "job:…" },
    "reg.expiry":         { "value": "2027-03-31",     "provenance": "verified",      "as_at": "2026-06-01", "source_ref": "NMC…" },
    "rtw.status":         { "value": "Settled",        "provenance": "verified",      "as_at": "2026-05-02", "source_ref": "…" }
  }
}
```

### Canonical token vocabulary (the catalog)

Namespaced dotted keys, resolved from data that **actually exists**: identity
(`identity.first_name/.last_name/.full_name/.known_as/.dob/.email/.phone/.town/
.postcode/.region/.country`), role (`role.division/.discipline/.specialty/
.job_title`), registration (`reg.body/.number/.expiry/.verified/.checked_at/
.source_ref`), DBS (`dbs.number/.level/.issue_date/.update_service/.verified`),
right-to-work (`rtw.status/.share_code/.method/.expiry/.verified`), references
(`refs.covered/.years/.count`), OH/immunisations (`oh.status/.date`,
`immun.status/.date`), mandatory training (`training.status/.expiry/
.<module>.status/.expiry`), qualification (`qual.name/.status/.cert_date`),
indemnity, care cert, plus a **generic per-item** block
`item.<code>.status/.expires_at/.verified_at/.source_ref` for any requirement.

Real seeded requirement codes the generic block covers (from `sql/13` + `sql/27`):
`cv, right_to_work, proof_of_address, references_3yr, overseas_police_check,
nmc_registration, gmc_registration, hcpc_registration, qualification_cert,
indemnity, dbs_enhanced, dbs_enhanced_adults, dbs_enhanced_children,
occupational_health, immunisations, mandatory_training, care_certificate,
cii_qualification, financial_reference, level5_diploma, fit_person_declaration`.

Resolution rule for item-backed fields: pick the latest item via
`order by (status='verified') desc, updated_at desc limit 1` (same lateral pattern
as `recompute_candidate_status`), so a verified record wins over a stale one.

### Gap analysis — fields client checklists need that we DON'T store (load-bearing)

**(a) UI-ahead-of-schema — the migration is simply missing.** `candidates.html`
already renders inputs for `c.address`, `c.ni_number`, `c.compliance_status`,
`c.audited_by`, `c.audited_at`, and `compliance_items.ai_review`, but **no
migration adds these columns** (confirmed: zero matches across `sql/`). Today those
writes silently no-op. The passport needs `address` and `ni_number`, so this must
be fixed first.

**(b) Genuinely new fields** client forms routinely demand: `ni_number`, single-line
`address`, `nationality`, `gender`, `place_of_birth`, DBS `number`/`level`/
`issue_date`, RTW `share_code`, and a **per-module** mandatory-training breakdown
(Manual Handling, BLS, Safeguarding L2/L3, Fire, IG…).

**[DECISION — capture strategy]** Recommended split:
- **Promote high-frequency identity fields to first-class columns** on
  `candidate.candidates` (migration 43): `ni_number`, `address_line`,
  `nationality`, `gender`, `place_of_birth`. Stable, queryable, and the UI already
  half-expects them. *This also fixes gap (a).*
- **Everything long-tail / client-specific goes into a key-value table**:

```sql
create table candidate.candidate_attributes (
  candidate_id uuid not null references candidate.candidates(id) on delete cascade,
  key          text not null,          -- e.g. 'dbs.number', 'training.bls.expiry', 'rtw.share_code'
  value        text,
  provenance   text not null default 'self_declared'
               check (provenance in ('verified','self_declared','derived')),
  as_at        date,
  source_ref   text,
  updated_by   uuid references auth.users(id),
  updated_at   timestamptz not null default now(),
  primary key (candidate_id, key)
);
```

The resolver reads columns first, then overlays `candidate_attributes` for any
vocabulary `key` not satisfied by a column/item — so a new client form can
introduce a new data point (map once, capture once per candidate) with no
migration.

**PII note:** NI number, DBS number and share code are special-category-adjacent
identifiers. They live in the `candidate` schema behind officer RLS; they are
**never** logged in `provider_jobs` payloads and never returned to a non-officer.

---

## 2. Checklist template library + fill records (schema — migration 44)

### `candidate.checklist_templates` — the reusable client form + map

```sql
create table candidate.checklist_templates (
  id            uuid primary key default gen_random_uuid(),
  client_name   text not null,
  client_ref    text,
  name          text not null,                          -- 'St Elsewhere NHS — Agency Worker Checklist'
  version       int  not null default 1,
  status        text not null default 'draft' check (status in ('draft','active','retired')),
  bucket        text not null default 'checklist-templates',
  template_path text not null,                          -- tokenized .docx in Storage
  original_path text,                                   -- untouched original (audit / re-tokenize)
  field_map     jsonb not null default '[]'::jsonb,     -- token -> passport field
  static_answers jsonb not null default '{}'::jsonb,    -- constant answers (agency name, PAYE ref…)
  missing_policy text not null default 'block' check (missing_policy in ('block','annotate')),
  discipline_id uuid references candidate.disciplines(id) on delete set null,
  created_by    uuid references auth.users(id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (client_name, name, version)
);
```

`field_map` shape (one entry per placeholder inserted into the doc):

```jsonc
[
  { "token": "reg_number", "field": "reg.number",   "required": true,  "transform": null },
  { "token": "reg_expiry", "field": "reg.expiry",   "required": true,  "transform": "date_uk" },
  { "token": "dbs_status", "field": "dbs.verified", "required": true,  "transform": "yes_no" },
  { "token": "agency",     "field": null, "static": "Day Webster",     "required": false }
]
```
Transforms are a fixed, safe allow-list: `date_uk` (dd/mm/yyyy), `yes_no`, `upper`,
`title`, `with_provenance` (append "(verified 01/06/2026)"). No arbitrary code.

### `candidate.checklist_fills` — the audit record (append-only in spirit)

```sql
create table candidate.checklist_fills (
  id            uuid primary key default gen_random_uuid(),
  candidate_id  uuid not null references candidate.candidates(id) on delete cascade,
  template_id   uuid not null references candidate.checklist_templates(id) on delete restrict,
  template_version int not null,                         -- frozen: which version was used
  bucket        text not null default 'checklist-outputs',
  output_path   text not null,                           -- generated .docx
  values_snapshot jsonb not null,                        -- frozen passport values actually merged
  missing_fields  jsonb not null default '[]'::jsonb,    -- fields that were empty/needs-attention
  status        text not null default 'generated' check (status in ('generated','needs_attention','sent')),
  generated_by  uuid references auth.users(id),
  generated_at  timestamptz not null default now(),
  sent_at       timestamptz,
  sent_by       uuid references auth.users(id)
);
```

No UPDATE-of-history: the only mutation permitted is the `mark-as-sent`
transition, done via a SECURITY DEFINER RPC that stamps `sent_at/sent_by/
status='sent'`. Re-generation makes a **new row** (never edits an old fill), so
"we sent client X this exact file for candidate Y on date Z" is provable.

### Storage buckets (private, EU region)
- `checklist-templates` — blank tokenized templates + originals (officer/admin read; service write).
- `checklist-outputs` — generated PII-bearing checklists (officer read via short-TTL signed URL; service write).

### RLS
Both tables get RLS. `checklist_fills` has **no client INSERT/UPDATE policy** —
reads only for officers; all writes via SECURITY DEFINER RPCs, so a fill record can
never be forged or back-dated (same pattern as `verification_events`). Storage
policies restrict both new buckets to officer read / service write.

**[DECISION — who may create templates]** Recommended: officers create/edit,
admins only retire/delete.

---

## 3. The fill engine

**Recommendation: `docxtemplater` + `pizzip` in a Deno Edge Function
`checklist-fill`.** Justification:
- The whole system is Supabase-edge (Deno); both libs are pure-JS and load via
  `npm:docxtemplater` / `npm:pizzip` — the `npm:` convention already used for the
  Anthropic + Supabase SDKs. A separate service breaks the ops model.
- **The `docx` skill is Python (`python-docx`) and cannot run in Deno** — so it is
  not in the runtime path (may still help a human eyeball a template offline).
- docxtemplater merges data into `{token}` placeholders **without touching
  surrounding XML** — the client's layout/branding is preserved byte-for-byte
  outside the tokens. Exactly "the client's exact form, filled in place."

### `checklist-fill` contract
```
POST /functions/v1/checklist-fill
  body: { candidate_id, template_id, dry_run? }
  auth: officer session (Authorization: Bearer <user jwt>); email-domain gate (as compliance-import)
```
Flow: auth-gate → `compliance_passport(candidate_id)` (service role) → load
template + download tokenized `.docx` → build render data per `field_map` (resolve
`passport.fields[field].value`, apply `transform`, or `static`) → **missing-value
handling (never silent-blank):** docxtemplater `nullGetter` returns a visible
sentinel (`«NEEDS ATTENTION: NMC PIN»`) and collects the field into
`missing_fields`; a `required` field resolving empty →
- `missing_policy='block'` (default): still render (so the officer sees it) but set
  `status='needs_attention'`; **mark-as-sent is disabled** until an officer
  overrides — a compliance answer-blank is never silently empty.
- `missing_policy='annotate'`: render the sentinel in place so the client sees
  what's outstanding.

Then render/zip/upload to `checklist-outputs/<candidate>/<template>/<fill>.docx` →
insert `checklist_fills` via `record_checklist_fill()` (frozen `values_snapshot`,
`missing_fields`, `template_version`) → return `{ fill_id, signed_url (TTL 300s),
missing_fields, status }`. `dry_run` does steps 1–4 only and returns the resolved
values + missing list for the **review view** without writing anything.

**[DECISION — PDF copy]** Deliverable is the `.docx`. A flattened PDF for DW's own
audit pack needs headless LibreOffice/Gotenberg (no native Deno Word→PDF) — **Phase
2**, recommend deferring.

Fail-closed + audited: no path produces a "sent" checklist without a
`checklist_fills` row; a resolver/render error returns 5xx and writes nothing.

---

## 4. Onboarding a NEW client checklist (drag-drop → reusable template)

The "automation you create." An edge function `checklist-onboard` with modes
(like `compliance-import`'s map/commit): **detect → map → save**.

- **detect** — unzip with pizzip, walk `word/document.xml` paragraphs + tables;
  detect answer-blanks by four signals in priority order: (1) content controls /
  form fields (`<w:sdt>`, `<w:fldSimple>`, legacy `FORMTEXT`) — explicit slots,
  highest confidence; (2) empty table cell adjacent to a label cell; (3) underscore
  / dotted-leader runs; (4) colon-terminated label followed by a blank. Each blank
  gets a stable **anchor** (label text + positional XML path) for deterministic
  token insertion.
- **map (AI-assisted)** — reuse the Anthropic stack (`claude-opus-4-8`, structured
  `json_schema`) as `compliance-import` does. Input: detected blanks + label/context.
  Output (schema-constrained): each blank → a passport field key **or** `static`
  **or** `unmapped`. The vocabulary is passed as the closed allow-list (same
  "closed target set" trick as `KNOWN_CODES`) so the model can't invent a field.
  The AI sees **only the blank template's label text — never candidate data.**
- **officer review** — each blank, its label, the AI suggestion, and a dropdown of
  the full passport catalog to correct (or `static`/`ignore`). Nothing saves until
  confirmed.
- **save** — insert a docxtemplater placeholder at each blank's anchor.
  **Robustness rule:** because *we* control insertion, each token is written as a
  **single contiguous `<w:r>` run** — sidestepping docxtemplater's classic
  "token split across runs" failure. Surrounding XML (styles, borders, branding,
  headers/footers) untouched. Save tokenized `.docx` + keep the original + write the
  `field_map`.
- **fallback** — an unmapped blank stays `unmapped`; the officer manually picks from
  the catalog or marks "leave blank / client fills". A required blank with no
  passport field surfaces a **new data point** → add a `candidate_attributes` key.

**[DECISION — phase this]** Detection + AI-mapping is harder than the fill path.
**Phase 1 ships manual/assisted onboarding** (upload a `.docx` that already contains
`{tokens}`, or hand-map detected blanks); **Phase 2 adds the AI auto-tokenizer.**
The fill engine (§3) is identical either way.

---

## 5. UI — candidate profile + admin library

Match the existing vanilla-HTML + `supabase-js` + dark `dw-theme.css` conventions
(the `sb` client with `{ db:{ schema:'candidate' } }`, `.rpc()`, signed URLs via
`createSignedUrl(path, 300)`). No secrets in the page.

- **Candidate panel — new "Client checklists" card** in `candidates.html` `#detail`:
  a **dropdown** of `status='active'` templates; a **drag-drop zone** to add a new
  client `.docx` (→ onboarding flow / mapping review); **Generate (preview)** →
  `checklist-fill` `dry_run:true` → a **review view** listing every resolved value
  with its **provenance badge**, missing/needs-attention highlighted red;
  **Download** (real fill → signed URL) + **Mark as sent** (disabled while
  `needs_attention` unless overridden); **History** of fills (client, date, who,
  status, download).
- **Admin — "Checklist library"** in `admin.html`: table of templates; upload/replace
  a `.docx`; the **field-map editor** (per-blank label → passport-field dropdown +
  transform + required + static); activate / retire / new-version (editing an active
  form → new `version`, never mutate — existing fills froze their `template_version`).
- **Mark-as-sent RPC** `mark_checklist_sent(p_fill_id)` — officer-gated; sets
  `status='sent'`, `sent_at`, `sent_by`; refuses if `needs_attention` unless an
  admin overrides.

---

## 6. Data protection + audit (UK GDPR)

- Generated checklists carry PII (NI number, DOB, DBS, address) → **private buckets,
  EU/UK region**; access only via **short-TTL (300s) signed URLs** for an
  authenticated officer.
- **Every generation is audited**: `checklist_fills` records who/when/which
  template/version/candidate + a frozen `values_snapshot` (insert + single
  sent-transition only).
- PII minimisation: NI/DBS/share-code never enter `provider_jobs` payloads or any AI
  prompt. Retention: outputs subject to the same purge sweep as `candidate-docs`; the
  `checklist_fills` row is retained as the audit record.
- **[DECISION — verification_events cross-link]** Optionally append a
  `verification_events` row (`event_type='checklist_sent'`, `method='system'`,
  `source_ref=fill_id`, `actor=officer`) so a send appears in the candidate's unified
  audit timeline / audit pack. Requires widening the `event_type` check constraint —
  a small migration.

---

## 7. Phasing + open decisions

### Phase 1 — the core "pick client → auto-fill → send"
1. Migration 43: identity columns (`ni_number`, `address_line`, `nationality`,
   `gender`, `place_of_birth`) **fixing the UI-ahead-of-schema gap** + the
   `candidate_attributes` KV table + RLS.
2. Migration 43b: `compliance_passport()` resolver + grants.
3. Migration 44: `checklist_templates`, `checklist_fills`, RLS, storage policies,
   `record_checklist_fill()` + `mark_checklist_sent()`.
4. Buckets `checklist-templates`, `checklist-outputs`.
5. `checklist-fill` edge function (docxtemplater + pizzip).
6. Candidate-panel "Client checklists" card + admin "Checklist library" + manual
   field-map editor (upload a template that already has `{tokens}` **or** hand-map).

### Phase 2
- `checklist-onboard` AI auto-tokenizer (detect → AI-map → review → save).
- Optional PDF copy (LibreOffice/Gotenberg).
- Bulk-generate for a list of candidates going to one client.
- `verification_events` cross-link + audit-pack inclusion.

### Open decisions for the user
1. **Missing-field / NI-capture policy:** default `missing_policy='block'` (never
   send an incomplete compliance form) vs `annotate` (send with "outstanding"
   markers). And: is capturing NI number / DBS number in the candidate record
   acceptable under your data-minimisation stance?
2. **Who may create templates:** officers vs admin-only (recommended: officers
   create, admins retire).
3. **Template versioning never-mutate** — acceptable?
4. **"Mark as sent":** record-only (recommended, Phase 1) vs actually email the
   client the file (needs a client-contact record we don't yet have — Phase 2).
5. **PDF copy** for the internal audit pack, or `.docx`-only?
6. **Cross-link into `verification_events`** (small constraint-widening migration)?

### Load-bearing schema facts that forced choices
- `candidates.html` writes `ni_number`/`address`/`compliance_status`/`audited_by`/
  `audited_at`/`ai_review` that **have no backing columns** — Phase 1 must add the
  identity ones or the passport can't resolve address/NI.
- `is_compliance_officer()` already folds in `is_admin`, so officer-gated policies
  cover admins automatically.
- `provider_jobs`/`verification_events` show the house pattern: **no client write
  policy + SECURITY DEFINER RPCs = un-forgeable audit** — `checklist_fills` follows
  it exactly.
- Requirement codes are seeded per-discipline with **`null`-discipline globals**; the
  passport's generic `item.<code>.*` block must resolve the latest item by code
  regardless of discipline (verified-wins lateral pattern).
