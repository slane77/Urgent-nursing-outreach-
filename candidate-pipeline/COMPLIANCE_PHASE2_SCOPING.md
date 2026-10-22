# Compliance Portal — Phase 2 scoping
### Automated register / DBS / Right-to-Work verification (pre-placement + annual)

Scoping deliverable (research + architecture). No code yet. Builds on the
committed Phase 0/1 hooks (`compliance_items`, the append-only `verification_events`
spine, the fail-closed `recompute_candidate_status` → `is_work_ready` gate, and
the deferred `verification_providers`/`provider_jobs` sketch).

## 0. The headline question: "can we scrape the official register sites?"

**No — and we don't need to.** Scraping is the wrong foundation for an audit-grade
compliance gate:
- UK registers are protected by **database right** + site **terms** that prohibit
  bulk/automated extraction; regulators channel bulk use through licensed feeds
  (GMC's paid download licence, GDC refusing to sell copies) — a clear signal.
- Regulator sites run **active anti-bot** protection (the research itself hit
  HTTP 403 on NMC/HCPC/GPhC), so scraping is fragile and rate-limited.
- A scraped screen-read is **weak evidence** for a framework/CQC audit or a
  tribunal, and raises UK-GDPR lawful-basis concerns.

The compliant, robust route is **official APIs / official bulk facilities / a
licensed aggregator (a named data processor under a DPA)** — which is enough to
automate real-time pre-placement checks and batched annual re-checks. Scraping is
at most a last-resort manual fallback for GDC/GOC.

---

## 1. Per-regulator verification landscape (July 2026, cited research)

| Body | Route | Automatable? |
|---|---|---|
| **HCPC** (AHPs, ODPs, biomed scientists) | **Employer Check API** (real API; apply via HCPC Comms) + free Multiple Registrant Search (100 at once) | ✅ **official real-time API** |
| **NMC** (nurses, midwives, NAs) | Employer Confirmations (free bulk web tool); no public API | ◐ official facility |
| **GMC** (doctors) | Free LRMP multi-number search; **register download licence** ≈ £815/yr for bulk | ◐ facility / licensed feed |
| **GPhC** (pharmacy) | **Data Subscription Service** — daily XML/CSV, **£600/yr** (£400 premises-only), licence agreement | ◐ licensed feed |
| **Social Work England** | Bulk search (100) + **CSV export**, free | ◐ official facility |
| **GDC** (dentists) | Individual online lookups only; **no bulk copies sold** | ✋ manual / scrape-only (not recommended) |
| **GOC** (opticians) | Individual lookups + manual "registrant check" letter | ✋ manual |
| **DBS Update Service** | Online status check — needs candidate consent + details; no gov API | ✋ manual / via aggregator |
| **Right to Work** | Share-code online check (free) + **IDVT via certified IDSPs** (Yoti/TrustID/Credas…) — commercial APIs | ✅ IDSP APIs |
| **GP Performers List** | NHS England / PCSE — separate from GMC registration | ◐ separate check |

**No single vendor holds official APIs to all regulators** (because most
regulators don't offer one). **Licensed aggregators** (Credentially, The Access
Group) stitch the official facilities together into one integration — advertising
NMC/GMC/HCPC/GPhC + DBS/uCheck coverage — but pricing is quote-based and "API to
NMC/GMC" usually means automated lookups against the official facility, not an
official regulator API. IDSP vendors cover the RTW/DBS-ID slice with real APIs.

Sources: HCPC employer checks + MRS; NMC Employer Confirmations; GMC LRMP + data
licence; GPhC Data Subscription; Social Work England employer search; GDC/GOC
registers; gov.uk DBS Update Service + Right-to-Work guidance (Jun 2025) +
DIATF certified-IDSP register.

---

## 2. Architecture — a provider/adapter layer over the existing gate

Authoritative, fail-closed verification that writes through the **existing**
`compliance_items` + `verification_events` spine, so the work-ready gate reacts
with **no change to its logic**. Automation may only ever auto-verify a **clean,
unambiguous match**; every failure/ambiguity/no-match degrades to **human review,
never auto-pass**.

### 2.1 New tables (migration 37)
- **`verification_providers`** — source registry: `provider_key`, `kind`
  (`realtime_api` | `bulk_facility` | `aggregator` | `manual`), `regulator`,
  `endpoint`, non-secret `config` (a `secret_ref` naming an env var), rate limit,
  max concurrency, `recheck_months` (annual default). **Credentials live in
  Function env / Supabase Vault — never in this table, never client-side.**
- **`provider_jobs`** — the queue + request/response audit: candidate/requirement/
  item, `trigger` (`pre_placement`/`annual_recheck`/`pre_expiry`/`manual`),
  `status` (`queued`→`running`→`succeeded`/`needs_human`/`failed`), attempts +
  backoff (`run_after`), frozen `request`/`response`, `outcome`, `source_ref`.
  A **unique index on (candidate, requirement) while in-flight** guarantees
  idempotency; a completed job is never re-run — a re-check is a new row.
- **`verification_consent`** — DBS/RTW are lawful only with candidate identifiers
  + consent; captured here (blocks DBS/RTW until a consent-capture policy is set).

### 2.2 Requirement wiring (migration 37)
Add `regulator`, `provider_key`, `verification_method` to `compliance_requirements`
(explicitly deferred from Phase 1) and wire the register/DBS/RTW codes.
**Load-bearing fix:** the register codes currently have `expiry_rule = null`
("never expires"), which is wrong for annual-renewal registers — switch them to
`{"type":"regulator_driven"}` so the provider writes the regulator's own renewal
date into `expires_at` and the existing expiry sweep + amber window start working
for registrations automatically.

### 2.3 RPC + worker (migrations 38/39, `functions/verification/`)
- **`enqueue_verification(candidate, code, trigger)`** — officer- or service-gated;
  sets the item `verifying` **only if not already `verified`** (an annual re-check
  must not drop a valid registration to red while in flight); idempotent.
- **`claim_provider_jobs(worker, provider_key, limit)`** — `FOR UPDATE SKIP LOCKED`
  + per-provider concurrency cap → safe parallelism, never hammers a facility.
- **`apply_verification_result(job, outcome, expiry, source_ref, …)`** — maps
  outcome→item status (only `verified` outcome ever sets `verified`), captures the
  regulator expiry, appends **one immutable** `verification_events` row, and the
  existing item trigger recomputes the gate. A lapsed re-check flips the candidate
  off work-ready and into the review queue.
- **`fail_provider_job(...)`** — retry with exponential backoff (honour 429
  `Retry-After`); after max attempts → `failed` + item `needs_human` (provider
  outage degrades to human review, never to a pass).
- **`enqueue_due_rechecks(limit)`** — daily set-based sweep of register/DBS/RTW
  items due (past `recheck_months` or nearing expiry), rate-spread via `run_after`.
- **`functions/verification/`** — one dispatcher (`mode = check | drain | sweep`),
  adapters as modules behind one interface (`realtime` / `bulk` / `aggregator` /
  `manual`). The dispatcher maps any `matchConfidence !== 'exact'` → `needs_human`
  centrally, so no adapter can auto-pass an ambiguous match. Service-role only;
  reaches the DB solely through the fail-closed definer RPCs.
- **Cron:** `verification-drain` every ~10 min (process the queue) +
  `verification-sweep` daily (top up re-checks) — extends the `early-warnings`
  pattern. Scale: ~15k on a 12-month rolling cadence ≈ ~41 re-checks/day baseline
  — comfortably under any facility's limits with the rate-spreading.

### 2.4 Pre-placement flow
Booking/officer → `verification?mode=check` → adapter verifies → result written →
then the existing `work-ready` gate returns the fresh status. The gate stays
read-only/fast and unchanged; there is **no code path from a provider error to
`verified`**, so it remains fail-closed.

### 2.5 UI (`compliance.html`)
Per-item **"Verify now"** (officer) + a verification pill (auto-verified / queued /
running / needs-human / provider-error) with last-checked + `source_ref`; a
dashboard **register-checks** tile (queued/running/failed/needs-human, auto-verified
last 24h). Failures already surface via the existing review queue / `needs_human_count`.

### 2.6 Data protection
Provider calls transmit candidate PII to third parties → each provider/aggregator
must be a **UK/EU processor under a signed DPA** (aggregator = disclosed
sub-processor); minimise PII in `provider_jobs.request`; set a **retention/purge**
on raw `response` payloads; confirm the Supabase project is UK/EU region.

---

## 3. Proposed phasing

- **Phase 2a (disciplines already exist):** **NMC, GMC, HCPC** register checks +
  **DBS Update Service** + **Right-to-Work** share-code/IDVT. Delivers the core
  "no one is placed without a live NMC/GMC/HCPC check" plus DBS/RTW.
- **Phase 2b:** **GPhC, GDC, GOC, Social Work England, GP Performers List** — these
  need new disciplines/specialties seeded (pharmacy/dentistry/optometry/social work
  aren't in the taxonomy yet) plus their own adapters/requirement codes.

## 4. Decisions for you
1. **Build vs. buy — the big one.** Build our own adapters per regulator (free
   official facilities exist for NMC/GMC/HCPC/DBS/RTW, but each is separate
   effort + maintenance) **vs.** buy a **licensed aggregator** (one integration,
   fast breadth, contract + sub-processor DPA cost). **Recommendation: hybrid** —
   own adapters where a free official API/facility exists (HCPC API, NMC/GMC/SWE
   facilities, gov RTW), aggregator/IDSP for the long tail (GPhC feed, DBS, IDVT,
   GDC/GOC). The adapter abstraction supports either with no schema change.
2. **Annual-cadence policy** — fixed 12-month rolling from last verify, vs. aligned
   to each regulator's renewal date, vs. risk-based (more frequent for higher-risk
   roles), plus the pre-expiry lead window. `recheck_months` is per-provider.
3. **Phase 2a scope** — confirm NMC/GMC/HCPC + DBS + RTW first; GPhC/GDC/GOC/SWE/
   Performers in 2b (they need new disciplines).
4. **Consent capture** for DBS + RTW (where/how/retention) — a data-policy call
   that blocks those two until decided.

## 5. Build order (once decisions signed off)
1. `37_verification_providers.sql` — providers + `provider_jobs` + consent;
   `regulator`/`provider_key`/`verification_method` on requirements + the
   `regulator_driven` expiry fix; seed 2a providers; RLS + indexes.
2. `38_verification_rpcs.sql` — enqueue / claim / apply / fail / enqueue_due_rechecks.
3. `39_verification_schedule.sql` — pg_cron drain + sweep; retention purge; a counts RPC.
4. `functions/verification/` — dispatcher + adapter interface + realtime/bulk/aggregator/manual adapters.
5. `compliance.html` — "Verify now" + verification pill + register-checks tile.
6. `DEPLOY.md` — new secrets, cron, region/DPA checklist.

**Fail-closed guarantee throughout:** the gate only ever credits a `verified`,
unexpired item; any provider error/ambiguity leaves the item non-verified →
red/not-placeable → human review. Every automated check appends one immutable
audit event; history is never mutated.
