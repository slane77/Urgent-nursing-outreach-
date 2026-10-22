// ============================================================================
//  Day Webster — Candidate Pipeline · compliance-import (Supabase Edge Function)
//
//  STATUS: DRAFT — NOT YET DEPLOYED. For review only.
//
//  The set-based bulk compliance migration (10-15k candidates / ~150k items).
//  Same "classify the genre once, apply deterministically" shape as csv-import:
//  one cheap Claude call maps a spreadsheet's HEADERS to composite compliance
//  targets; the mapping is then applied to every row with zero further AI.
//
//  Two modes (POST JSON):
//    { mode: "map",    headers: [...], samples: [ {h: v}, ... ] }
//        -> { mapping: [{source_header, target}], notes }
//           target ∈ { "email", "phone", "ignore", "req:<code>:<field>" }
//           field  ∈ { status, issue_date, expiry_date, number, evidence_note }
//    { mode: "commit", mapping: [...], rows: [ {h: v}, ... ] }
//        -> explodes each row into per-requirement item rows and POSTs
//           ~2,000-row batches to candidate.import_compliance_bulk(). Returns the
//           aggregated match/insert report.
//
//  Migrated items land status='verified' (D1) but stamped migrated. Dateless
//  items get a 90-day grace expiry (D2); items whose expiry cell was present but
//  unparseable are flagged expiry_unparsed so the RPC lands them due-now +
//  needs_human (D1/D3). The RPC does all writes under a bulk_load guard.
//
//  AUTH: staff-only. verify_jwt=true at deploy; we also check the email domain.
//  ISOLATION: writes ONLY to the `candidate` schema.
// ============================================================================

import Anthropic from "npm:@anthropic-ai/sdk";
import { createClient } from "npm:@supabase/supabase-js";

const MODEL = "claude-opus-4-8";
const anthropic = new Anthropic({ apiKey: Deno.env.get("ANTHROPIC_API_KEY")! });
const sb = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { db: { schema: "candidate" } },
);

const ALLOWED_DOMAINS = [
  "@daywebster.com", "@daywebstergroup.com",
  "@homecare-providers.com", "@homecareproviders.co.uk",
];

// Requirement codes from sql/13_compliance_requirements.sql (+ nursing
// care_certificate added in 27). The RPC re-scopes each code to the candidate's
// assigned set, so an over-broad guess here is harmless.
const KNOWN_CODES = [
  "cv", "right_to_work", "proof_of_address", "references_3yr", "overseas_police_check",
  "nmc_registration", "gmc_registration", "hcpc_registration", "qualification_cert",
  "indemnity", "dbs_enhanced", "dbs_enhanced_adults", "dbs_enhanced_children",
  "occupational_health", "immunisations", "mandatory_training", "care_certificate",
  "cii_qualification", "financial_reference", "level5_diploma", "fit_person_declaration",
] as const;

const ITEM_FIELDS = ["status", "issue_date", "expiry_date", "number", "evidence_note"] as const;
const IDENTITY_TARGETS = ["email", "phone", "ignore"] as const;

const CODES = new Set<string>(KNOWN_CODES);
const FIELDS = new Set<string>(ITEM_FIELDS);

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Content-Type": "application/json",
};

function emailFromJwt(req: Request): string | null {
  const auth = req.headers.get("Authorization") ?? "";
  const token = auth.replace(/^Bearer\s+/i, "");
  const part = token.split(".")[1];
  if (!part) return null;
  try {
    const json = JSON.parse(atob(part.replace(/-/g, "+").replace(/_/g, "/")));
    return (json.email ?? "").toLowerCase() || null;
  } catch {
    return null;
  }
}

function authorized(req: Request): boolean {
  const email = emailFromJwt(req);
  return !!email && ALLOWED_DOMAINS.some((d) => email.endsWith(d));
}

