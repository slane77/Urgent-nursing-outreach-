# Day Webster AI OS — Blueprint

> **Status:** Thinking document. Nothing here is built or applied. It maps the
> five-layer "AI OS" pattern onto what this repo *already* contains, names the
> one architectural decision that determines everything else, and lists what is
> genuinely missing.
>
> Author: Scott Lane, August 2026.

---

## 0. The headline

You already own four of the five layers. They are in this repository.

| The five-layer pattern | What exists here today | Gap |
|---|---|---|
| 1. AI OS Dashboard | `dashboard.html` — control tower: KPIs, pipeline funnel, intake by channel × discipline, campaign cost-per-candidate, agent activity feed | No agent *control*. It reports; it doesn't command. |
| 2. AI Second Brain | The `candidate` Postgres schema — candidates, messages, employment, consent, compliance items, desks. A genuinely good **structured** brain. | No **unstructured** brain. The SOPs, the ruleset, "how we price a theatre locum", the past decisions — those live in people's heads and in Outlook. |
| 3. Executive Assistant Agent | Nothing. | This is the only layer that is genuinely a new build. |
| 4. Marketing Agent | `outreach-campaign` (referral + re-engagement), `job-advert` (Claude writes advert copy + deterministic JSON-LD), Brevo sender, `promo.html`, Canva connector | No content calendar, no attribution loop closing back to spend, single channel (email). |
| 5. Team of AI Agents | Seven edge functions: `candidate-agent`, `inbound-email`, `early-warnings`, `outreach-campaign`, `job-advert`, `csv-import`, `candidate-intake` | No roster, no scheduler, no shared run log, no cost cap, no escalation path. They are seven strangers, not a team. |

So this is not a build-from-zero project. It is a **shell, a memory, a scheduler
and a phone** away from being real.

The uncomfortable part: none of the seven functions is deployed. Every file
says `STATUS: DRAFT — NOT YET DEPLOYED`. The AI OS conversation is downstream of
a much more boring one — *deploy the agents you already wrote*.

---

## 1. The decision that determines everything: where does the OS live?

The brief says "use all of my connectors." That single sentence forces a choice
most people building these dashboards don't notice until they're three weeks in.

**Connectors (Gmail, Google Calendar, Drive, M365, Canva, Lusha, Supabase, Wix)
are Claude-side MCP integrations. They authenticate to your Claude account, not
to your app.** A dashboard you build and host at `daywebster.com` does not get
them. If you want your own web app to read Outlook, you implement Microsoft
OAuth yourself, store the tokens, handle refresh, and pass Microsoft's security
review. Times eight.

That gives three shapes:

### Option A — Claude is the OS
Claude Code (desktop) + Remote Control (phone) is the shell. Every connector
works natively, day one, zero build. Your dashboard becomes a read-only pane of
glass the agents write into.

- **Cost:** ~£0 of new build. Subscription only.
- **Cost of a different kind:** the "operating system" is a chat window and a
  terminal. It is not the Iron Man interface in the video.
- **Ceiling:** anything a colleague needs to touch has to be rebuilt as a proper
  UI anyway, because you cannot hand a recruiter your terminal.

### Option B — Your app is the OS
Build the dashboard as the real product; re-implement every integration.

- **Cost:** months. Eight OAuth flows, token vaults, Microsoft app registration,
  and you now own the security surface of a mail client.
- **Benefit:** it's yours, it's brandable, staff can use it, it survives you.

### Option C — Two front doors, one brain *(recommended)*
The database is the operating system. Everything else is a client of it.

```
                  ┌──────────────────────────────────┐
                  │   Supabase  ·  the actual OS     │
                  │   schema + RLS + storage + cron  │
                  │   agent_runs · memory · costs    │
                  └───────┬──────────────────┬───────┘
                          │                  │
       ┌──────────────────┴────┐    ┌────────┴──────────────────┐
       │  YOUR DOOR            │    │  MY DOOR                  │
       │  dashboard.html       │    │  Claude Code + Remote     │
       │  candidates.html      │    │  Control (desktop+phone)  │
       │  staff, branded,      │    │  you only, all connectors │
       │  RLS-scoped per desk  │    │  ad-hoc, powerful, unsafe │
       └───────────────────────┘    └───────────────────────────┘
                          │                  │
                  ┌───────┴──────────────────┴───────┐
                  │  Edge functions = the agent team  │
                  │  candidate · inbound · warnings   │
                  │  outreach · advert · import       │
                  └───────────────────────────────────┘
```

