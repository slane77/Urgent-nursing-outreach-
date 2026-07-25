# Candidate Compliance Experience — design & recommendation
### The portal + chase/collect/communicate engine ("the easiest system in the world" for candidates)

Scoping deliverable (research + architecture). No code yet. Answers: how candidates
are chased for updates, how documents are received/verified/uploaded/stored, and how
we communicate through the whole compliance journey — optimised for candidate ease
and completion. Builds on what already exists (AI document triage, the work-ready
gate, evidence storage, the AI candidate-agent, the auto-chase loop).

## 0. The evidence — why this design (best-in-class benchmarks)
- **Passwordless magic-link access = the single biggest lever: +40–60% completion**
  (one case 41%→67% in two weeks just by removing the password). Each extra form
  field costs 7–10% completion.
- **A live progress checklist ("compliance passport")** is what Credentially (100+ UK
  healthcare orgs) credits for cutting candidate **drop-off ~70–80%** and onboarding
  from **~60 days to ~5** — *visibility* of exactly what's outstanding drives it.
- **~25% of people drop out at document upload** — so capture must be effortless and
  we must **never re-ask for what we already hold**.
- **WhatsApp ~98% open** (78% within 5 min) vs SMS ~70–80% vs email ~9–20%.
- **Compliance chasers are transactional (service) messages under PECR**, not
  marketing — so they don't need marketing consent (keep shift/referral marketing on
  a separate consented stream). Messaging cost across the 10–15k cohort is only a few
  £k; the spend is the platform/IDVT/capture, not the messages.

## 1. The candidate experience (ranked by impact)
1. **Passwordless, no app.** Every chase message *is* a one-tap login link (magic
   link) that drops the candidate straight onto the exact item; 6-digit OTP fallback
   for SMS/WhatsApp. No password, no account creation, no download.
2. **A "compliance passport"** — progress bar + only the **outstanding** items (driven
   by the work-ready gate), each with plain-language "what this is / why we need it".
3. **Ask only for what's missing** — pre-fill everything we hold; auto-verify register
   PINs/DBS/RTW (Phase 2) so we never re-ask.
4. **Mobile-first, one-thing-per-screen** (the GOV.UK Design System pattern) with
   **save-and-resume** (candidates gather documents over days).