// A composite target is valid if it's an identity/ignore keyword or req:code:field.
function validTarget(t: string): boolean {
  if ((IDENTITY_TARGETS as readonly string[]).includes(t)) return true;
  const m = /^req:([a-z0-9_]+):([a-z_]+)$/.exec(t);
  return !!m && CODES.has(m[1]) && FIELDS.has(m[2]);
}

// Build an ISO date string ONLY if (y, mo, d) is a real calendar date. We
// round-trip through a UTC Date so impossible dates (31/31/2020, 2020-02-30,
// 2020-31-31) roll over and are rejected as null — never a bad string that
// would abort the whole RPC batch on the `date` cast (D1/D3).
function validISO(y: number, mo: number, d: number): string | null {
  if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
  const dt = new Date(Date.UTC(y, mo - 1, d));
  if (dt.getUTCFullYear() !== y || dt.getUTCMonth() !== mo - 1 || dt.getUTCDate() !== d) {
    return null;
  }
  return `${String(y).padStart(4, "0")}-${String(mo).padStart(2, "0")}-${String(d).padStart(2, "0")}`;
}

// Best-effort date normalisation to ISO (YYYY-MM-DD); the RPC casts to `date`.
// Handles YYYY-MM-DD, DD/MM/YYYY (UK), and bare Excel serial dates (integer days
// since the 1899-12-30 epoch). Returns null for anything unparseable/invalid.
function toISODate(v: string): string | null {
  const s = v.trim();
  if (!s) return null;

  // Excel serial date: a bare integer (days since 1899-12-30). Bound the range to
  // real calendar dates so a stray year/PIN can't masquerade as a serial forever.
  if (/^\d+$/.test(s)) {
    const serial = parseInt(s, 10);
    if (serial < 1 || serial > 2958465) return null; // 1900-01-01 .. 9999-12-31
    const dt = new Date(Date.UTC(1899, 11, 30) + serial * 86400000);
    return validISO(dt.getUTCFullYear(), dt.getUTCMonth() + 1, dt.getUTCDate());
  }

  let m = /^(\d{4})[-/](\d{1,2})[-/](\d{1,2})$/.exec(s); // YYYY-MM-DD
  if (m) return validISO(+m[1], +m[2], +m[3]);
  m = /^(\d{1,2})[-/](\d{1,2})[-/](\d{4})$/.exec(s); // DD/MM/YYYY (UK)
  if (m) return validISO(+m[3], +m[2], +m[1]);
  return null; // unrecognised
}

// ---- MAP: ask Claude to map this file's headers to compliance targets -------
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
                  target: { type: "string" },
                },
                required: ["source_header", "target"],
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
      "You map columns of an old compliance/vetting spreadsheet to targets in a candidate compliance database. " +
      "For each source header return exactly one target string:\n" +
      "  'email' or 'phone' for the candidate's identity columns (used to match the person);\n" +
      "  'req:<code>:<field>' for a compliance column, where <code> is one of: " +
      KNOWN_CODES.join(", ") + "; and <field> is one of: " + ITEM_FIELDS.join(", ") + ";\n" +
      "  'ignore' for anything else (names, internal ids, blank columns).\n" +
      "Guidance: DBS/CRB columns -> dbs_enhanced (adults barred -> dbs_enhanced_adults, children -> dbs_enhanced_children); " +
      "NMC/GMC/HCPC PIN or registration -> the matching *_registration code (number field); " +
      "'expiry'/'renewal' dates -> expiry_date, 'issued'/'completed' dates -> issue_date, cert/PIN numbers -> number, " +
      "a done/complete/verified flag -> status. Return one entry per source header.",
    messages: [{
      role: "user",
      content: `Headers:\n${JSON.stringify(headers)}\n\nSample rows:\n${JSON.stringify(samples.slice(0, 5), null, 2)}`,
    }],
  });
  const text = resp.content.filter((b) => b.type === "text").map((b: any) => b.text).join("");
  return JSON.parse(text);
}

