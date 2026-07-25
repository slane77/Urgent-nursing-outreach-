# Deployment runbook — Candidate Pipeline

Stand the whole pipeline up **on an isolated Supabase dev branch first**, prove
it on synthetic data, then promote to production. Nothing here touches the
existing outreach system (it's a separate `candidate` schema).

> **Order matters.** Do the steps top to bottom. ☐ = tick as you go.

---

## 0. Before you start — gather

- ☐ **Anthropic API key** + confirm data-handling terms (DPA / no-training-by-default / zero-data-retention). *Use synthetic candidates on dev until this is signed off (§11).*
- ☐ **Brevo account** + API key (transactional email).
- ☐ A **sending domain/subdomain** you control (e.g. `candidates.daywebster.com`) for `From` and `Reply-To`.
- ☐ (Later) Indeed / Reed / CV-Library recruiter **API credentials**.

---

## 1. Create the dev environment

**Option A — Supabase Branching** (Pro plan): Dashboard → Branches → create branch `candidate-dev`. You get an isolated DB + its own URL/keys.
**Option B — a second free Supabase project** named `candidate-dev` as your sandbox.

☐ Note the dev project's **Project URL**, **anon (publishable) key**, and **service-role key**.

---

## 2. Apply the schema (in order)

In the dev project's **SQL Editor**, run each file in order:

☐ `sql/10_candidate_schema.sql`
☐ `sql/11_candidate_policies.sql`
☐ `sql/12_candidate_seed.sql`
☐ `sql/13_compliance_requirements.sql`
☐ `sql/14_early_warnings.sql`
☐ `sql/15_inbound_email.sql`
☐ `sql/16_sourcing.sql`
☐ `sql/17_dashboard.sql`
☐ `sql/18_desks.sql`
☐ `sql/19_app_users.sql`

☐ **Expose the schema:** Settings → API → *Exposed schemas* → add `candidate`.
☐ **Storage:** create a **private** bucket named `candidate-docs`.

---

## 3. Set function secrets

In the dev project: Edge Functions → Secrets (or `supabase secrets set`). Set:

| Secret | Example / note |
|---|---|
| `ANTHROPIC_API_KEY` | `sk-ant-…` |
| `BREVO_API_KEY` | from Brevo |
| `CANDIDATE_SENDER_EMAIL` | `candidates@candidates.daywebster.com` |
| `CANDIDATE_SENDER_NAME` | `Day Webster` |
| `REPLY_DOMAIN` | `candidates.daywebster.com` |
| `REPLY_LOCAL` | `compliance` |
| `INBOUND_SECRET` | any random string |
| `CRON_SECRET` | any random string |
| `WORK_READY_TOKEN` | any random string — shared bearer the external booking system sends to the `work-ready` gate; the function returns 401 until this is set |
| `PUBLIC_SITE_URL` | where `intake.html` is hosted (see step 6) |
| `ORG_NAME` / `ORG_URL` | `Day Webster` / `https://www.daywebster.com` |

`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are injected automatically — don't set them.

---

## 4. Deploy the edge functions

The functions import a shared folder, so deploy them with `_shared` alongside.
Place them under `supabase/functions/` like this (copy from
`candidate-pipeline/functions/`):

```
supabase/functions/_shared/{email.ts,jobposting.ts}
supabase/functions/candidate-agent/index.ts
supabase/functions/<each other function>/index.ts
```

Deploy (`supabase functions deploy <name>` for each, or the dashboard editor),
with these JWT settings:

| Function | verify_jwt | Who calls it |
|---|---|---|
| `candidate-agent` | **true** | staff (cockpit) |
| `csv-import` | **true** | staff (importer) |
| `compliance-import` | **true** | staff (compliance bulk migration) |
| `reference-request` | **true** | staff |
| `job-advert` | **true** | staff (vacancies) |
| `outreach-campaign` | **true** | staff |
| `candidate-intake` | **false** | public form |
| `inbound-email` | **false** | email provider (`?secret=`) |
| `early-warnings` | **false** | cron (`?secret=`) |
| `jobs` | **false** | public (Google) |
| `work-ready` | **false** | external booking system (Bearer `WORK_READY_TOKEN`) — compliance gate; returns 401 until the token is set |

> **Compliance Phase 0 migrations** — apply `sql/22_compliance_sets.sql`,
> `sql/23_work_ready_gate.sql`, then `sql/24_seed_nhs_rn_set.sql` (after 10–21).
> They add versioned requirement sets, the `is_compliance` staff flag, the
> append-only `verification_events` audit table, and the computed work-ready
> gate (`is_work_ready()` / `work_ready_status()`), plus a seeded NHS Registered
> Nurse set. The external booking system calls the `work-ready` function to gate
> placement (fail-closed: unreachable / red ⇒ do not place).
>
> Note on set versions: candidates are pinned to the set *version* they were
> assigned. Publishing a new active version (e.g. `NHS_RN` v2) does not move v1
> candidates automatically — reassign them to the new version so the gate
> recomputes; until then the booking system (which resolves `set_code` to the
> latest active version) reads them as red (fail-closed, not fail-open).
>
> **Compliance Phase 1 migrations** — after 22–24, apply in order:
> `sql/25_compliance_scale.sql` (adds `'waived'` + `migrated` to
> `compliance_items`, the `candidate.bulk_load` trigger guard, the
> `needs_human_count`/`expiring_count` scalars + waived-caps-at-amber recompute,
> `recompute_candidate_status_bulk()`, the compliance-officer desk-read exemption,
> and the scale indexes), `sql/26_requirement_set_map.sql` (the
> `requirement_set_map` table + `assign_requirement_sets()` / `materialize_items()`
> + the auto-assign trigger), `sql/27_seed_requirement_sets.sql` (composes
> NHS_HCA / NHS_DOCTOR / AHP_HCPC / COMPLEX_CARE / CARE_HOME / CHILDRENS /
> INSURANCE + the REG_MGR_* add-ons and seeds the map; adds a nursing-scoped
> `care_certificate`), `sql/28_evidence.sql` (`candidate_evidence` + RLS), and
> `sql/29_compliance_ops.sql` (the `compliance_worklist` view + the
> `compliance_dashboard` / `decide_item` / `bulk_assign_set` / `bulk_request` /
> `import_compliance_bulk` RPCs). Then deploy the `compliance-import` edge
> function (verify_jwt=true, staff): `map` mode uses Claude to map spreadsheet
> headers to `req:<code>:<field>` targets; `commit` mode batches to
> `import_compliance_bulk` (service_role). Migrated items import as
> `verified`+`migrated` with a 90-day grace expiry and one provenance
> `verification_events` row each.

---

## 5. Schedule + inbound

☐ **Cron:** schedule `early-warnings` daily — Dashboard → Cron, or pg_cron:
`select cron.schedule('early-warnings','0 8 * * *', $$ select net.http_post('https://<dev>.functions.supabase.co/early-warnings?secret=<CRON_SECRET>') $$);`
☐ **Inbound email:** in your email provider (Brevo Inbound Parsing / SendGrid
Inbound Parse / Mailgun Routes), point inbound to
`https://<dev>.functions.supabase.co/inbound-email?secret=<INBOUND_SECRET>` and
map its payload to `{from,to,subject,text,html,attachments[]}`.
☐ **Deliverability:** in Brevo, verify the sending domain and add **SPF, DKIM,
DMARC** records. Don't send volume until this is green.

---

## 6. Host the front-end (pointed at the dev branch)

The pages (`dashboard.html`, `candidates.html`, `vacancies.html`,
`candidate-import.html`, `intake.html`) are static and read `js/config.js`.

☐ For dev testing, set `js/config.js` to the **dev** project's URL + anon key
(keep a copy of the prod values). Set `PUBLIC_SITE_URL` (step 3) to wherever
these are served (Vercel preview, a dev Pages site, or even local `file://`
for the staff pages — though Storage/login work best over http).

---

## 6a. Desks & roles (co-pilot)

Visibility is **siloed by desk**. Until you populate `staff`, *everyone on an
authorised domain is treated as admin and sees all* (safe bootstrap). To switch
on siloing once people have logged in once (so they exist in `auth.users`):

```sql
-- 1. make yourself admin (see everything + the control tower)
insert into candidate.staff (user_id, full_name, is_admin)
select id, 'Scott Lane', true from auth.users where email = 'you@daywebster.com';

-- 2. add a recruiter to one or more desks (they then see only those desks)
insert into candidate.staff (user_id, is_admin)
select id, false from auth.users where email = 'recruiter@daywebster.com';
insert into candidate.desk_members (desk_id, user_id)
select dk.id, u.id from candidate.desks dk, auth.users u
where dk.code = 'theatres' and u.email = 'recruiter@daywebster.com';
```

Candidates **auto-route** to a desk on qualification (Theatres → Theatres desk,
ward/A&E/ITU/HCA/RMN → Nursing North/South by region, neonatal/paeds →
Midwifery, ANP/ENP → Primary Care, etc.). Anything that can't be matched stays
**Unrouted** and shows in the dashboard + the cockpit's "Unassigned (to route)"
filter for an admin to place. (North/South routing needs the candidate's
`region` to read "North"/"South" — normalise region for full auto-split, or
route those manually for now.)

**Easier:** once deployed, use **`admin.html`** to do all of this by clicking —
toggle who's an admin, put recruiters on desks, create desks, and edit routing
rules. (The SQL above is just the manual fallback.) Staff appear in the admin
people list automatically after they've signed into any staff page once.

---

## 7. Smoke test (synthetic data only)

Work through the loop and watch the **dashboard** populate:

1. ☐ Open `intake.html` → register a fake candidate → appears in `candidates.html` as `sourced`.
2. ☐ In the cockpit, open them → **Run agent** → it replies + fills fields + requests docs.
3. ☐ `candidate-import.html` → import a tiny synthetic spreadsheet → rows land as `sourced`, deduped.
4. ☐ `vacancies.html` → create a vacancy → advert generates → open the public **jobs** page (`/functions/v1/jobs?slug=…`) and check it renders + has JSON-LD (view source).
5. ☐ Cockpit → send a **reference request** (via `reference-request`) to a test inbox; reply to it; confirm `inbound-email` ingests it and it shows in the review queue.
6. ☐ Manually hit `early-warnings?secret=…` → check it returns counts.
7. ☐ Run an `outreach-campaign` (referral/reengagement) against the synthetic bench.
8. ☐ Dashboard: KPIs, funnel, intake-by-channel, campaign cost-per-candidate, activity feed all populate.

Validate JSON-LD at search.google.com/test/rich-results before relying on Google for Jobs.

---

## 8. Promote to production

When dev is proven and the §11 terms are signed off:

1. ☐ Run `sql/10 → 19` on the **production** project (or merge the branch).
2. ☐ Expose `candidate` schema; create the `candidate-docs` bucket.
3. ☐ Set the same secrets with **production** values.
4. ☐ Deploy the functions to production; schedule cron; point the inbound webhook.
5. ☐ Restore `js/config.js` to production URL/anon key; set `PUBLIC_SITE_URL` to the live host.
6. ☐ Go live with inbound + Google for Jobs first; turn on paid channels once connectors + budgets are set.

---

## Rollback

Everything is additive and isolated. To remove it entirely:
`drop schema candidate cascade;` (dev), delete the functions, delete the
`candidate-docs` bucket. The outreach system is untouched throughout.
