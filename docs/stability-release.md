# Outreach stability release — 8 September 2026

The frontend is deployed from GitHub main to the existing Vercel sites. Supabase functions and database migrations deploy separately.

## Changes

Session refresh and same-user sign-in events no longer rebuild the workspace. Supabase calls are deferred outside the auth callback. App startup is guarded against repeated boots; profile loading finishes before the first workspace render. Signing out uses local session scope. Login network exceptions show a recoverable error.

All three bulk send paths enqueue a durable campaign through queue_outreach_mailshot. The database snapshots the template and job details, deduplicates recipient IDs, verifies the sender profile and candidate sectors, and stores one delivery record per recipient. A repeated submission using the same request ID returns the existing campaign.

The mailshot-worker cron runs every minute and claims up to 100 recipients globally, processing five at a time. It rechecks the sender profile and current candidate restrictions, do-not-use and unsubscribe state. It retains existing sender routing and personalisation. It stops taking new work after 90 seconds and returns untouched claims to the queue. Provider calls time out after 15 seconds. Interrupted delivery attempts are marked uncertain after ten minutes, never automatically resent. Explicit provider rejections are marked failed, not bounced. Sent means accepted by Brevo, not confirmed delivered.

Consultants see their latest ten campaigns, counts, and a cancel-waiting control across tabs. Confirmed queued work continues with the browser closed. Browser submission itself must finish before closing. Other applications and their functions are unchanged.

## Verification

Ten local regression tests cover session events, queue retry IDs, partial-recipient failures, access checks, suppression and provider response handling. Database tests run in rolled-back transactions check idempotency, cancellation and sector restrictions. The authenticated scheduled endpoint returned 200 with no work. No test email was sent to a real recipient.

Real consultant sign-in and a user-initiated mailshot still need operational observation. This fixes the observed app refresh behaviour; it cannot establish that every historical Joe Cooper logout had the same cause.

## Operations and rollback

Source of the new worker and database setup is committed with this release. send-mailshot remains unchanged for older clients; the new UI uses the queue worker.

To pause new claims: UPDATE outreach_private.worker_config SET enabled=false WHERE id=true. In-flight attempts can finish. Never expose the worker secret; it is generated in the private schema and read only by scheduled SQL and the privileged claim function.

To revert the frontend, restore js/app.js and index.html from a2f01939119db073568faac158c00c0dabe2ec5c. Existing queued campaigns should be completed or explicitly cancelled before reverting send controls to avoid users resubmitting them. Do not drop queue tables while records remain. Do not automatically resend uncertain items: check Brevo records first.
