# compliance-chat (edge function)

The **Role-Scoped Compliance AI Chat (v1)**: a staff-facing natural-language Q&A
over the **live** compliance data, scoped to the caller's role. Built on
`claude-opus-4-8` with tool use; a manual agentic loop calls a fixed set of
read-only, **scope-safe** DB tools and summarises the results. No write tools.

> **Draft — not deployed.** Committed for review only.

## The security model (why this function is unusual)

- **Rule A — runs as the CALLER, never as service role.** The data client uses
  the **anon key + the caller's forwarded JWT**, so every `*_in_scope` RPC runs
  under the real `auth.uid()` and Postgres RLS + `chat_scope()` decide who sees
  what. A bug here cannot leak cross-officer data.
- **Rule B — scope is SQL, not a tool argument.** The model may set only
  non-scope params (`p_limit`, `p_days`, `p_query`, `p_division`). The officer-id
  set is injected by each RPC from `chat_scope()`; nothing the model emits can
  widen it.
- Three DB gating layers: `is_authorized_user()` (domain) →
  `is_compliance_officer()` (capability) → `chat_scope()` (row scope).

## Scope tiers (sql/45)

| Role | Sees |
|---|---|
| Compliance Officer (`is_compliance`) | their OWN candidates only |
| Compliance Manager (`is_manager`) | ALL compliance data + `chat_officer_breakdown` |
| Admin (`is_admin`) | everything (a manager too) |

Unassigned candidates are visible only to manager/admin (all_access).

## Request shape

`POST` with JSON: `{ "question": "what needs urgent attention?" }`
with header `Authorization: Bearer <user session access_token>`
→ returns `{ "answer": "...", "role": "officer|manager", "pii_mode": "aggregate|identifying" }`.
Every turn is audited to `candidate.compliance_chat_log` (tool names + inputs +
row-counts only — never candidate rows).

## PII mode (§7 / DPA gate)

`CHAT_PII_MODE` (default **`aggregate`**): in aggregate mode candidate
names/emails are stripped from tool results before they reach Anthropic — counts
and coded reasons only. Switch to `identifying` **only** once the Anthropic
DPA / zero-retention terms are recorded. The mode is stamped into each log row.

## Deploy prerequisites

1. Apply migrations through `candidate-pipeline/sql/46` (45 = `is_manager`;
   46 = `chat_scope` + `*_in_scope` RPCs + `compliance_chat_log`).
2. Secrets: `ANTHROPIC_API_KEY`, `CHAT_PII_MODE` (set `aggregate` until the DPA).
   The function also uses project-injected `SUPABASE_URL` + `SUPABASE_ANON_KEY`.
3. Deploy as `compliance-chat` with **`verify_jwt = true`**.

## Tuning notes

- `max_tokens = 1500`, `effort = low` (retrieve-and-summarise); single response,
  not streamed. The tool loop is capped at 6 rounds.
- `chat_officer_breakdown_in_scope` is offered to the model only for
  manager/admin callers, and the DB raises for anyone else regardless.
