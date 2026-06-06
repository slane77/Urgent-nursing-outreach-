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
- `functions/candidate-agent/` — the Claude-powered recruiter agent
  (engage → qualify → request compliance; human-gated past that line).

Read `ARCHITECTURE.md` for the agent design and what's built vs pending.

## Next steps

1. Review the schema + agent, then apply `sql/10 → 11 → 12` and deploy
   `candidate-agent` (ideally on a Supabase **dev branch** first).
2. Set `ANTHROPIC_API_KEY` and confirm the §11 data-protection terms before
   running on real candidate data.
3. Build the **inbound-email pipeline** + the search connectors for the chosen
   sourcing channels (inbound web/apply, referrals, paid CV-DB APIs; social
   via compliant/official routes only).
4. Build the **Candidates tab** (review queue UI) in the app.
5. Import the compliance requirement set from the compliance project.
