# Candidate Pipeline — Architecture & Agent Design

> **Status:** Draft for review. Nothing here is applied to a live database yet.
> **Isolation:** This system lives in its own Postgres schema (`candidate`) and
> does **not** touch the existing client/employer outreach tables in `public`
> (contacts, email_sends, email_events, templates, …). Shared DB server + auth
> only.

## 1. What this is

The **candidate bench** — the front end of Day Webster's recruiter machine and
the **golden record** the compliance engine reconciles against. It is built to
become the eventual system of record, with an integration boundary to **sync
into Eclipse** later (see §6).

It is the missing top-of-funnel that neither the existing app nor the Compliance
Automation Feasibility Assessment covers. Together they form one machine:

```
  PROSPECT ──► ENGAGE ──► QUALIFY ──► [HUMAN GATE] ──► COMPLIANCE ──► READY ──► PLACED
  └──────── autonomous agent ────────┘              └─ existing assessment ─┘
                                                     (config-driven engine)
```

## 2. The autonomous agent — scope of autonomy

Per the assessment's gradient principle (automate the structured/low-stakes
~80%, flag-and-route the high-stakes ~20%), the agent is **autonomous up to a
line and human-gated past it**:

| Stage | Autonomy | What the agent does |
|---|---|---|
| **Search** | Autonomous | Find/receive candidates from the chosen source(s); create `candidates` rows at `status='sourced'`. |
| **Engage** | Autonomous | Open and hold a two-way conversation (email/SMS/WhatsApp/web), with consent captured first. Logs every turn to `messages`. |
| **Qualify** | Autonomous | Establish discipline, specialty, location, availability, right-to-work, registration number. Fills the light-qualification fields; moves to `qualified`. |
| **Begin compliance** | Autonomous *request*, human *decision* | Open `compliance_items` for the discipline's requirements and ask the candidate for them. **Verification/acceptance and registration are human-gated** — the agent never decides a reference is genuine or a candidate is work-ready. |

This is the Tier-B semi-auto model agreed earlier, applied end to end.

## 3. Components (all reuse one spine — "no new build primitive")

1. **Candidate store** — the schema in `sql/10_*` (this is built, in draft).
2. **Conversation/agent engine** — a Claude-powered edge function
   (`functions/candidate-agent/`, `claude-opus-4-8`, adaptive thinking, tool
   use) that drives the engage→qualify→compliance-request conversation and
   writes structured results back to the DB. *Built (draft, not deployed).*
3. **Inbound-email pipeline** — classify inbound email → locate artefact (body
   vs attachment, through Fwd chains) → ingest → check sender domain. This is
   the exact spine the assessment's references (§8f) and bookings half need;
   building it here de-risks both. *Built (draft, not deployed):
   `functions/inbound-email/` + `sql/15`; files to the `candidate-docs` bucket;
   lands documents as `received` for human acceptance.*
4. **Classify-and-judge + validation layer** — CV/document parsing, field
   extraction with format validation (PIN/NI/DBS/dates), low-confidence routing
   to the review queue. Shared with the compliance engine. *Not yet built.*
5. **Compliance config** — `compliance_requirements` rows. *First per-discipline
   set seeded (`sql/13`) from the assessment; the agent reads it to request the
   right documents. Refine against the live compliance project.*
6. **Human review surface** — the `review_queue` view + a Candidates tab in the
   app. *App work not yet built.*

## 4. Data model map (what's in the draft schema)

- `disciplines` / `specialties` — multi-discipline taxonomy, seeded day-one.
- `candidates` — golden record incl. registration number (stored, never
  AI-verified), name variants + employment timeline for reconciliation.
- `employment` — timeline enabling the ≥3-year reference-coverage gap analysis.
- `messages` — unified cross-channel engagement log (agent memory).
- `consent` — UK GDPR / PECR record (individuals need consent — unlike the B2B
  outreach side).
- `compliance_requirements` (config table) + `compliance_items` (per-candidate
  instances with channel + source-confidence + expiry + human-review flag).
- `review_queue` — live human-in-loop surface.

## 5. Compliance project — the pluggable slot

`compliance_requirements` mirrors the assessment's model (tier A–H, deterministic
`expiry_rule`, `coverage_rule`, `needs_human`). The plan is to **import** the
requirement set from the compliance project per discipline (nursing → NMC +
revalidation + references-3yr + DBS …; doctors → GMC …; children's → Ofsted/DBS
…; insurance → its own set). No schema change needed to load them — they are
rows.

## 6. Eclipse integration boundary (future)

`candidates.external_ids` + `sync_status` reserve the seam for a later one- or
two-way sync to Eclipse via its API. The bench stays the system of record;
Eclipse is a downstream consumer until/unless that changes. **Eclipse API
details required before this is scoped.**

## 7. Data protection (assessment §11 — gating, not a footnote)

- Individuals need a **lawful basis / consent** for engagement — captured from
  the first contact (`consent` table, per-source default basis).
- **Data minimisation**: store only what each stage needs; redact-on-ingest for
  documents that carry far more PII than required.
- **LLM sub-processor retention** is a hard gate on using an LLM for screening
  or document understanding. Anthropic's API terms (training/retention, DPA,
  zero-data-retention options) must be confirmed and recorded before the agent
  processes real candidate data. *To confirm and document.*

## 7a. Outbound + monitoring (built)

- **Sending** — `functions/_shared/email.ts` (Brevo, candidate-side sender,
  tokenised Reply-To). The agent now *sends* its replies (draft fallback).
- **Reference requests + confirmation handshake** — `reference-request` issues a
  token and emails the referee; `inbound-email` ingests the reference, then
  emails the referee to confirm authorship, and a "yes" reply marks it
  confirmed. Acceptance of the reference itself remains human.
- **Early Warnings** — `early-warnings` (scheduled): auto-chases candidates
  before documents lapse and flags expired items for a human (assessment §6).

## 8. Open decisions (block specific legs, not the foundation)

1. **Sourcing channels** — what the agent is allowed to *search*. This is the
   one decision blocking the "search" leg and has legal/ToS weight (job-board
   ToS, LinkedIn, paid CV-DB APIs vs clean inbound). The schema is
   channel-agnostic and ready for any choice.
2. **Engagement channels** for go-live (email first; SMS/WhatsApp later).
3. **Compliance requirement import** from the compliance project.
4. **Eclipse API** specifics.
