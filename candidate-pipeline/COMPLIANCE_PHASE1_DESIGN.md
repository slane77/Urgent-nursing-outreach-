# Compliance Portal — Phase 1 design (build spec)
### Scale + bulk migration + the compliance team's workspace

Builds directly on Phase 0 (`sql/22_compliance_sets.sql`, `23_work_ready_gate.sql`,
`24_seed_nhs_rn_set.sql`). Target stack is this repo's cockpit: **vanilla HTML +
`dw-theme.css` + supabase-js**, `candidate` schema, `is_authorized_user()` /
`is_compliance_officer()`.

## Locked decisions
- **D1 — import representation = migrate-with-provenance.** Known-good legacy
  items import as `status='verified'` (so RAG counts them and the bench stays
  placeable), but stamped migrated (`channel='import'`, `source_confidence='migrated'`,
  new boolean `migrated=true`) and re-verified on next expiry. One
  `verification_events` row per migrated item: `event_type='verified'`,
  `method='import'`, `actor_kind='system'`, `notes='bulk migration — provenance only'`.
- **D2 — grace window = 90 days.** Migrated items with no known expiry get
  `expires_at = migration_date + 90 days` so nothing stays trusted-but-unverified
  forever; they roll into the existing `expiring_items` sweep.
- **D3 — waive semantics:** add `'waived'` to `compliance_items.status`;
  recompute treats a waived blocking item as satisfied **but caps the set at
  amber** (can't go green). Waive reason is mandatory → `verification_events.notes`.
- **D4 — derived `candidate_compliance_status` RAG is the single source of truth
  for work-ready.** The legacy free-text `candidates.compliance_status` stays a
  manual recruiter note and must NOT gate placement.
- **D5 — HCA `care_certificate`:** add a `nursing`-scoped `care_certificate`
  catalogue row (or reference the existing complex_care/care_homes one) so the
  `NHS_HCA` set can require it. Coder picks the cleaner option.
- **D6 — storage/region:** confirm the Supabase project is UK/EU region and the
  `candidate-docs` bucket `storage.objects` policies are restricted to
  `is_authorized_user()` (deployment check, not code).

---

## 1. Requirement sets for every job type + auto-assignment

### Sets to compose (migration 27, same shape as `24_seed_nhs_rn_set.sql`)
All from already-seeded catalogue codes in `sql/13_compliance_requirements.sql`.

| Set code | Discipline / specialty | Blocking | Standard | Advisory |
|---|---|---|---|---|
| `NHS_RN` (exists) | nursing | rtw, proof_of_address, references_3yr, nmc_registration, qualification_cert, dbs_enhanced, occupational_health, immunisations | mandatory_training | cv, overseas_police_check |
| `NHS_HCA` | nursing/`hca` | rtw, proof_of_address, references_3yr, dbs_enhanced, care_certificate, occupational_health, immunisations | mandatory_training | cv |
| `NHS_DOCTOR` | doctors | rtw, proof_of_address, references_3yr, gmc_registration, qualification_cert, indemnity, dbs_enhanced, occupational_health, immunisations | mandatory_training | cv, overseas_police_check |
| `AHP_HCPC` | ahp | rtw, proof_of_address, references_3yr, hcpc_registration, qualification_cert, dbs_enhanced, occupational_health, immunisations | mandatory_training | cv, overseas_police_check |
| `COMPLEX_CARE` | complex_care | rtw, proof_of_address, references_3yr, dbs_enhanced, care_certificate, occupational_health | mandatory_training | cv |
| `CARE_HOME` | care_homes | rtw, proof_of_address, references_3yr, dbs_enhanced_adults, care_certificate, occupational_health | mandatory_training | cv |
| `CHILDRENS` | childrens | rtw, proof_of_address, references_3yr, dbs_enhanced_children, qualification_cert | mandatory_training | cv |
| `INSURANCE` | insurance | rtw | proof_of_address, financial_reference | cv, cii_qualification |
| `REG_MGR_CHILDRENS` (add-on) | childrens/`registered_mgr` | fit_person_declaration | — | — |
| `REG_MGR_CARE_HOME` (add-on) | care_homes/`registered_mgr` | fit_person_declaration | — | — |

Add-on sets **stack**: a candidate row in `candidate_requirement_sets` can hold
multiple sets; `recompute_candidate_status` already loops all active sets.

### Mapping table + auto-assign (migration 26)
```
candidate.requirement_set_map (
  id uuid pk, discipline_id uuid not null, specialty_id uuid null,
  set_id uuid not null, add_on boolean default false,
  active boolean default true, priority int default 100,
  unique(discipline_id, specialty_id, set_id))
```
Resolution: **base** set = highest-priority row matching (discipline, specialty),
specialty match beats discipline-wide (`specialty_id is null`); **plus all**
`add_on=true` matches.

`candidate.assign_requirement_sets(p_candidate_id)` (SECURITY DEFINER): resolve
base+add-ons → upsert active into `candidate_requirement_sets` (denormalise
set_code/latest active version) → deactivate sets that no longer resolve (Phase 0
recompute already drops their stale status row) → call `materialize_items()` to
insert `not_started` placeholder `compliance_items` for requirements with no item
yet. Day-to-day trigger: `AFTER INSERT OR UPDATE OF discipline_id,
primary_specialty_id ON candidate.candidates` → `assign_requirement_sets` (guarded — see §3).

## 2. Bulk migration (10–15k candidates, ~150k items) — set-based, no trigger storm

Identity import stays on the existing `csv-import`. Add
`functions/compliance-import/index.ts` mirroring csv-import's two modes:
- `mode:"map"` — Claude maps headers to composite targets `req:<code>:<field>`,
  field ∈ {status, issue_date, expiry_date, number, evidence_note}.
- `mode:"commit"` — parse rows client-side, POST ~2,000-row batches to a single
  RPC `candidate.import_compliance_bulk(p_rows jsonb)` (SECURITY DEFINER, grant
  service_role). No per-row edge work.

`import_compliance_bulk` (migration 29):
1. `select set_config('candidate.bulk_load','on', true);` (txn-local; disables recompute/assign triggers).
2. Match rows to candidates by `lower(email)` then `phone`; report unmatched.
3. Auto-assign sets: `insert ... select` into `candidate_requirement_sets` via `requirement_set_map`, `on conflict do nothing`.
4. Set-based insert of `compliance_items` from `jsonb_to_recordset(p_rows)` joined to `compliance_requirements` on `code`; compute `expires_at` from provided date, else catalogue `expiry_rule`, else **migration_date + 90 days** (D2); `status='verified'`, `channel='import'`, `source_confidence='migrated'`, `migrated=true` (D1).
5. One `verification_events` row per item (verified/import/system, provenance note).
6. `recompute_candidate_status_bulk(array_agg(distinct candidate_id))` — once per batch.
7. `set_config('candidate.bulk_load','off', true);`

**Trigger guard (migration 25):** `create or replace` the three Phase 0 trigger
fns (`trg_recompute_from_item`, `trg_recompute_from_cand_set`,
`trg_recompute_from_set_item`) and the new assign trigger to early-return when
`current_setting('candidate.bulk_load', true) = 'on'`.

### Scale indexes (migrations 25/26/28)
- `compliance_items (candidate_id, requirement_id, updated_at desc)` — the recompute lateral hot path (most important).
- `compliance_items (requirement_id)`; `compliance_items (migrated) where migrated`.
- `candidate_compliance_status (status)`, `(set_id, status)`, `(next_expiry)`.
- `candidate_requirement_sets (set_id) where active`.
- `requirement_set_map (discipline_id, specialty_id)`. (`candidates (phone)`, `candidates_email_lower_idx` already exist.)

## 3. `compliance.html` — the compliance team's workspace (at 15k)

Vanilla HTML in `candidates.html` style. Add "Compliance" to `topnav` on all
cockpit pages. In-page gate to `is_compliance_officer` (DB enforces the real boundary).

- **Dashboard**: one RPC `candidate.compliance_dashboard(p_desk, p_set)` → RAG
  counts (`candidate_compliance_status` grouped), expiring buckets (reuse
  `expiring_items`), needs-review count, migration backlog (`migrated`).
- **Worklist** (server-side filter + pagination): a view
  `candidate.compliance_worklist` (security_invoker) pre-joining status→candidate→
  discipline→set, one row per (candidate, set). Query like candidates.html:
  `.select(...,{count:'exact'}).eq(...).range(...)`. Filters map to indexed cols
  (status, discipline_id, set_id/set_code, desk/owner, next_expiry window,
  needs_human, migrated). **Scale fix (migration 25): extend
  `recompute_candidate_status` to also write `needs_human_count` and
  `expiring_count` scalars onto `candidate_compliance_status`** so the worklist
  filters/sorts on indexed scalars, not live aggregates over 150k items.
- **Per-candidate detail** (overlay): checklist = `requirement_set_items` ⋈
  `compliance_requirements` LEFT JOIN this candidate's `compliance_items`;
  "migrated — re-verify" badge where `migrated`. Actions via one RPC
  `candidate.decide_item(p_item_id, p_decision, p_reason)` (SECURITY DEFINER,
  is_compliance_officer) that atomically updates status AND inserts the matching
  `verification_events` row: verify→verified (clear migrated), reject→unsuitable,
  waive→waived (reason mandatory). Evidence upload to private `candidate-docs`
  bucket, recorded in new `candidate_evidence` (§5), signed URLs (300s). Audit-pack
  action reuses/extends `audit-pack.html`.
- **Bulk ops**: `bulk_assign_set(ids, set_code)`, `bulk_request(ids, codes)` —
  both use the bulk_load guard + one bulk recompute.

## 4. RLS / required Phase 0 fix
`18_desks.sql` silos `candidates` reads to the recruiter's desk. **Amend the
`desk read candidates` policy (migration 25) to add `or
candidate.is_compliance_officer()`** so compliance officers see the whole bench.
Preserve Phase 0 guarantees: `candidate_compliance_status` keeps NO client write
policy; `verification_events` stays insert-only for compliance officers (immutable).

Access: recruiter = own desk read, RAG read, no event insert; compliance officer =
all-desk read, decide_item, evidence read/insert, import; admin = + set/map write;
service_role = import_compliance_bulk / recompute / work-ready.

## 5. Phase 0 gap to close: evidence table (migration 28)
`compliance_items` has a single `artefact_path`; the portal needs multiple docs
per requirement + audit-pack compilation:
```
candidate.candidate_evidence (
  id, candidate_id, item_id, requirement_id, bucket, path, filename,
  content_type, size_bytes, sha256, uploaded_by, uploaded_at)
```
RLS: authorized read; compliance-officer insert; admin delete.

## 6. Build order
1. **[decisions locked above]**
2. `25_compliance_scale.sql` — bulk_load guard on the 3 trigger fns; `recompute_candidate_status_bulk(uuid[])`; extend `recompute_candidate_status` to write `needs_human_count`/`expiring_count` + handle `'waived'`; alter `compliance_items` status check to add `'waived'` + add `migrated boolean`; amend `desk read candidates` policy for `is_compliance_officer()`; scale indexes.
3. `26_requirement_set_map.sql` — map table + `assign_requirement_sets()` + `materialize_items()` + guarded candidates trigger + indexes.
4. `27_seed_requirement_sets.sql` — compose the sets above + seed `requirement_set_map`.
5. `28_evidence.sql` — `candidate_evidence` + RLS + indexes.
6. `29_compliance_ops.sql` — `compliance_worklist` view; RPCs `compliance_dashboard`, `decide_item`, `bulk_assign_set`, `bulk_request`, `import_compliance_bulk`; grants.
7. `functions/compliance-import/index.ts` (map + commit).
8. `compliance.html` (dashboard → worklist → detail/decide → evidence → bulk) + topnav link + extend `audit-pack.html`.
9. Spot-check RAG vs source sample; verify migrated provenance + re-verify worklist.
