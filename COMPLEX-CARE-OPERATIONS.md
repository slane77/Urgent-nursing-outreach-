# Complex care operations

Open `complex-care-operations.html`, or choose Availability and shifts from the nurse bank. Each nurse card also links directly to availability and approval records.

## Workflow

1. Add a provider package using a non identifying reference, postcode, adult or child population, required skills and controlled care plan reference. Do not enter patient names or upload clinical documents. Requirements are immutable; retire and recreate a package if its needs change.
2. Record the nurse's confirmed availability with exact start and end times, confirmation time and a conversation or email reference. Availability must cover the entire requested shift and be confirmed within 7 days of the booking check. Record fresh availability to renew a confirmation; withdraw a record if availability changes.
3. An existing administrator records documentary clinical sign off, compliance evidence and provider package acceptance. Record the responsible clinician and compliance reviewer, evidence references and validity times. This is a record of assessments performed outside the application, not automated clinical approval. Renewal creates a new record; revocation needs a reason and records actor/time.
4. Add a provider shift request, exact start and end times, request reference and hourly pay/charge rates. One request represents one nurse; create separate requests where multiple nurses are required.
5. Open the shortlist. Nurses with valid package approval, fresh availability and no restrictions or conflicting bookings appear first. Other results explain missing checks. Record nurse and provider acceptance references and confirm travel, rest and external commitments before saving a booking.
6. Cancel or complete a booking with an outcome note. Cancellation leaves the request open for replacement; close the request if cover is no longer needed. A completed or cancelled booking cannot be rewritten. Original and outcome actor/times remain stored.

All times display in Europe/London. Entry defaults to UK local time. At a clock change, a missing or ambiguous local time is rejected; select UTC and enter the intended UTC time. Approval expiry must cover the end of the shift.

## Boundaries

Availability, approvals and bookings are entered by signed in staff with Urgent Nursing access. The existing administrator role is required to record/revoke clinical and compliance approval. There is no external provider portal or nurse availability portal in this release. No messages or emails are sent by these screens. Rates are planning data, not a payroll or invoice calculation. Rest, travel and bookings elsewhere require manual confirmation.

The dashboard flags booked shifts when availability is withdrawn or becomes stale, approval is revoked/expires, the package is retired or a candidate restriction applies. These warnings appear when the shift list is refreshed, within the selected date range. No background alerts or automatic cancellations are created. Do not treat a past successful booking as continuing clearance.

## Import hold review on 17 October 2026

Scott Lane authorised removal of unnecessary restrictions. Of 1,687 held ITU COMPLEX CARE records, 864 had only the missing exported contact preferences hold, with no source DNU, do not contact, hold, shared identity or prior do_not_use flag. These were released: 461 restored to dormant, 4 to processing and 399 to requires_update. None was marked clinically approved or available for a shift. Source notes and unsubscribed values were preserved, and a dated audit note was appended with marker `cc_import_hold_release_20261017`.

The remaining 823 were retained because of recorded source refusal, restriction or identity concerns. Release does not fabricate consent. No outreach was queued or sent.

## Technical release and verification

Apply `supabase/migrations/20261017065107_complex_care_operations.sql` once to the existing outreach database, then deploy the static files through the existing Git integration. Earlier schema remains in the existing `sql/` directory; this migration is additive to that installed schema and is not a standalone bootstrap.

Tables use RLS and column grants. Creation timestamps and staff IDs cannot be supplied by browser clients. Package specifications and approval evidence are immutable. Booking validation runs in a database trigger, serialising concurrent nurse bookings and preventing multiple active assignments to one shift. Rollback the frontend if necessary; retain operational tables and their records.

Checks: 25 Node tests passed, including UK clock changes. Transactional database assertions covered eligibility, stale availability, overlaps, record immutability, cancellation, revocation, anonymous/cross sector access, and ordinary consultant versus administrator privileges. A concurrent synthetic booking test accepted exactly one overlapping booking. Synthetic test data was removed. DOM workflow tests covered package, availability, approval, request, booking, withdrawal warning, cancellation and sign out. Full visual browser testing remains unverified in this environment.

The security advisor reported no findings naming these new objects. Existing unrelated findings remain unchanged.
