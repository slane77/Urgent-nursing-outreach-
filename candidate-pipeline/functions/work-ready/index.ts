// ============================================================================
//  Day Webster — Candidate Pipeline · work-ready (Supabase Edge Function)
//
//  STATUS: DRAFT — NOT YET DEPLOYED. For review only.
//
//  The compliance gate the EXTERNAL booking/placement system calls before it
//  puts a candidate forward for a shift. Given a candidate + a requirement set,
//  it returns the work-ready verdict derived by the database.
//
//    green  -> work_ready:true   (fully compliant)
//    amber  -> work_ready:true   (placeable with a caveat — a refresh is due)
//    red    -> work_ready:false  (blocked)
//
//  FAIL-CLOSED by construction: a missing status row, any downstream error, or
//  an unknown candidate/set all resolve to { work_ready:false, status:"red" } —
//  never a 500 the caller might treat as "unknown = proceed". Auth failure is a
//  401 (a distinct signal), and the endpoint is dead unless WORK_READY_TOKEN is
//  configured.
//
//  AUTH: shared bearer secret for the booking system (env WORK_READY_TOKEN).
//  verify_jwt=false at deploy. ISOLATION: reads ONLY the `candidate` schema via
//  fail-closed SECURITY DEFINER functions; no evidence is ever exposed here.
// ============================================================================

import { createClient } from "npm:@supabase/supabase-js";

const sb = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { db: { schema: "candidate" } },
);

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Content-Type": "application/json",
};

// The fail-closed answer, used for every non-authorised-but-reachable outcome.
const NOT_READY = { work_ready: false, status: "red", blocking_open: null, next_expiry: null };

function authorised(req: Request): boolean {
  const need = Deno.env.get("WORK_READY_TOKEN");
  if (!need) return false;                       // fail closed: unconfigured => dead
  const tok = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  const alt = (req.headers.get("x-work-ready-token") ?? "").trim();
  return tok === need || alt === need;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (!authorised(req)) {
    return new Response(JSON.stringify({ error: "unauthorized" }), { status: 401, headers: CORS });
  }

  try {
    const b = await req.json().catch(() => ({}));
    const candidateId = (b.candidate_id ?? "").toString().trim();
    let setId = (b.set_id ?? "").toString().trim() || null;
    const setCode = (b.set_code ?? "").toString().trim() || null;

    if (!candidateId || (!setId && !setCode)) {
      return new Response(JSON.stringify({ error: "candidate_id and set_id (or set_code) are required" }), { status: 400, headers: CORS });
    }

    // Resolve set_code -> the latest ACTIVE version's id.
    if (!setId && setCode) {
      const { data: set } = await sb.from("requirement_sets")
        .select("id").eq("code", setCode).eq("status", "active")
        .order("version", { ascending: false }).limit(1).maybeSingle();
      if (!set?.id) {
        // Unknown/inactive set => not work-ready (fail closed), not an error.
        return new Response(JSON.stringify({ candidate_id: candidateId, set_code: setCode, ...NOT_READY }), { headers: CORS });
      }
      setId = set.id;
    }

    // Derive the verdict from the fail-closed DB functions + the status row.
    const [{ data: ready }, { data: status }, { data: row }] = await Promise.all([
      sb.rpc("is_work_ready", { p_candidate_id: candidateId, p_set_id: setId }),
      sb.rpc("work_ready_status", { p_candidate_id: candidateId, p_set_id: setId }),
      sb.from("candidate_compliance_status")
        .select("blocking_open,next_expiry")
        .eq("candidate_id", candidateId).eq("set_id", setId).maybeSingle(),
    ]);

    return new Response(JSON.stringify({
      candidate_id: candidateId,
      set_id: setId,
      work_ready: ready === true,               // null/false both => not ready
      status: (status as string) ?? "red",
      blocking_open: row?.blocking_open ?? null,
      next_expiry: row?.next_expiry ?? null,
    }), { headers: CORS });
  } catch (_e) {
    // Never surface a 500 that could read as "unknown, proceed" — fail closed.
    return new Response(JSON.stringify(NOT_READY), { headers: CORS });
  }
});
