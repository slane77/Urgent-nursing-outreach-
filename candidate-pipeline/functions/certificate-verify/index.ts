// ============================================================================
//  Day Webster — Candidate Pipeline · certificate-verify (Supabase Edge Function)
//
//  STATUS: DRAFT — NOT YET DEPLOYED. For review only. Deploying requires:
//    1. Migrations applied through candidate-pipeline/sql/52.
//    2. Deploy with **verify_jwt=false** — this is a PUBLIC certificate checker.
//
//  PUBLIC CERTIFICATE VERIFICATION (design §5, [DECISION C2]). Anyone (a client,
//  an auditor) can confirm a Day Webster training certificate by its ID. The
//  function runs as the SERVICE ROLE but its ONLY data path is the SECURITY
//  DEFINER RPC verify_certificate(p_certificate_id), which returns a deliberately
//  MINIMAL whitelist — { valid, module_title, framework_subject,
//  sfh_accreditation_ref, completion_date, expiry_date, status, candidate_initials }
//  — never the full name, DOB or score. We pass that JSON straight through; this
//  function adds no other query and no other field.
//
//  Rate-limited + generic errors + no enumeration: an unknown id returns the same
//  { valid:false } the RPC yields, so the endpoint never reveals which ids exist.
// ============================================================================

import { createClient } from "npm:@supabase/supabase-js";

// Service role, but the ONLY table/RPC touched is verify_certificate (minimal
// whitelist). The public is never granted direct DB access (no anon schema grant).
const sb = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { db: { schema: "candidate" }, auth: { persistSession: false } },
);

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "content-type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Content-Type": "application/json",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: CORS });
}

// ── Best-effort per-isolate rate limit (blunts brute-force id enumeration) ──
const WINDOW_MS = 60_000;
const MAX_HITS = 30;
const hits = new Map<string, number[]>();
function rateLimited(ip: string): boolean {
  const now = Date.now();
  const arr = (hits.get(ip) ?? []).filter((t) => now - t < WINDOW_MS);
  arr.push(now);
  hits.set(ip, arr);
  if (hits.size > 5000) {
    for (const [k, v] of hits) { if (v.every((t) => now - t >= WINDOW_MS)) hits.delete(k); }
  }
  return arr.length > MAX_HITS;
}
function clientIp(req: Request): string {
  return (req.headers.get("x-forwarded-for") ?? "").split(",")[0].trim() ||
    req.headers.get("cf-connecting-ip") || "unknown";
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (rateLimited(clientIp(req))) return json({ error: "rate_limited" }, 429);

  // Accept the id from ?certificate_id= (GET) or a JSON body (POST).
  let certificateId: string | null = null;
  try {
    if (req.method === "GET") {
      certificateId = new URL(req.url).searchParams.get("certificate_id");
    } else if (req.method === "POST") {
      const body = await req.json().catch(() => ({}));
      certificateId = typeof body?.certificate_id === "string" ? body.certificate_id : null;
    } else {
      return json({ error: "method_not_allowed" }, 405);
    }
  } catch {
    return json({ error: "bad_request" }, 400);
  }

  if (!certificateId || typeof certificateId !== "string" || certificateId.length > 64) {
    return json({ error: "bad_request" }, 400);
  }

  try {
    const { data, error } = await sb.rpc("verify_certificate", { p_certificate_id: certificateId });
    if (error) return json({ error: "unavailable" }, 500); // generic
    // Pass the RPC's minimal whitelist through UNCHANGED (unknown id => {valid:false}).
    return json(data ?? { valid: false });
  } catch {
    return json({ error: "unavailable" }, 500);
  }
});