Staff get a real product. You get a superuser console with every connector
attached. Neither one is the system of record — the database is. That is what
keeps the thing from becoming a toy that only works when you're at your desk.

**This is the recommendation.** The rest of this document assumes Option C.

---

## 2. Layer by layer — what's real, what's missing

### Layer 1 · The dashboard

What's in the video is a visual language, not an architecture. Arc reactor,
scanlines, agent roster down the left, schedule down the right. It looks like
command. Underneath it is a database query and a chat box.

Do not spend three weeks on the glow. Spend it on the three things
`dashboard.html` cannot currently do:

1. **Show what the agents did.** There is a "Recent agent & system activity"
   feed, but nothing writes to it on a schedule and nothing shows a *run*:
   started, tools used, tokens, cost, outcome, whether a human was needed.
2. **Let you intervene.** Approve, reject, pause an agent, re-run a job, kill a
   campaign — from the same screen, on a phone, in a queue at Tesco.
3. **One command bar.** "What needs me today?" typed into the dashboard,
   answered from the database. This is the single feature that makes it feel
   like an OS instead of a report.

**New tables required:** `agent_runs`, `agent_costs`, `approvals`.
Everything else is presentation.

### Layer 2 · The second brain

The structured half is done and it's the harder half. The `candidate` schema is
a real golden record with provenance, consent, and reconciliation fields.

The missing half is the unstructured one — and it is the layer that actually
makes the agents good rather than generic:

- **The ruleset.** `rules.html` and `guide.html` are the beginning of this.
  Compliance thresholds, which desk takes what, escalation rules, tone of voice,
  what we never say to a client. Today an agent has to be *told* these each time.
- **The history.** Every decision, every "we tried that in March and it failed",
  every client quirk. This is what a five-year employee has and a new agent
  doesn't.
- **The documents.** Contracts, framework agreements, rate cards, the
  compliance assessment, the Eclipse notes.

The pattern that works: a plain-text vault (Markdown, in git or Drive), indexed,
plus session logs written at the end of every working session and read at the
start of the next. Boring, versioned, greppable, portable, and it survives the
vendor going out of business. The pretty graph view in the video is Obsidian
rendering exactly that — a folder of Markdown files.

**Practical shape:** `ai-os/brain/` in this repo for anything non-personal and
non-PII; Drive/SharePoint for documents; a `memory` table in Supabase for facts
the agents write back themselves.

**Hard constraint:** candidate PII does not go in the vault. It stays in Postgres
behind RLS. The brain holds *how we work*, not *who we have*.

### Layer 3 · The executive assistant

The video's assistant is Hermes — an open-source agent framework from Nous
Research. Worth being precise about what it is, because the name gets used as if
it were a model: **Hermes has no intelligence of its own.** It wraps a model
(Claude, GPT, whatever) and adds the four things a chat window lacks: persistent
memory across sessions, a self-improving skills system, messaging gateways
(Telegram, WhatsApp, Slack, Discord), and cron. It runs on a ~£5/month VPS.

You have two credible routes:

| | Claude Code + Remote Control | Self-hosted Hermes |
|---|---|---|
| Mobile | Official Claude iOS/Android app, since Feb 2026 | Telegram/WhatsApp |
| Connectors | All of yours, natively | You wire each one |
| Always-on | No — it mirrors a session you started | Yes, genuinely autonomous |
| Memory | CLAUDE.md + session logs | Built in |
| Setup | Minutes | A weekend, plus ongoing ops |
| Ops burden | None | You now run a server |

**Recommendation: start with Remote Control.** It gives you the phone control
you asked for, immediately, with every connector working. Move to a self-hosted
agent only when you hit the specific wall it solves — genuinely autonomous
overnight work that no one triggered.

**What the assistant should actually do,** given this business:
- Morning brief: what came in overnight (inbound-email), who's blocked
  (`review_queue`), what expires this week (`early-warnings`), what needs
  approving.
- Inbox triage across Outlook — but see the governance section; this is the
  highest-risk single feature in the whole plan.
- Calendar defence and meeting prep from the candidate/client record.
- "Chase Ewan about the theatre rates" → it remembers, and chases.

