// ============================================================================
//  Day Webster — Candidate Pipeline · csv-import (Supabase Edge Function)
//
//  STATUS: DRAFT — NOT YET DEPLOYED. For review only.
//
//  "Smart" bulk importer for the years of loose candidate spreadsheets. The
//  intelligence is at the HEADER level, not per row: one Claude call maps each
//  file's columns to the candidate schema (cheap, once per file); the mapping
//  is then applied DETERMINISTICALLY to every row. This is the assessment's
//  "classify the genre once, apply deterministically" principle.
//
//  Two modes (POST JSON):
//    { mode: "map",    headers: [...], samples: [ {h: v}, ... ] }
//        -> returns { mapping: [{source_header, target_field}], notes }
//    { mode: "commit", mapping: [...], rows: [ {h: v}, ... ] }
//        -> dedupes on email OR phone, upserts NEW rows as status='sourced'
//           (source 'import'; email rows are idempotent, phone-only rows are
//           kept too), returns { inserted, skipped_duplicates, skipped_no_contact,
//           phone_only_inserted }
//
//  Imported candidates land UNQUALIFIED (status 'sourced'); the candidate-agent
//  qualifies them later. Raw rows are kept in source_detail for provenance.
//
//  AUTH: staff-only. verify_jwt=true at deploy; we also check the email domain.
//  ISOLATION: writes ONLY to the `candidate` schema.
// ============================================================================

import Anthropic from "npm:@anthropic-ai/sdk";
import { createClient } from "npm:@supabase/supabase-js";
import { verifyStaff, unauthorized, CORS } from "../_shared/auth.ts";

const MODEL = "claude-opus-4-8";
const anthropic = new Anthropic({ apiKey: Deno.env.get("ANTHROPIC_API_KEY")! });
const sb = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { db: { schema: "candidate" } },
);

// Target fields the importer understands. Everything else is kept as provenance.
const TARGET_FIELDS = [
  "first_name", "last_name", "full_name", "title", "known_as", "email", "phone",
  "town", "postcode", "region", "country", "dob", "ni_number", "right_to_work_status",
  "discipline", "specialty", "registration_body", "registration_number", "availability",
  "employer", "job_title", "notes", "ignore",
] as const;

// Fields written straight onto a candidate row (the rest are kept as provenance).
const DIRECT_FIELDS = new Set([
  "first_name", "last_name", "title", "known_as", "email", "phone",
  "town", "postcode", "region", "country", "dob", "ni_number", "right_to_work_status",
  "registration_body", "registration_number", "availability",
]);

// Normalise a phone to digits (+ optional leading +) for dedup; null if too short.
function normPhone(p: unknown): string | null {
  const d = (p ?? "").toString().replace(/[^\d+]/g, "");
  return d.replace(/\D/g, "").length >= 7 ? d : null;
}

// Fields under a DB CHECK / type constraint — a non-conforming legacy value must
// go to provenance, not into the column (else it fails the whole insert batch).
const RTW_VALUES = new Set(["uk_citizen", "settled", "pre_settled", "visa", "unconfirmed", "no"]);
function conformsToColumn(field: string, v: string): boolean {
  if (field === "right_to_work_status") return RTW_VALUES.has(v);
  if (field === "dob") return /^\d{4}-\d{2}-\d{2}$/.test(v) && !Number.isNaN(Date.parse(v));
  return true;
}

// ---- MAP: ask Claude to map this file's headers to schema fields -----------
async function doMap(headers: string[], samples: Record<string, unknown>[]) {
  const resp = await anthropic.messages.create({
    model: MODEL,
    max_tokens: 2048,
    output_config: {
      effort: "low",
      format: {
        type: "json_schema",
        schema: {
          type: "object",
          properties: {
            mapping: {
              type: "array",
              items: {
                type: "object",
                properties: {
                  source_header: { type: "string" },
                  target_field: { type: "string", enum: [...TARGET_FIELDS] },
                },
                required: ["source_header", "target_field"],
                additionalProperties: false,
              },
            },
            notes: { type: "string" },
          },
          required: ["mapping", "notes"],
          additionalProperties: false,
        },
      },
    },
    system:
      "You map spreadsheet column headers to a candidate database schema. These are old, inconsistent recruitment spreadsheets. For each source header pick the best target_field. Use 'full_name' when one column holds the whole name and there is no separate first/last. Map nursing/role/grade/profession columns to 'discipline', sub-speciality to 'specialty', NMC/GMC/HCPC PIN columns to 'registration_number' and the body to 'registration_body'. Use 'ignore' for anything irrelevant (IDs, internal codes, blank columns). Return one mapping entry per source header.",
    messages: [{
      role: "user",
      content: `Headers:\n${JSON.stringify(headers)}\n\nSample rows:\n${JSON.stringify(samples.slice(0, 5), null, 2)}`,
    }],
  });
  const text = resp.content.filter((b) => b.type === "text").map((b: any) => b.text).join("");
  return JSON.parse(text);
}

