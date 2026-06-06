# candidate-agent (edge function)

The autonomous-to-a-line recruiter agent: **engage → qualify → request compliance**,
writing structured results into the isolated `candidate` schema. Built on
`claude-opus-4-8` (adaptive thinking) with tool use; runs a manual agentic loop
so the human-gate and DB side-effects stay under our control.

> **Draft — not deployed.** It is committed for review only.

## What it will and won't do

- **Autonomous:** consent capture, qualification (discipline/specialty/RTW/
  availability/registration number — *stored, never validated*), employment
  history, pipeline status up to `compliance`, and *requesting* compliance docs.
- **Human-gated (never autonomous):** deciding a document/reference is genuine
  or acceptable, asserting a registration is valid, or marking work-ready.
  Ambiguity and adverse safeguarding answers are routed to the review queue.

## Request shape

`POST` with JSON: `{ "candidate_id": "<uuid>", "inbound_message": "...", "channel": "web|email|sms|whatsapp" }`
→ returns `{ "reply": "<drafted message to the candidate>" }` and logs it to
`candidate.messages` as `status='draft'`.

## Deploy prerequisites (when you're ready)

1. Apply the schema: `candidate-pipeline/sql/10 → 11 → 12` (ideally on a Supabase **dev branch** first).
2. Set the secret: `ANTHROPIC_API_KEY` (the function also uses the
   project-injected `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY`).
3. **§11 data-protection gate:** confirm and record Anthropic's data-handling
   terms (no training on API data by default; DPA / zero-data-retention
   available) before processing real candidate PII. Until then, test on
   synthetic candidates only.
4. Deploy as a Supabase edge function named `candidate-agent`.

## Tuning notes

- `output_config.effort` is set to `medium` for conversational latency; raise to
  `high` for harder qualification judgement.
- The loop is capped at 6 tool rounds per turn.
- Actual outbound **send** (e.g. via Brevo) is intentionally not wired yet —
  replies are logged as drafts so a human can review during early rollout.