// ---- COMMIT: explode rows into per-requirement item rows + POST batches -----
async function doCommit(
  mapping: { source_header: string; target: string }[],
  rows: Record<string, unknown>[],
) {
  const map = new Map(
    mapping.filter((m) => m.target && m.target !== "ignore" && validTarget(m.target))
      .map((m) => [m.source_header, m.target]),
  );

  const items: Record<string, unknown>[] = [];
  let skipped_no_identity = 0;

  for (const row of rows) {
    let email: string | null = null;
    let phone: string | null = null;
    // per-requirement bucket of collected fields
    const byCode = new Map<string, Record<string, string>>();

    for (const [header, value] of Object.entries(row)) {
      const target = map.get(header);
      if (!target) continue;
      const v = (value ?? "").toString().trim();
      if (!v) continue;
      if (target === "email") { email = v.toLowerCase(); continue; }
      if (target === "phone") { phone = v; continue; }
      const [, code, field] = target.split(":"); // req:<code>:<field>
      const bucket = byCode.get(code) ?? {};
      bucket[field] = v;
      byCode.set(code, bucket);
    }

    if (!email && !phone) { skipped_no_identity++; continue; }
    if (byCode.size === 0) continue; // identity-only row, nothing to import

    for (const [code, fields] of byCode) {
      // Distinguish "expiry cell present but unparseable" from "no expiry cell"
      // (D1/D3): fields.expiry_date is only set when the source value was
      // non-empty, so a non-null parse failure means genuinely bad data.
      let expiry_date: string | null = null;
      let expiry_unparsed = false;
      if (fields.expiry_date) {
        expiry_date = toISODate(fields.expiry_date);
        if (expiry_date === null) expiry_unparsed = true;
      }
      items.push({
        email,
        phone,
        code,
        status: fields.status ?? null,
        issue_date: fields.issue_date ? toISODate(fields.issue_date) : null,
        expiry_date,
        expiry_unparsed,
        number: fields.number ?? null,
        evidence_note: fields.evidence_note ?? null,
      });
    }
  }

  // POST ~2,000-item batches to the single set-based RPC.
  const BATCH = 2000;
  const totals = {
    rows: 0, matched_rows: 0, unmatched_rows: 0, candidates: 0, items_inserted: 0,
    expiry_unparsed: 0, skipped_out_of_scope: 0,
  };
  const unmatched_sample: unknown[] = [];
  const out_of_scope_sample: unknown[] = [];
  for (let i = 0; i < items.length; i += BATCH) {
    const batch = items.slice(i, i + BATCH);
    const { data, error } = await sb.rpc("import_compliance_bulk", { p_rows: batch });
    if (error) {
      return { error: error.message, ...totals, skipped_no_identity, partial: true };
    }
    const r = data as any;
    totals.rows += r?.rows ?? 0;
    totals.matched_rows += r?.matched_rows ?? 0;
    totals.unmatched_rows += r?.unmatched_rows ?? 0;
    totals.candidates += r?.candidates ?? 0;
    totals.items_inserted += r?.items_inserted ?? 0;
    totals.expiry_unparsed += r?.expiry_unparsed ?? 0;
    totals.skipped_out_of_scope += r?.skipped_out_of_scope ?? 0;
    if (Array.isArray(r?.unmatched_sample) && unmatched_sample.length < 50) {
      unmatched_sample.push(...r.unmatched_sample.slice(0, 50 - unmatched_sample.length));
    }
    if (Array.isArray(r?.out_of_scope_sample) && out_of_scope_sample.length < 50) {
      out_of_scope_sample.push(...r.out_of_scope_sample.slice(0, 50 - out_of_scope_sample.length));
    }
  }

  return { ...totals, skipped_no_identity, unmatched_sample, out_of_scope_sample };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (!authorized(req)) return new Response(JSON.stringify({ error: "unauthorized" }), { status: 401, headers: CORS });
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