// ---- COMMIT: deterministically transform rows + dedupe + insert ------------
async function getImportSourceId(): Promise<string | null> {
  const { data } = await sb.from("sources").select("id").eq("code", "import").maybeSingle();
  if (data) return data.id;
  const { data: created } = await sb.from("sources")
    .insert({ code: "import", name: "Spreadsheet import", channel_type: "import", default_consent_basis: "legitimate_interest" })
    .select("id").maybeSingle();
  return created?.id ?? null;
}

async function doCommit(mapping: { source_header: string; target_field: string }[], rows: Record<string, unknown>[]) {
  const sourceId = await getImportSourceId();
  const map = new Map(mapping.filter((m) => m.target_field !== "ignore").map((m) => [m.source_header, m.target_field]));

  const candidates: any[] = [];
  let skipped_no_contact = 0;                 // no email AND no usable phone
  const seenEmail = new Set<string>();
  const seenPhone = new Set<string>();

  for (const row of rows) {
    const c: any = { status: "sourced", source_id: sourceId, source_detail: { raw: row }, name_variants: [] };
    const extra: Record<string, unknown> = {};
    let fullName = "";

    for (const [header, value] of Object.entries(row)) {
      const v = (value ?? "").toString().trim();
      if (!v) continue;
      const field = map.get(header);
      if (!field || field === "ignore") continue;
      if (field === "full_name") { if (!fullName) fullName = v; else extra[header] = v; continue; }
      if (field === "notes") { c.notes = c.notes ? `${c.notes}\n${v}` : v; continue; }
      if (DIRECT_FIELDS.has(field)) {
        // A value that would violate the column's CHECK/type goes to provenance
        // (e.g. "British" in an RTW column, "N/A" in a DOB column) so it can't
        // fail the batch insert.
        if (!conformsToColumn(field, v)) { extra[header] = v; continue; }
        // First non-empty wins; a second header mapped to the same field is
        // kept as provenance rather than silently overwriting.
        if (c[field] == null || c[field] === "") c[field] = field === "email" ? v.toLowerCase() : v;
        else extra[header] = v;
      } else {
        // discipline/specialty/employer/job_title kept as provenance + notes;
        // the agent resolves them to taxonomy codes during qualification.
        extra[field] = v;
      }
    }

    if (fullName && !c.first_name && !c.last_name) {
      const parts = fullName.split(/\s+/);
      c.first_name = parts.shift() ?? null;
      c.last_name = parts.length ? parts.join(" ") : null;
      c.name_variants = [fullName];           // keep the raw name for reconciliation
    }
    if (Object.keys(extra).length) {
      const tag = Object.entries(extra).map(([k, val]) => `${k}: ${val}`).join("; ");
      c.notes = c.notes ? `${c.notes}\n${tag}` : tag;
      c.source_detail.parsed = extra;
    }

    // Accept a row with EITHER an email or a usable phone — legacy sheets are
    // routinely phone-only, and dropping them defeats the point of the importer.
    const phone = normPhone(c.phone);
    if (!c.email && !phone) { skipped_no_contact++; continue; }
    if (c.email) { if (seenEmail.has(c.email)) continue; seenEmail.add(c.email); }
    else if (phone) { if (seenPhone.has(phone)) continue; seenPhone.add(phone); }
    candidates.push(c);
  }

  // Split by contactability. Email rows upsert idempotently (re-running an
  // import won't duplicate them); phone-only rows are inserted.
  const withEmail = candidates.filter((c) => c.email);
  const phoneOnly = candidates.filter((c) => !c.email);

  let inserted = 0;
  const errors: string[] = [];

  // Email rows: upsert ignoring duplicates on the unique email index. One bad
  // batch is recorded and skipped — it never aborts the remaining batches.
  for (let i = 0; i < withEmail.length; i += 500) {
    const { data, error } = await sb.from("candidates")
      .upsert(withEmail.slice(i, i + 500), { onConflict: "email", ignoreDuplicates: true })
      .select("id");
    if (error) errors.push(error.message); else inserted += data?.length ?? 0;
  }
  const skipped_duplicates = withEmail.length - inserted;   // pre-existing emails

  let phone_only_inserted = 0;
  for (let i = 0; i < phoneOnly.length; i += 500) {
    const { data, error } = await sb.from("candidates").insert(phoneOnly.slice(i, i + 500)).select("id");
    if (error) errors.push(error.message); else phone_only_inserted += data?.length ?? 0;
  }

  return {
    inserted: inserted + phone_only_inserted,
    skipped_duplicates, skipped_no_contact, phone_only_inserted,
    ...(errors.length ? { errors } : {}),
  };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (!(await verifyStaff(req))) return unauthorized();
  try {
    const body = await req.json();
    if (body.mode === "map") {
      const result = await doMap(body.headers ?? [], body.samples ?? []);
      return new Response(JSON.stringify(result), { headers: CORS });
    }
    if (body.mode === "commit") {
      const result = await doCommit(body.mapping ?? [], body.rows ?? []);
      return new Response(JSON.stringify(result), { headers: CORS });
    }
    return new Response(JSON.stringify({ error: "mode must be 'map' or 'commit'" }), { status: 400, headers: CORS });
  } catch (e) {
    return new Response(JSON.stringify({ error: String(e) }), { status: 500, headers: CORS });
  }
});
