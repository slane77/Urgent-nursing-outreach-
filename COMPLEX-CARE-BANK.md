# Complex care bank improvements

The complex care workspace now includes ITU COMPLEX CARE, ITU / Critical Care, Paediatrics and questionnaire responders. Do Not Use and unsubscribed candidates are excluded by default. Uncheck that filter only to review held records; sending restrictions still apply.

## Recruitment workflow

Filter by candidate pool, experience, skills, location, reported care population, preferred shift, usual notice, screening stage and follow up due. Counts reflect the complete filtered result, not just the current page.

Open Screening on a candidate card to save a stage, follow up date and note. History is append only and records the signed in staff member. Stages are To contact, Screening, Compliance review, Clinical review and Paused. None means clinically approved or ready to work. Do not enter patient details or clinical documents in screening notes.

The questionnaire separates actual adult/child care experience from work preference. Each selected skill can include recency, setting and equipment. Notice and transport are general preferences, not live shift availability. Existing personal invitation links continue to work.

## Personal invitation campaigns

Create a candidate email template in the outreach workspace. Put `{{ComplexCareLink}}` in the body, never the subject. Suggested wording is available under Prepare a personal invitation campaign on the complex care page. Select an Urgent Nursing audience, review the template and recipients, then use the existing queue confirmation.

The worker creates a unique 30 day link for each eligible recipient immediately before sending. Only a hash is stored. It rechecks sector, sender access, Do Not Use, unsubscribe and complex care contact preferences. Declined, phone only and no follow up respondents are skipped. Links are not supported for contacts or other candidate sectors. No campaign was created or sent as part of this release.

## Deployment and checks

1. Apply `sql/complex_care_bank.sql` once.
2. Deploy `complex-care-response` with `index.ts` and `validation.mjs`.
3. Deploy `mailshot-worker` with `index.ts`, `delivery.ts` and `complex-care-link.mjs`.
4. Deploy the static frontend via the existing Git integration.

Both edge functions retain their existing custom authentication; no deployment protection changes are required. Rollback the frontend and edge versions if needed; keep additive columns and history so recorded information is retained.

Verification: 23 Node tests passed, including campaign rendering and restrictions. Transactional SQL assertions passed for search, evidence persistence, stage counts, append only history, actor spoof prevention and cross sector/anonymous access. A synthetic submission through the deployed endpoint persisted the new evidence fields; all test data was removed. Synthetic DOM checks cover dashboard controls and form payloads. Full visual browser checks were unavailable because the browser download failed.

The security advisor returned existing findings on unrelated views and functions; none named the new bank objects. Those existing findings were not changed in this release.

Next phase: dated availability, verified compliance evidence, package specific competency sign off, provider shift requests and booking outcomes. This release is recruitment and screening infrastructure, not a clinical clearance or shift dispatch system.
