# Candidate Pipeline

The recruiter-side system: an autonomous agent that **prospects, engages and
qualifies candidates**, then begins compliance intake — building Day Webster's
candidate bench across multiple business areas (Nursing, Doctors, Complex Care,
AHP, Insurance / John Williams, Children's Services, Care Homes).

> **Separate from the outreach app.** This system has its own Postgres schema
> (`candidate`) and never touches the existing client/employer outreach tables
> (`contacts`, `email_sends`, etc.) in `public`. See `ARCHITECTURE.md`.

## Status

Foundation + agent drafted, **not yet applied/deployed**:

- `sql/10_candidate_schema.sql` — tables (golden record, employment timeline,
  messages, consent, compliance config + items, review queue).
- `sql/11_candidate_policies.sql` — RLS (authorised-domain access).
- `sql/12_candidate_seed.sql` — day-one disciplines & specialties.
- `sql/13_compliance_requirements.sql` — per-discipline compliance requirement
  set (tiers/expiry/coverage/human-gate) derived from the compliance
  assessment; the agent reads these to request the right documents.
- `functions/candidate-agent/` — the Claude-powered recruiter agent
  (engage → qualify → request compliance; human-gated past that line).
- `functions/candidate-intake/` + `/intake.html` — public self-registration
  form → creates a `sourced` candidate with consent.
- `functions/csv-import/` + `/candidate-import.html` — smart bulk importer for
  old spreadsheets: Claude maps each file's columns once, applied
  deterministically to every row; dedupes on email; lands rows as `sourced`.
- `/candidates.html` — the staff **review cockpit**: pipeline funnel by status,
  candidate detail (profile/transcript/employment/consent/compliance), edit +
  status control (incl. the human-gated `ready`/`placed`), one-click "run
  agent", and the human review queue. Reads/writes the `candidate` schema
  directly under RLS — never touches the outreach app.

(`intake.html`, `candidate-import.html` and `candidates.html` live at the repo
root so GitHub Pages serves them alongside the existing app.)

Read `ARCHITECTURE.md` for the agent design and what's built vs pending.

## Next steps

1. Review the schema + functions, then apply `sql/10 → 16` and deploy the edge
   functions (ideally on a Supabase **dev branch** first):
   - `candidate-agent`, `csv-import`, `reference-request`, `job-advert`,
     `outreach-campaign` — verify_jwt (staff)
   - `candidate-intake`, `inbound-email`, `early-warnings`, `jobs` — verify_jwt
     false (public/provider/cron; `inbound-email` + `early-warnings` guard with
     a `?secret=`). Create a private Storage bucket `candidate-docs`.
   - Schedule `early-warnings` daily (Supabase Cron).
2. Set secrets: `ANTHROPIC_API_KEY`, `BREVO_API_KEY`, `CANDIDATE_SENDER_EMAIL` /
   `CANDIDATE_SENDER_NAME`, `REPLY_DOMAIN` / `REPLY_LOCAL`, `INBOUND_SECRET`,
   `CRON_SECRET`, `PUBLIC_SITE_URL` (where intake.html is hosted), `ORG_NAME` /
   `ORG_URL`. Confirm the §11 data-protection terms before real PII.
3. Expose the `candidate` schema to the API (Supabase → Settings → API →
   Exposed schemas) so `candidates.html` can read/write it under RLS.
4. Use `candidate-import.html` to load the old spreadsheets; share
   `intake.html` for inbound registration; work candidates in `candidates.html`.
5. Build the **inbound-email pipeline** + search connectors for the chosen
   sourcing channels (referrals, paid CV-DB APIs; social via official routes).
6. Import the compliance requirement set from the compliance project.
