# inbound-email (edge function)

The inbound-email spine: documents and references arrive by email, get
classified, located, ingested, and landed on a compliance item for a human to
accept. Built once here, it's the same machinery the bookings half will reuse.

> **Draft — not deployed.**

## Flow
1. **Identify candidate** — correlation token in the reply-to/plus-address
   (`local+TOKEN@…`) or subject (`[#TOKEN]`), else match the sender's email.
   Tokens are issued (in `candidate.email_tokens`) when we request a reference
   from a referee, who isn't the candidate.
2. **Classify (Claude)** — reference / compliance document / candidate reply /
   noise; map to a requirement code; locate the artefact (body vs which
   attachment); pull a few fields. Handles forwarded chains.
3. **Ingest** — attachments → private `candidate-docs` Storage bucket; message
   logged; a `compliance_item` set to **`received`** (never auto-verified).
4. **Anti-fraud signal** — institutional vs free-webmail sender domain. Free
   webmail, references, low confidence, or judgement items → `needs_human`,
   surfaced in the cockpit review queue. Acceptance is always human (§7).

## Request shape (provider-agnostic)
`POST ?secret=<INBOUND_SECRET>` with JSON:
```
{ "from": "...", "to": "...", "subject": "...", "text": "...", "html": "...",
  "attachments": [ { "filename": "...", "contentType": "...", "contentBase64": "..." } ] }
```
Map your provider's inbound-parse payload to this (Brevo Inbound / SendGrid
Inbound Parse / Mailgun Routes), or add a thin adapter at the top of `Deno.serve`.

## Deploy prerequisites
1. Apply `sql/10 → 15`.
2. Create a **private** Storage bucket named `candidate-docs`.
3. Secrets: `ANTHROPIC_API_KEY`, `INBOUND_SECRET` (any random string; put it in
   the webhook URL). Function `verify_jwt=false` (the provider calls it).
4. Point your email provider's inbound webhook at
   `…/functions/v1/inbound-email?secret=<INBOUND_SECRET>`.
5. Confirm the §11 data-protection terms before real PII flows through the LLM.