5. **Effortless capture** — phone-camera → **our existing AI triage** auto-detects the
   document type + expiry + photo quality, confirms in ~5 seconds ("Got your DBS,
   valid to 2027 ✓" / "too blurry, retake"), and files it against the right
   requirement. Never a 3-day admin-rejection latency (where candidates ghost).
6. **Two-way help** — the candidate can ask a question or reply and get an answer from
   our AI candidate-agent (guard-railed, with human handoff).
7. **Accessible & inclusive** — WCAG 2.2, plain language, big targets, multilingual,
   an assisted mode (recruiter can co-fill), and an easy "talk to a person" escape.

## 2. Channel strategy
**WhatsApp-first, SMS fallback, email for records — not push.**
- WhatsApp: nudges, deep-links, magic-link/OTP, two-way support (highest reach).
- SMS: guaranteed-delivery fallback for links/OTP.
- Email: formal confirmations + document copies + audit.
- **Provider:** Twilio (SMS + WhatsApp Business + Verify in one vendor, GBP/UK routes),
  Brevo retained for email. WhatsApp Business needs Meta verification + approved
  templates (procurement lead time) → **email + SMS first, WhatsApp shortly after**.
- PECR: capture per-channel consent at intake; honour STOP/START; keep compliance and
  marketing streams separate.

## 3. Architecture (on the existing Supabase/edge/vanilla-HTML stack)

### Reuse (don't reinvent)
- **AI triage** (`inbound-email`'s `classify()`) → refactor to `_shared/triage.ts`,
  shared by inbound-email and the portal (add a photo-quality field).
- **Work-ready gate** (`sql/23/25`) → drives the progress bar + "outstanding" list.
- **Evidence store** (`candidate_evidence` + private `candidate-docs`) → portal uploads.
- **Human acceptance** (`decide_item`) unchanged — a candidate upload lands `received`
  + `needs_human`, **never `verified`** (core safety invariant preserved).
- **candidate-agent** → the portal's "ask a question" (guard-railed + human handoff).
- **Verification provider/adapter pattern** (`sql/37-39`) → the comms engine mirrors it
  exactly; **`early-warnings`** generalises into the chase scheduler.
- **Message log** (`candidate.messages`, already has email/sms/whatsapp channels) →
  the auditable comms log.

### Passwordless auth — function-as-trust-boundary (recommended)
The candidate never gets a DB token; they hold only an opaque session token and talk
only to the `candidate-portal` edge function, which uses the service role and appends
`.eq('candidate_id', session.candidate_id)` to **every** query. Tables stay
**default-deny** to non-staff (no anon/candidate RLS policy at all) — same trust model
as `inbound-email`/`verification`, minimal blast radius. Magic-link + session tokens are
single-use / short-TTL / **hashed at rest**, rate-limited. (A DB-enforced candidate-JWT
RLS variant is documented as later hardening.)

### New objects (migrations 40–42, all additive/idempotent)
- `portal_magic_links` + `portal_sessions` (hashed, expiring; no client policy) +
  `consume_magic_link()`.
- `comms_preferences` (preferred channel, per-channel PECR consent, quiet hours,
  pause), `comms_providers` (mirror verification_providers; secret_ref only),
  `scheduled_nudges` (the escalating chase queue + partial-unique so no dupes).
- **Auto-stop trigger**: when an item becomes received/verifying/verified/waived, cancel
  its scheduled nudges (per-item, so "I already sent that!" never happens).
- `compliance_requirements.candidate_label`/`candidate_help` (plain-language copy),
  `declarations` (e-sign audit: name/timestamp/IP/hash), extra `messages` columns.

### New functions
- **`candidate-portal`** (replaces the dead stub): `issue_link` / `verify` / `get`
  (progress + outstanding only) / `upload` (→ triage → confirm → `received`) /
  `add_referee` / `consent` / `sign` / `set_prefs` / `ask`. Service-role, session-scoped,
  returns whitelisted columns only.
- **`comms-send`** (mirrors `verification`): `mode=schedule` (daily — the generalised
  `early-warnings`: upsert nudges for outstanding/expiring items) + `mode=drain`
  (~15 min — send due nudges, resolving channel + PECR consent + quiet hours + caps,
  minting a fresh deep-link magic token, logging to `messages`). Channel adapters
  (email/sms/whatsapp/sim), credential-gated.
- **`comms-inbound`** (Twilio SMS/WhatsApp webhook): match by phone → agent → reply;
  STOP/START toggles consent.

## 4. Candidate journey (end to end)
1. **Registered** → consent + comms preferences created; first magic link sent → lands
   authenticated on the portal.
2. **Home** → greeting + progress bar + only the outstanding items with plain "what/why".
3. **Collect each item** → phone-camera → triage confirms → lands `received` → that
   item's chase **auto-stops**. Referees requested; RTW/DBS consent captured (→ optional
   Phase-2 auto-verify); declarations e-signed.
4. **Between visits** → `comms-send` escalates on the preferred channel (email→+SMS→
   +WhatsApp), quiet-hours + PECR + frequency-capped, each nudge deep-linking to the
   exact item; questions answered by the agent with human handoff.
5. **Work-ready** → last blocking item human/provider-verified → gate flips → "You're
   ready for work 🎉".
6. **Ongoing renewals** → the verification sweep + scheduler re-open expiring items ahead
   of time and chase renewal through the same loop — annually, hands-off.

## 5. Decisions (recommendations in **bold**)
1. **Magic-link per nudge + OTP fallback** (lowest friction).
2. **Function-as-trust-boundary** auth (default-deny RLS); DB-scoped JWT later.
3. **Twilio** for SMS + WhatsApp; Brevo for email. **POC = email + SMS; WhatsApp once
   Meta verification/templates land.**
4. **Self-upload → `received` + human-verify** (never auto-verified); auto-verify only
   register/DBS/RTW via the Phase-2 provider path.
5. **Per-candidate channel + escalation cadence** (e.g. day 0/3/7/14), quiet hours
   21:00–08:00, ≤1 msg/candidate/day then human.
6. **Capture per-channel consent at intake** (safe PECR posture).

## 6. Phased build plan
- **POC (fast, high-impact):** `40_portal_auth.sql`; refactor `_shared/triage.ts`;
  `candidate-portal` (issue_link/verify/get/upload) + wire the real `portal.html`
  (passwordless login → progress → camera upload → triage confirm). This alone proves
  the "easiest experience" end-to-end.
- **Then:** `42` candidate copy + consent/sign/add_referee/set_prefs/ask;
  `41_comms_engine` + `comms-send` (email+SMS+sim) + generalise `early-warnings` +
  auto-stop; `comms-inbound` for two-way.
- **Then:** WhatsApp adapter + templates (post Meta verification); declaration PDFs;
  DB-scoped candidate RLS hardening.

## 7. Data protection
Function-mediated access (default-deny); hashed magic-link/session tokens; SMS/WhatsApp
bodies carry minimal PII (first name + link); STOP/START honoured; Twilio + Anthropic
under DPAs before real PII; declarations capture IP/UA/timestamp; confirm UK/EU Supabase
region. Compliance chasers are transactional under PECR; marketing stays on a separate
consented stream.
