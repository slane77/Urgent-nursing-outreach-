# Acquisition engine — Phase 2 plan

How the autonomous recruiter *reaches* candidates and builds the pipeline.
Decisions taken: **paid sourcing approved**, accounts held = **Indeed / Reed /
CV-Library-Totaljobs**, **UK-only** for now (international = later track).

## The model (built — `sql/16`)

```
vacancy ──< advert (per channel: indeed/reed/cvlibrary/google_jobs/…)
   │                       │ external_ref + cost
   │                       ▼
   └──────────────► applicants ──► candidates (vacancy_id, campaign_id, source_id)
sourcing_campaign (budget/spend) ──┘        └─► cost-per-candidate by channel & discipline
```

- **vacancies** also double as the source for **Google for Jobs** (each carries a
  `slug` + we store `JobPosting` JSON-LD on its advert).
- **candidates.vacancy_id / campaign_id** give the control tower attribution:
  the `intake_by_channel` view already reports candidates / qualified /
  ready-or-placed by channel × discipline.
- Applying to a vacancy (`intake.html?vacancy=<slug>`) pre-tags the candidate's
  discipline — fewer mis-classifications for oversight to catch.

## Channels & how each gets wired

| Channel | Build | Needs from you |
|---|---|---|
| **Google for Jobs** | A public `jobs` function serving an index + per-vacancy pages with `JobPosting` structured data → Google indexes them free. No external account. | A subdomain to host (e.g. `jobs.daywebster…`) |
| **Careers-site / landing** | Discipline landing pages → `intake.html`. | — |
| **Referral engine** | Function that runs refer-a-friend (bounty) to the existing bench via the send helper. | A bounty policy |
| **Re-engagement** | Function that works dormant/lapsed candidates (consent-checked) via the agent. | — |
| **Indeed** | Connector behind a common interface (post advert / receive applies / CV search). | **Indeed API credentials** + partner access (Indeed Apply / Sponsored / Resume) |
| **Reed** | Connector (job posting + CV search). | **Reed recruiter API key** |
| **CV-Library / Totaljobs** | Connector (posting + CV-database search). | **CV-Library/Totaljobs recruiter API credentials** |
| **Paid social (Meta/TikTok/Google Ads)** | Later — campaign + creative generation to landing pages. | Ad-account access + budget |

### Connector interface (so boards slot in cleanly)
Each board connector implements two verbs, behind one shape:
- `postAdvert(vacancy, channel) -> { external_ref, cost }` — writes back to `adverts`.
- `searchCVs(query) -> [candidate-ish rows]` — lands matches as `sourced`
  candidates (source `cv_search`), deduped, for the agent to engage.
Adverts and applicants are all attributed, so cost-per-candidate is automatic.

## Hard dependencies before scaling outreach

1. **Deliverability** — sending to individuals at volume needs a warmed sending
   domain with SPF/DKIM/DMARC, and **consent (PECR)**. The candidate-side Brevo
   sender is the start; this must be set up properly before mass outreach.
2. **Spend governance** — every paid channel has a cost; the control tower must
   surface cost-per-candidate by channel/discipline and gate budgets. The
   `sourcing_campaigns.budget/spend` + `intake_by_channel` view start this.

## Build order (Phase 2)

1. ✅ Sourcing/attribution model + intake attribution (`sql/16`).
2. ✅ **Vacancies UI + advert generator** — `vacancies.html` + `job-advert`
   (Claude writes the copy + channel variants; JSON-LD built in code).
3. ✅ **Google-for-Jobs `jobs` function** — public, structured-data job pages.
4. ✅ **Referral + re-engagement** — `outreach-campaign` (credential-free).
5. **Board connectors** — Indeed / Reed / CV-Library, once credentials arrive
   (implement `postAdvert` / `searchCVs` against the interface above).
6. **Control tower (Phase 3)** — dashboard over `intake_by_channel`,
   cost-per-candidate, discipline-integrity review, agent action log.

## What unblocks the paid connectors

To wire Indeed / Reed / CV-Library I need, per board, from your recruiter
accounts: **API key/secret**, the **account/partner identifiers**, and which
**products** you have (job posting vs CV search vs Apply). These go in Supabase
secrets — never in the repo.
