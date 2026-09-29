# Connected complex care responses

Candidates open `complex-care-interest.html#invite=<random token>` and submit a short expression of interest. The server resolves the token to an existing `public.candidates` record; it never trusts a candidate ID supplied by the browser. Tokens contain 256 random bits, are stored only as SHA-256 hashes, expire after 30 days, can be revoked, and accept one response. Retrying a submitted token is idempotent. The public endpoint never returns stored candidate contact details. Anyone holding a forwarded link can submit it, so it is an invitation credential, not proof of identity. Proposed contact changes therefore require staff review and confirmation.

The staff page `complex-care.html` uses the existing signed-in session and sector access rules. It highlights current/previous complex care experience, labels it self-reported, and searches ALL/ANY selected skills plus any of several towns, counties or postcode prefixes. Preferred work areas are displayed separately from current location. This search includes the ITU COMPLEX CARE specialty and any Urgent candidate who has responded; it does not claim the SQL extraction covered every source database.

Contact proposals retain a snapshot of the original values. Accepting a stale proposal fails instead of overwriting a newer edit. Accepted town/postcode changes clear stale geocoding. No response changes a candidate's status, unsubscribe flag, registration or competency verification. Invitations cannot be generated for do-not-use or unsubscribed candidates. No invitations or mailshots are automatically sent. Campaign merge-token integration and bulk invitations are not part of this change; staff can create and copy individual links once live.

## Deployment status and order

1. `sql/complex_care.sql` has been applied to the existing Supabase project as `complex_care_candidate_responses`. It adds three RLS-protected tables and narrowly granted functions; it does not backfill candidate data.
2. The user explicitly approved publication with invitation-token authentication on 29 September 2026. `complex-care-response` version 1 is deployed with gateway `verify_jwt=false`; the 256-bit invitation is the custom credential. The service-role key remains server-side and the submission RPC is service-role-only.
3. The real form was tested against the deployed endpoint using a temporary synthetic candidate. Skills saved to the matching record; a proposed email entered pending review; existing email, do-not-use status and unsubscribe flag remained unchanged. Publish the frontend through the existing main-branch deployment and verify production routing.

The form links to the published Day Webster privacy policy. No unconfirmed pay-rate claim is included.

## Verification

Run `node --test tests/*.test.cjs`. Run `tests/complex-care.sql` through the SQL connection: it uses synthetic records in a transaction and rolls back. Assertions cover record matching, retry idempotency, all/any skills, multiple locations, proposed-versus-current location, staff approval, unchanged status, suppression blocking, and unauthorised access.

Run `node tests/build-complex-care-preview.cjs` to generate local-only mock pages in `tests/preview`. These use fictional examples and make no API calls. The real browser form was also submitted to the deployed endpoint and the resulting database record verified. No campaign emails were sent. A signed-in consultant browser check remains dependent on an available consultant session.

## Rollback

Revert the frontend files and disable/remove the response endpoint. Preserve response history and the additive tables; do not drop tables holding real responses. Existing outreach functionality does not depend on the new tables until the frontend change is published.
