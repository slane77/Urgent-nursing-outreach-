# Candidate Pipeline

The recruiter-side system: an autonomous agent that **prospects, engages and
qualifies candidates**, then begins compliance intake — building Day Webster's
candidate bench across multiple business areas (Nursing, Doctors, Complex Care,
AHP, Insurance / John Williams, Children's Services, Care Homes).

> **Separate from the outreach app.** This system has its own Postgres schema
> (`candidate`) and never touches the existing client/employer outreach tables
> (`contacts`, `email_sends`, etc.) in `public`. See `ARCHITECTURE.md`.

## Status

Foundation drafted, **not yet applied to any database**:

- `sql/10_candidate_schema.sql` — tables (golden record, employment timeline,
  messages, consent, compliance config + items, review queue).
- `sql/11_candidate_policies.sql` — RLS (authorised-domain access).
- `sql/12_candidate_seed.sql` — day-one disciplines & specialties.

Read `ARCHITECTURE.md` for the agent design and what's built vs pending.

## Next steps

1. Review the schema, then apply 10 → 11 → 12 (ideally on a Supabase **dev
   branch** first).
2. Decide **sourcing channels** (the one decision blocking the agent's "search"
   leg).
3. Build the Claude-powered conversation agent + inbound-email pipeline.
4. Import the compliance requirement set from the compliance project.