### Layer 4 · The marketing agent

Closest to done. `job-advert` already has Claude writing channel-tailored copy
with the JSON-LD built deterministically in code — which is exactly right, and a
mistake most people make the other way round.

What turns it from a copy generator into a marketing *agent* is the loop:

```
   plan  →  produce  →  publish  →  measure  →  learn
    │         │           │           │           │
  calendar  Claude     Brevo/Wix/  campaign_   writes back
   table    +Canva      Indeed    performance   to brain
```

`campaign_performance` and `channel_spend` (sql/17) already close the measure
leg — cost per candidate, per campaign, per channel. That is more than most
agencies have. The gaps are **plan** (no calendar) and **learn** (nothing feeds
results back into the next brief).

Connectors that matter here: **Canva** (connected — assets and brand templates),
**Wix** (connected — the site), **Lusha** (connected — this is your B2B client-side
prospecting engine and it's sitting unused in the outreach half of the app).

### Layer 5 · The team

Seven functions is already a team. What it lacks is management:

- **A roster.** One table listing each agent, what it's allowed to do, its cost
  ceiling, its schedule, its owner, whether it's on. Renders as the left column
  of the dashboard.
- **A scheduler.** `early-warnings` is explicitly designed to run daily and
  nothing runs it. Supabase Cron, one line each.
- **A shared log.** `agent_runs`, written by every function, read by the
  dashboard. Without this you cannot debug, cost, or trust any of it.
- **An escalation path.** `review_queue` exists for candidates. Agents need the
  same: "I'm not confident, a human decides." The architecture already commits
  to this ("autonomous to a line") — it just needs to be uniform.
- **A kill switch.** One row that stops every agent. You will want this at 2am
  at least once.

---

## 3. What else you'd need — the actual shopping list

### Immediately, at zero cost
- **Turn on the connectors that are installed but not connected.** Gmail, Google
  Calendar and Google Drive currently show as not connected / not enabled in
  chat. Canva, Lusha, Microsoft 365, Supabase and Wix are live.
- **Decide Gmail vs Microsoft 365.** Both are attached. Two mail systems means
  two triage paths and an assistant that's wrong half the time. Pick one.

### Required before anything touches real data
- **`ANTHROPIC_API_KEY` as a Supabase secret** — this alone is blocking
  `candidate-agent`, `chat-intake`, `inbound-email`, `csv-import` and
  `job-advert` from deploying.
- **The §11 data-protection gate.** Your own `ARCHITECTURE.md` flags it: confirm
  and *record* Anthropic's terms (no training on API data by default; DPA and
  zero-data-retention available) before candidate PII goes through an LLM. An
  executive assistant with inbox access makes this materially more urgent — it
  moves PII from a controlled pipeline into an open-ended agent context.
- **A DPIA covering the EA agent specifically.** Different lawful basis, different
  scope, and NHS-adjacent clients will ask.

### Infrastructure
- **Supabase Cron** — the scheduler. Free tier covers it.
- **An inbound-email provider** with parse webhooks (Brevo Inbound / SendGrid /
  Mailgun). `inbound-email` is written provider-agnostic and needs one chosen.
- **Object storage** — the `candidate-docs` bucket, private, already designed.
- **A VPS** (~£5–20/month) *only if* you go self-hosted Hermes later.
- **Cost controls.** Per-agent monthly ceiling, checked before each call, logged.
  An unbounded loop against a paid API is the classic way these projects die.

### Access & identity
- Current model is a domain allowlist in RLS plus desk-scoped siloing. Sound.
- An EA agent acting *as you* needs its **own service identity** and its own
  audit trail, not your credentials. "The agent did it" must be answerable.
- Mobile: Remote Control needs your machine awake and the session running. If
  you want true always-on from the phone, that's the VPS conversation.

### Skills you'd want (portable across Claude Code and Hermes)
Small, versioned, reusable: *daily brief*, *chase overdue compliance*, *draft
client outreach*, *prep for this meeting*, *weekly desk report*, *cost review*.
These are the "AI employees" in practical terms — not personas with names, but a
job description plus a checklist plus tool permissions.

---

## 4. The benefits — stated honestly

**Real, and specific to this business:**
- **Compounding context.** The single biggest one. Every session the agents get
  better at *your* business, not at business in general. A new consultant takes
  six months; the brain is instant and never leaves.
