# Urgent Nursing Outreach Manager

A lightweight web app for managing the GP surgery outreach campaign at Urgent
Nursing (Day Webster Group). Replaces a manual Word + Excel + Outlook process
with a database-backed tool that handles contact management, email templates,
and personalised mail merges — while still sending emails through personal
Outlook to stay within NHS-friendly send mechanics.

## What it does

- Holds the GP surgery contact database, with three statuses: **Leads**, **Live**, **Unsubscribes**
- Stores reusable email templates with merge tokens (`{{FirstName}}`, `{{Town}}`, `{{Org}}` etc.)
- Builds personalised email batches in one of two modes:
  - **One-by-one mode** — copy/paste each personalised email into Outlook (best for small / warm sends)
  - **Mail merge CSV mode** — downloads a filtered CSV ready for Word Mail Merge → Outlook bulk send
- Logs every email sent (date, template, batch, status) for audit and analysis
- Auto-excludes anyone on the Unsubscribe list from every send

## Tech stack

- **Frontend** — vanilla HTML + JavaScript, no framework, no build step
- **Backend** — [Supabase](https://supabase.com) (Postgres database + Auth)
- **Hosting** — GitHub Pages (free, served straight from this repo)

Anyone who can read JavaScript and SQL can maintain this. No NPM, no Webpack,
no Docker, no CI/CD. Open `index.html` in a browser and it just runs.

## First-time setup

### 1. Database

1. Create a new project at [supabase.com](https://supabase.com)
2. Open SQL Editor → New query → paste contents of `sql/01_schema.sql` → Run
3. New query → paste `sql/02_policies.sql` → Run
4. New query → paste `sql/03_seed.sql` → Run

This creates three tables (`contacts`, `templates`, `email_sends`), a helper
view (`contacts_with_last_email`), and 12 row-level security policies that
restrict database access to authorised email domains only.

### 2. Auth configuration

In Supabase Dashboard:

- **Authentication → Providers** → confirm Email is enabled (on by default)
- **Authentication → URL Configuration** → set Site URL to the GitHub Pages URL

### 3. App config

Edit `js/config.js` and paste in:

- `SUPABASE_URL` — your Project URL (Project Settings → API)
- `SUPABASE_ANON_KEY` — your anon public key (Project Settings → API)

Both are safe to commit publicly. The database is protected by RLS policies,
not by key secrecy. **Never commit the `service_role` key** — that one bypasses
all policies.

### 4. Hosting

Repo **Settings → Pages** → Source: `main` branch, root folder → Save. Site
goes live at `https://<username>.github.io/<repo-name>` within a couple of minutes.

## Authorised users

By default, only emails from these domains can log in:

- `@daywebster.com`
- `@daywebstergroup.com`
- `@homecare-providers.com`
- `@homecareproviders.co.uk`

To change the list: edit the function in `sql/02_policies.sql` (lines 24–28)
and re-run that block in the Supabase SQL Editor.

## Backup & disaster recovery

- Supabase free tier includes daily automated database backups
  (Dashboard → Database → Backups)
- For manual exports: Table Editor → each table → "..." → Export as CSV
- A legacy single-file HTML version with localStorage is preserved at
  `legacy/urgent_nursing_outreach_manager.html` as an offline emergency fallback

## Maintainers

- Original build: Scott Lane, May 2026
- Successor: _to be added_

If you make substantial changes, please update this README so the next person
picking this up doesn't have to reverse-engineer the system.
