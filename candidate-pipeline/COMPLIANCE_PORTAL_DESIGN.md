# Compliance Portal — "Work-Ready" Engine
### Design & architecture brief (v1, 2026-07-25)

An ambitious, automation-first **compliance portal** bolted onto the existing
placement & booking system, so that no agency worker can be put forward for a
shift until they are **fully compliant and work-ready** — audit-proof for the
NHS, and flexible enough to flex to other regulated sectors (adult social care /
CQC, children's services / Ofsted, education).

> Produced by the team: **Chuck** (architecture + NHS requirements research),
> a market/automation scout, and a repo-foundation audit — synthesised here.
> This is a design deliverable; no production code has been written yet.

---

## 0. TL;DR

- **Don't rebuild — extend.** The `candidate` schema already has a genuinely
  well-designed, config-driven compliance foundation (`compliance_requirements`
  as data, `compliance_items` state machine, expiry-sweep cron, AI document
  ingestion, human-gated acceptance). The new build is the **layer above it**.
- **The one thing missing that matters most:** there is **no computed
  "work-ready" status** and **nothing gates placement**. Today a recruiter can
  flip a candidate to `ready` with zero verified evidence. That is the core fix.
- **Add four capabilities:** (1) a computed work-ready **gate**; (2) **per-client
  / per-framework** requirement sets (not just per-discipline); (3) an
  **immutable audit trail + on-demand evidence pack**; (4) **automated
  verification adapters** (DBS Update Service, register checks, Right-to-Work,
  IDVT) with human-verify fallback.
- **Automation is real** for Right-to-Work/IDVT, e-signature, document OCR/AI and
  HCPC; **semi-automated** for NMC/GMC/GPhC, Occupational Health and CSTF
  training. Architect the friction points as evidence-workflows, not live APIs.
- **Differentiator vs. incumbents (Credentially, Access, Bullhorn):** AI document
  extraction + per-client/framework requirement mapping + automated
  re-verification scheduling, all native to our own placement system.

---

## 1. What "work-ready" actually means (cited requirements reference)

Everything here is time-bound or evidence-bound — which is exactly why it must
be **configuration (data), not hard-coded**.

### 1.1 NHS Employment Check Standards — the six mandatory checks

Every candidate put forward to an NHS assignment must satisfy all six; framework
auditors sample against them.

| # | Standard | Evidence the pack must hold | Auto-verifiable? |
|---|----------|------------------------------|------------------|
| 1 | **Identity** | 3 documents (photo ID + address + confirming identity) **or** a certified **IDVT** digital identity check | ✅ IDVT API |
| 2 | **Right to work** | UK/Irish passport, or a **Home Office online share-code** check (mandatory for eVisa/BRP), plus follow-up dates for time-limited leave | ✅ RTW share-code |
| 3 | **Professional registration & qualifications** | Live regulator register check (NMC/GMC/HCPC/GPhC/GDC/SWE), qualification certs, English-language competence | ✅ register lookups |
| 4 | **Employment history & references** | ≥2 written references obtained **directly from employers** covering a **full 3 consecutive years**; conduct/competence/suitability; gaps explored | ◐ reference API + human review |
| 5 | **Work health (occupational health)** | OH clearance / fitness-to-work; immunisation & bloodborne-virus status; **EPP clearance** where relevant (Hep B/C, HIV, MMR, Varicella, TB) | ◐ OH portal; mostly human |
| 6 | **Criminal record (DBS)** | Enhanced DBS with appropriate **barred-list** (adults and/or children); cert number recorded; **DBS Update Service** status checked | ✅ DBS Update Service |

Sources: [NHS Employers — check standards background](https://www.nhsemployers.org/articles/background-information-employment-checks-standards) · [Employment history & references standard 2025 (PDF)](https://www.nhsemployers.org/system/files/2025-06/employment-history-and-reference-checks-standard-1843.pdf) · [Right to work standard](https://www.nhsemployers.org/publications/right-work-checks-standard) · [Identity checks standard](https://www.nhsemployers.org/publications/identity-checks-standard).

### 1.2 Agency framework audits (what auditors check in a candidate pack)

- **CCS / GCA RM6277** (non-clinical) and **RM6281** (clinical) under the **NHS
  Workforce Alliance** (consolidating into **RM6397**). Suppliers return an
  **Assignment Checklist / compliance pack** per placement, pre-placement,
  QA-audited against **NHS ECS + Skills for Health (CSTF)**; non-NHS roles may
  require **BPSS** instead.
- **HTE** and **NHS LPP** run parallel frameworks with their own audit templates
  but the same underlying evidence set.
- **Design implication:** every requirement instance needs an **immutable audit
  trail** (who verified, when, method, source reference, document version), and
  the system must generate an **on-demand evidence pack** per candidate per
  framework/client. This is the single most audit-critical feature.

Sources: [RM6277 — GCA](https://www.gca.gov.uk/agreements/RM6277) · [RM6281 — GCA](https://www.gca.gov.uk/agreements/RM6281) · [NHS Workforce Alliance](https://thorntonandlowe.com/nhs-workforce-alliance-healthcare-solutions/).

### 1.3 Register verification & revalidation cycles (regulator-driven expiry)

| Regulator | Cycle | Method |
|-----------|-------|--------|
| **NMC** (nurses/midwives/NAs) | Revalidation **every 3 yrs** + annual fee/declaration | Online register / API |
| **GMC** (doctors) | Revalidation **every 5 yrs** (annual appraisal + RO recommendation) | GMC LRMP register |
| **HCPC** (AHPs) | Renewal **every 2 yrs**, profession-specific window | HCPC register |
| **GPhC** (pharmacists/techs) | **Annual** renewal + revalidation | GPhC register |

Design consequence: registration expiry is **regulator-driven, not a fixed
period** — the model needs a `regulator_driven` expiry rule that captures the
expiry date from the check itself.

Sources: [HCPC renewals](https://www.hcpc-uk.org/registration/registration-renewals/when-to-renew/) · [GPhC renewal](https://www.pharmacyregulation.org/pharmacists/revalidation-renewal/renew-your-registration) · [NMC revalidation](https://www.nmc.org.uk/revalidation/) · [revalidation cycles overview](https://expiryedge.com/glossaries/healthcare-compliance/revalidation/).

### 1.4 Statutory & Mandatory Training — Core Skills Training Framework (CSTF)

11 subjects, **default 3-year** refresh, with several annual variants (BLS,
Information Governance, practical Moving & Handling, Fire) by local/DSPT policy.
Exact per-subject/per-level frequencies to be seeded from the **CSTF v1.1
Subject Guide** as editable data: Equality/Diversity, Health & Safety, Conflict
Resolution, Moving & Handling (L2 practical annual), Fire (annual–2yr),
Infection Prevention & Control, Information Governance (annual), Resuscitation
(BLS annual / ILS / ALS), Safeguarding Adults (L1–3), Safeguarding Children
(L1–3), PREVENT/WRAP.

Sources: [CSTF Subject Guide v1.1 (PDF)](https://www.skillsforhealth.org.uk/wp-content/uploads/2021/07/CSTF-Eng-Subject-Guide-v1.1.pdf) · [CSTF overview](https://www.skillsforhealth.org.uk/news/core-skills-training-framework-overview/).

### 1.5 UK GDPR retention & residency (special-category data)

- **DBS certificate copies**: destroy normally **within 6 months** of the
  decision; retain only cert number + issue date + outcome unless a documented
  safeguarding-audit justification supports longer.
- **Data minimisation + purpose limitation**; segregate OH clinical data with the
  tightest access.
- **Residency:** keep the Supabase project in **London (eu-west-2)** — UK
  personal + special-category (health, criminal) data.
- Consequence: retention is **per requirement type** → definitions carry a
  `retention_months`, and a scheduled job purges/anonymises expired sensitive
  evidence.

Sources: [DBS retention / UK GDPR — DPO Centre](https://www.dpocentre.com/blog/dbs-checks-how-to-stay-compliant-with-the-uk-gdpr/) · [ClearCheck](https://clearcheck.co.uk/how-long-should-employers-retain-dbs-information/).

---

## 2. What we already have (build on this, don't rebuild)

From the audit of `candidate-pipeline/` (all DRAFT / not-yet-applied, isolated in
the Postgres `candidate` schema):

**Solid foundation — reuse:**
- **`candidate.compliance_requirements`** — the config table: requirements are
  rows, not code. Columns for `tier` (A–E, H), `required`, `expiry_rule` (jsonb),
  `coverage_rule` (jsonb, e.g. 3-yr continuous history), `needs_human`,
  discipline/specialty scoping, `unique(discipline_id, specialty_id, code)`.
  Already **seeded per discipline** (NMC/GMC/HCPC/CQC/Ofsted + registered-manager
  extras). *(`sql/10_candidate_schema.sql:249`, `sql/13_compliance_requirements.sql`)*
- **`candidate.compliance_items`** — per-candidate state machine
  (`not_started→requested→received→verifying→verified/unsuitable/expired`),
  channel, `source_confidence`, `expires_at`, `extracted` jsonb, `artefact_path`,
  `needs_human`, `human_notes`, `decided_by`. *(`sql/10_candidate_schema.sql:276`)*
- **`review_queue`** view — human worklist of everything `needs_human`.
- **Expiry sweep** — `expiring_items` view + `early-warnings` cron function
  (auto-chase weekly, mark expired → not work-ready). *(`sql/14_early_warnings.sql`)*
- **Inbound document ingestion + AI triage** — `inbound-email` classifies
  reference/document/reply/noise, maps to a requirement code, stores to a private
  bucket, lands `received` (never auto-verified), + referee confirmation
  handshake. *(`functions/inbound-email/index.ts`)*
- **`employment` timeline + `name_variants`** — schema ready for 3-year reference
  reconciliation.
- **Human-gated acceptance** — `candidate-agent` is autonomous only to
  `compliance`; `verified` is a terminal state only a human sets; registration
  numbers are stored, never AI-verified.
- RLS pattern (`candidate.is_authorized_user()`) + `verifyStaff` on functions.

**Missing for audit-grade (the build):**
1. **Computed work-ready status** — nothing derives "all required items verified
   & unexpired"; `ready` is an unenforced manual flag.
2. **Per-client / per-framework requirement sets** — requirements scope only by
   discipline/specialty; no client, framework, or set-versioning dimension.
3. **Placement gating** — no bookings link, nothing blocks placing a
   non-compliant candidate.
4. **Evidence-pack / audit export** — no per-candidate dossier generation.
5. **Automated verification integrations** — reg/DBS/RTW numbers stored but never
   checked.
6. **Immutable audit log** — acceptance decisions are mutable fields, not
   append-only history.
7. **Coverage-rule evaluator** — the 3-yr history rule is stored config with no
   code evaluating it against `employment`.

---

## 3. Target architecture

A **config-driven compliance framework**: "what makes a candidate work-ready" is
data — reusable **requirement definitions** bundled into **versioned requirement
sets** per sector / discipline / framework / client. Each candidate's assigned
sets resolve into per-candidate **requirement instances** whose statuses (from
automated adapters + human review) roll up into a single **work-ready status**
that **gates placement**. Every check is audit-logged; an **evidence pack** can
be generated on demand.

### 3.1 The three layers (definitions → sets → instances)

- **Definitions** — the canonical catalogue of every possible requirement, once.
  *We already have this shape* in `compliance_requirements`; extend it with:
  `evidence_type`, `verification_method` (auto/human/hybrid), `barred_list`
  coverage, `retention_months`, `regulator`, `provider_key`.
- **Requirement sets (NEW)** — named, **immutably-versioned** bundles per
  sector/discipline/framework/client (e.g. `NHS_RM6281_REGISTERED_NURSE`,
  `CQC_ADULT_SOCIAL_CARE_CARE_WORKER`), with per-item overrides (tier, validity,
  barred-list) and conditional inclusion. Versioning lets an audit prove *which*
  rule set applied when a worker was cleared.
- **Instances** — the existing `compliance_items`, one per applicable definition
  per candidate, driven by evidence + verification.

### 3.2 New tables (extending the `candidate` schema)

```
candidate.requirement_sets          -- versioned bundle (sector/discipline/framework/client)
candidate.requirement_set_items     -- definitions in a set + per-set overrides
candidate.candidate_requirement_sets-- which set(s) apply to a candidate; PINS set_version
candidate.verification_events       -- APPEND-ONLY audit trail (who/when/method/source)
candidate.candidate_compliance_status -- derived red/amber/green gate (low-sensitivity)
candidate.verification_providers    -- adapter registry (idvt, rtw, dbs, reg_nmc, …)
candidate.provider_jobs             -- queued/async verification jobs + request/response
```
Plus additive columns on `compliance_requirements` (evidence_type,
verification_method, barred_list, retention_months, regulator, provider_key) and
on `compliance_items` (external_ref already partially present; add
verification_method, waived_reason).

### 3.3 Work-ready computation + placement gate

- A `SECURITY DEFINER` function `recompute_candidate_status(candidate_id)`
  resolves each assigned set, joins the candidate's items, and writes
  `candidate_compliance_status`:
  - **green** = every **blocking**-tier item is `verified` and unexpired.
  - **amber** = all blocking verified but ≥1 item `expiring_soon`, or a
    non-blocking item open. *(placeable-with-caveat — see decisions)*
  - **red** = ≥1 blocking item unverified/expired → **placement gated**.
- Triggers on item / set-assignment changes recompute for that candidate; a
  nightly **pg_cron** job flips `verified → expiring_soon → expired` and enqueues
  reminders (extends the existing `early-warnings` loop).
- **The gate:** the booking system calls `is_work_ready(candidate_id, set_id) →
  boolean` (or reads `candidate_compliance_status`) before "put forward".
  **Fail-closed:** no green row = not work-ready.

### 3.4 The privacy boundary (security-critical)

Special-category data (criminal, health) means **status and evidence are
separated**:
- **Placement/recruitment staff** see only the **traffic light** (red/amber/green
  + counts) to gate placement — never DBS/OH evidence.
- **Compliance officers** (a new capability flag, mirroring the existing
  `is_authorized_user` / an `is_compliance` role) + admin see evidence.
- `candidate_compliance_status` is readable broadly (no sensitive data);
  `candidate_evidence` / `verification_events` are locked to compliance + admin
  (plus self-read for the candidate portal). Evidence lives in a **private
  bucket**, 60-second signed URLs only.
- `verification_events` is **append-only** (no update/delete policy) — the audit
  spine.

### 3.5 Automation as adapters

Each verification provider is a config row; work runs in **Edge Functions**
(service-role, server-side) calling best-of-breed APIs and writing back
`verification_events` + updating items. **Any provider failure degrades to human
review — never to auto-pass.**

---

## 4. Automation map — what we can actually automate

Legend: ✅ API today · ◐ semi-automated (portal/bulk + human sign-off) · ✋ manual.

| Step | Bucket | Notes / providers |
|------|--------|-------------------|
| **Right to Work / IDVT** | ✅ | Most mature. DIATF-certified IDSPs with real REST APIs: **Amiqus, TrustID, Yoti, Onfido**. ~low £/check. |
| **DBS Update Service** | ✅* | Free gov "Multiple Status Check" facility but **build-your-own** front-end; or wrap via umbrella-body APIs (Zinc, Disclosure Services). Needs candidate Update-Service subscription. |
| **HCPC register** | ✅ | Real **Employer Check API** + Multiple Registrant Search (100 at once). |
| **E-signature** | ✅ | **DocuSign** REST (eIDAS/QES add-ons); AES sufficient for most agency docs. |
| **Document AI / OCR** | ✅ | AWS Textract `AnalyzeID` / Google Document AI / Azure — ~£1.50/1k pages; extract expiry + reg numbers, cross-check against register/RTW. |
| **NMC register** | ◐ | Employer Confirmations bulk portal; no open official REST API. |
| **GMC register** | ◐ | Multi-number public search; no official API. |
| **GPhC register** | ◐ | Data Subscription Service (CSV/XML, ~£600/yr). |
| **Occupational Health** | ◐/✋ | No national API; certificate upload / bespoke per-provider feed. |
| **CSTF training** | ◐ | elfh / NHS Learning Hub free content; completion exportable per-LMS (PDF/CSV/API), no national verification API. |
| **References** | ◐ | Reference-automation providers (Xref, Refapp) + human review of gaps. |

**Build sequencing implication:** start automation with the ✅ steps (RTW/IDVT,
DBS Update Service, HCPC, OCR) for the fastest ROI; architect NMC/GMC/GPhC, OH and
CSTF as **semi-automated evidence workflows** (bulk check + scheduled re-check +
human sign-off + document capture).

Sources (automation): [Credentially](https://www.credentially.io/en-us/features-compliance) · [DBS Multiple Status Checking Guide (PDF)](https://assets.publishing.service.gov.uk/media/67449590ece939d55ce93006/Multiple_Status_Checking_Guide_V2.0_23112024.pdf) · [HCPC employer checks](https://www.hcpc-uk.org/employers/registration/checking-your-employees-registration/) · [NMC Employer Confirmations](https://www.nmc.org.uk/registration/employer-confirmations/) · [GPhC data subscription](https://www.pharmacyregulation.org/about-us/publications-and-insights/research-data-and-insights/gphc-registers-data) · [TrustID API](https://developer.trustid.co.uk/documentation/) · [Amiqus API](https://developers.amiqus.co/aqid/api-reference.html) · [Yoti developers](https://developers.yoti.com/) · [CSTF / Skills for Health](https://www.skillsforhealth.org.uk/integrated-solutions/core-skills-training-framework/) · [DocuSign QES](https://www.docusign.com/en-gb/products/electronic-signature/qualified-electronic-signature).

---

## 5. Build vs. buy — the competitive picture

Incumbents already do much of this: **Credentially** (UK, healthcare-native —
OCR extract-on-upload, auto DBS Update Service re-checks, GMC/NMC/HCPC/uCheck
integrations, ~60-day→~5-day claim), **The Access Group "Onboarded"**, and
**Bullhorn + Vetty**. **Panther** does per-client RAG compliance.

**Why build anyway (our edge):** we own the placement/booking system. A native
compliance engine gives us: (a) **AI document extraction** already partly built;
(b) **per-client/per-framework requirement mapping** with set-versioning for
audit; (c) **automated re-verification scheduling** wired straight into the
work-ready gate; (d) no per-seat SaaS margin on our own core workflow; (e) full
control of the audit/evidence-pack format framework auditors want. The
build-vs-buy call is a **[DECISION]** for stakeholders — this brief assumes
build + integrate best-of-breed verification APIs.

Sources (market): [Credentially NHS](https://www.credentially.io/nhs) · [Access Onboarded](https://www.theaccessgroup.com/en-gb/products/onboarded/) · [Bullhorn healthcare](https://www.bullhorn.com/uk/healthcare/) · [Panther](https://www.panther-software.co.uk/use-cases/nursing-recruitment/s52322/).

---

## 6. Decisions needed before build

1. **Booking-system relationship** — confirm the placement & booking system is
   this `candidate-pipeline` (same Supabase `candidate` schema) so the portal
   *extends* it; if it's separate, the portal exposes the work-ready status via
   an API/webhook the booking system calls to gate placement.
2. **Amber policy** — is "amber" placeable (conditional put-forward) or
   non-placeable? A product-policy call that shapes the gate.
3. **Build vs. buy** — custom build (assumed) vs. evaluate white-labelling
   Credentially/Access first. A cost/timeline call.
4. **Compliance-officer role** — add a dedicated `is_compliance` capability flag
   (recommended) to separate evidence access from recruiters, or reuse the
   existing staff role.
5. **Priority sectors** — NHS first (assumed); confirm whether to seed CQC /
   Ofsted / education sets in phase 1 or later (the engine is sector-agnostic
   either way).

---

## 7. Phased roadmap

**Phase 0 — Foundations (extend what exists)**
- Additive columns on `compliance_requirements` (evidence_type,
  verification_method, barred_list, retention_months, regulator, provider_key).
- `requirement_sets` + `requirement_set_items` + `candidate_requirement_sets`
  (versioned), seeded with the first NHS sets (RN, non-clinical).
- `verification_events` (append-only) + `candidate_compliance_status` +
  `recompute_candidate_status()` + triggers + the `is_work_ready()` gate.
- Extend `early-warnings` cron to flip expiring/expired + recompute status.

**Phase 1 — Portal & gate (make it usable and safe)**
- Compliance dashboard (candidates by status, what's expiring), candidate view
  (requirement checklist + evidence + verify/reject/waive), set management.
- Privacy-split RLS (evidence locked to compliance role; status readable to
  placement staff) + private evidence bucket.
- **Wire the placement gate** into the booking flow (fail-closed).
- Candidate self-service upload portal (extends the existing inbound spine).

**Phase 2 — Automation (highest-ROI adapters first)**
- ✅ adapters: Right-to-Work/IDVT, DBS Update Service, HCPC register, document
  OCR/AI extraction on upload.
- Evidence-pack generator (per candidate / per framework, on demand) + retention
  purge job for special-category evidence.

**Phase 3 — Depth & flex**
- ◐ workflows: NMC/GMC/GPhC bulk re-check + human sign-off, OH certificate
  capture, CSTF/LMS completion ingestion, reference automation + gap analysis
  (evaluate the stored `coverage_rule` against `employment`).
- Seed CQC / Ofsted / education requirement sets (config only — no code change).
- E-signature (DocuSign) for contracts/declarations; framework-audit exports.

---

*Appendix: full per-agent research (Chuck's cited requirements + schema sketch,
the market/automation scan with all source URLs, and the repo-foundation audit
with file:line references) is preserved in the session and can be attached in
full on request.*