- **The 24-hour clock.** Compliance chasing, inbound triage, advert refresh,
  re-engagement — all things that don't need you awake. `early-warnings` alone
  (chasing documents before they lapse) is the highest-ROI loop in the whole
  system, per your own assessment, and it costs nothing to run.
- **One place to look.** Right now "how are we doing" is a spreadsheet, an
  Outlook folder, Eclipse and someone's memory. Cost-per-candidate by channel,
  live, is a genuine commercial edge in agency recruitment.
- **Leverage without headcount.** The desk model (`sql/18`) plus agents means a
  recruiter works their slice while the machine does the legwork. That's the
  actual business case — not replacing people, replacing swivel-chair work.
- **It's an asset.** A documented, database-backed operating system is worth
  something at sale. A folder of prompts isn't.

**Overstated in the videos, and you should discount it:**
- "AI employees that replace real daily work" — what these replace is
  *coordination overhead*. The judgement calls (is this reference genuine, is
  this candidate safe to place) stay human, and in healthcare staffing they must.
- The dashboard aesthetic is 5% of the value and 40% of the build time.
- "Set it up in 30 minutes" is true for a demo and false for anything holding
  candidate PII under UK GDPR.

**What it costs you that no one mentions:**
- You become the sysadmin of a system your business depends on. The README
  already asks for a named successor and hasn't got one. An AI OS makes that gap
  a real operational risk, not a documentation nicety.
- Agent sprawl. Seven is manageable. Twenty, undocumented, each with a key and a
  cron, is how people end up with mystery emails going to clients.

---

## 5. Sequence

Ordered by "what unblocks the most", not by what's most fun.

**Phase 0 — Ground truth (days)**
Deploy what's already written. Secrets set, schema applied on a dev branch,
`early-warnings` on cron, one agent proven end to end on synthetic data. Record
the §11 terms. *Nothing below matters until this is done.*

**Phase 1 — The spine (1–2 weeks)**
`agent_runs`, `agent_costs`, `agent_roster`, `approvals`. Every function writes
its run. Dashboard grows an agent column and an approvals queue. Kill switch.
This is the least glamorous phase and the one that makes the rest trustworthy.

**Phase 2 — The phone (days)**
Remote Control on desktop + Claude mobile app. Connectors tidied to one mail
system. First three skills written: daily brief, what-needs-me, chase-compliance.
You now run the business from your pocket, using the connectors, with no new code.

**Phase 3 — The brain (ongoing, start now)**
`ai-os/brain/` in git. Ruleset, SOPs, client quirks, decision log. Session logs
written and read. This is the layer that keeps paying out and it starts as a
folder of Markdown files.

**Phase 4 — The shell (2–3 weeks, optional)**
The AI OS dashboard proper: roster, live runs, command bar, schedule, cost.
Built on `dw-theme.css` so it looks like the rest of the estate. Do this *last* —
by then you'll know what actually needs to be on it.

**Phase 5 — Marketing loop / always-on assistant (later)**
Content calendar, Canva pipeline, Lusha-driven client-side prospecting,
attribution feeding back into the brief. Self-hosted always-on agent only if
Phase 2 proves insufficient.

---

## 6. Open decisions

1. **Option A / B / C.** Recommended: C.
2. **Gmail or Microsoft 365** as the single mail system.
3. **Inbound-email provider.**
4. **Remote Control now, or self-hosted always-on agent now.** Recommended:
   Remote Control now.
5. **How much of the EA's inbox access is acceptable** before the DPIA is done.
   Recommended: none — calendar and internal data only until it's signed off.
6. **Who the successor is.** Still open from the README, and now load-bearing.

---

## 7. References

- Hermes Agent — <https://hermes-agent.io/> (open-source, self-hosted, persistent
  memory + skills + messaging gateways + cron; wraps a model, isn't one)
- Claude Code Remote Control — Anthropic, Feb 2026; bridges a local session to
  claude.ai/code and the Claude mobile apps
- Obsidian + Claude second-brain pattern — Markdown vault + MCP access + session
  logs; the graph view in the reference video is this
- Existing internal design: `candidate-pipeline/ARCHITECTURE.md` §2 (autonomy
  gradient), §7 (data protection), §7b (desks / co-pilot model)
