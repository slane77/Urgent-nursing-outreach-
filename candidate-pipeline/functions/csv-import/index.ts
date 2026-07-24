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
//        -> dedupes on email, inserts NEW rows as status='sourced' (source
//           'import'), returns { inserted, skipped_duplicates, skipped_no_email }
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
  "first_name", "last_name", "full_name", "title", "email", "phone",
  "town", "postcode", "region", "country", "discipline", "specialty",
  "registration_body", "registration_number", "availability",
  "employer", "job_title", "notes", "ignore",
] as const;

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
  let skipped_no_email = 0;
  const seenInFile = new Set<string>();

  for (const row of rows) {
    const c: any = { status: "sourced", source_id: sourceId, source_detail: { raw: row }, name_variants: [] };
    const extra: Record<string, unknown> = {};
    let fullName = "";

    for (const [header, value] of Object.entries(row)) {
      const v = (value ?? "").toString().trim();
      if (!v) continue;
      const field = map.get(header);
      if (!field) continue;
      switch (field) {
        case "full_name": fullName = v; break;
        case "first_name": c.first_name = v; break;
        case "last_name": c.last_name = v; break;
        case "title": c.title = v; break;
        case "email": c.email = v.toLowerCase(); break;
        case "phone": c.phone = v; break;
        case "town": c.town = v; break;
        case "postcode": c.postcode = v; break;
        case "region": c.region = v; break;
        case "country": c.country = v; break;
        case "registration_body": c.registration_body = v; break;
        case "registration_number": c.registration_number = v; break;
        case "availability": c.availability = v; break;
        // discipline/specialty/employer/job_title kept as provenance + notes;
        // the agent resolves them to taxonomy codes during qualification.
        case "discipline": extra.discipline = v; break;
        case "specialty": extra.specialty = v; break;
        case "employer": extra.employer = v; break;
        case "job_title": extra.job_title = v; break;
        case "notes": c.notes = c.notes ? `${c.notes}\n${v}` : v; break;
      }
    }

    if (fullName && !c.first_name && !c.last_name) {
      const parts = fullName.split(/\s+/);
      c.first_name = parts.shift() ?? null;
      c.last_name = parts.length ? parts.join(" ") : null;
    }
    if (Object.keys(extra).length) {
      const tag = Object.entries(extra).map(([k, val]) => `${k}: ${val}`).join("; ");
      c.notes = c.notes ? `${c.notes}\n${tag}` : tag;
      c.source_detail.parsed = extra;
    }

    if (!c.email) { skipped_no_email++; continue; }
    if (seenInFile.has(c.email)) continue;
    seenInFile.add(c.email);
    candidates.push(c);
  }

  // Dedupe against existing candidates (by email).
  const emails = candidates.map((c) => c.email);
  const existing = new Set<string>();
  for (let i = 0; i < emails.length; i += 500) {
    const { data } = await sb.from("candidates").select("email").in("email", emails.slice(i, i + 500));
    (data ?? []).forEach((r: any) => r.email && existing.add(r.email.toLowerCase()));
  }
  const fresh = candidates.filter((c) => !existing.has(c.email));
  const skipped_duplicates = candidates.length - fresh.length;

  let inserted = 0;
  for (let i = 0; i < fresh.length; i += 500) {
    const { data, error } = await sb.from("candidates").insert(fresh.slice(i, i + 500)).select("id");
    if (error) return { error: error.message, inserted, skipped_duplicates, skipped_no_email };
    inserted += data?.length ?? 0;
  }
  return { inserted, skipped_duplicates, skipped_no_email };
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
