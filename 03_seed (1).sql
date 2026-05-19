-- ============================================================================
--  Urgent Nursing Outreach Manager — Seed Templates
--  File: 03_seed.sql
--  Run this THIRD (optional). Inserts the three default email templates that
--  shipped with the original local tool. Skip if you've already created
--  templates in the live system. Safe to run only once — the UNIQUE
--  constraint on templates.name will reject duplicate runs.
--
--  Note: the body text uses PostgreSQL dollar-quoting ($body$...$body$) so
--  apostrophes inside the text don't need escaping. This is a feature, not
--  a typo — leave the $body$ markers alone unless you know SQL.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- Template 1: Practice Nurse - General Availability
-- ----------------------------------------------------------------------------
insert into public.templates (name, subject, body) values (
  'Practice Nurse - General Availability',
  'Practice Nurse available in {{Town}} - {{FirstName}}',
  $body$Hi {{FirstName}},

I hope you are well.

I wanted to make you aware that we currently have an experienced Practice Nurse available for ad-hoc, locum or longer-term cover, happy to travel up to 30 minutes from {{Town}}.

Clinical skills include:
- Chronic disease management
- Immunisations and vaccinations
- Minor wounds and complex wounds, leg ulcers
- Smears
- ECGs and blood samples

If this would be of any interest at {{Org}} now or in the coming weeks, please reply and I will share the candidate's CV and availability.

Kind regards,
Scott

---
If you do not wish to receive these updates, please reply to this email with 'Unsubscribe' in the subject line.$body$
);


-- ----------------------------------------------------------------------------
-- Template 2: ANP / Advanced Nurse Practitioner
-- ----------------------------------------------------------------------------
insert into public.templates (name, subject, body) values (
  'ANP / Advanced Nurse Practitioner',
  'ANP available near {{Town}} - {{FirstName}}',
  $body$Hi {{FirstName}},

Quick note to flag that we have an Advanced Nurse Practitioner available for sessional work in the {{Town}} area, including face-to-face appointments, triage, and home visits.

If {{Org}} is looking for cover - either ongoing or for specific clinics - I would be happy to share the candidate's details.

Kind regards,
Scott

---
If you do not wish to receive these updates, please reply to this email with 'Unsubscribe' in the subject line.$body$
);


-- ----------------------------------------------------------------------------
-- Template 3: GP Locum Availability
-- ----------------------------------------------------------------------------
insert into public.templates (name, subject, body) values (
  'GP Locum Availability',
  'GP locum cover in {{Town}}',
  $body$Hi {{FirstName}},

We have a GP available for locum sessions and willing to travel up to 30 minutes from {{Town}}.

Full GMC registration, on the Performers List, experienced in NHS general practice including telephone triage, face-to-face, home visits, and EMIS/SystmOne.

If you have any sessional gaps at {{Org}} I would be happy to send the CV across.

Kind regards,
Scott

---
If you do not wish to receive these updates, please reply to this email with 'Unsubscribe' in the subject line.$body$
);


-- ----------------------------------------------------------------------------
-- Sanity check — should return 3 rows
-- ----------------------------------------------------------------------------
-- select name, subject, length(body) as body_length from public.templates;
