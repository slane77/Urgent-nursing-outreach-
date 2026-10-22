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
//  SHIFT-DATE MODE (decision E2/E3): pass `shift_date` (YYYY-MM-DD) and the gate
//  confirms the candidate is compliant FOR THAT DATE, not just today — a blocking
//  item must stay valid past shift_date + a configurable BUFFER (no bookings
//  within N days of an expiry). Optional `buffer_days` overrides the DB default.
//  `via_override` is true when readiness comes from a manager override (the
//  underlying traffic light is still red) — so an override is always VISIBLE,
//  never hidden. With no `shift_date` the behaviour is unchanged (today).
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
const NOT_READY = { work_ready: false, status: "red", blocking_open: null, next_expiry: null, via_override: false };

// Accept YYYY-MM-DD only; anything else is treated as "no shift date" (today mode).
function parseShiftDate(v: unknown): string | null {
  const s = (v ?? "").toString().trim();
  return /^\d{4}-\d{2}-\d{2}$/.test(s) ? s : null;
}

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
    const shiftDate = parseShiftDate(b.shift_date);
    const bufferDays = Number.isFinite(Number(b.buffer_days)) && b.buffer_days != null
      ? Math.max(0, Math.trunc(Number(b.buffer_days))) : null;

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
        return new Response(JSON.stringify({ candidate_id: candidateId, set_code: setCode, shift_date: shiftDate, ...NOT_READY }), { headers: CORS });
      }
      setId = set.id;
    }

    if (shiftDate) {
      // SHIFT-DATE MODE: evaluate compliance as-of the shift date (+buffer), and
      // reflect a manager override. The traffic light stays the TRUE colour so an
      // override is visible: work_ready=true while status may still be "red".
      //
      // We ALSO surface a COMPLIANCE-BREACH warning: booking a candidate who is
      // red — or ready ONLY via a manager override — for this date places a worker
      // with an elapsed/unsatisfied required doc. `blocking_reasons` names WHICH
      // docs (read-only; this endpoint logs nothing). The actual recording + alert
      // is a separate call to the booking-breach function when the booking proceeds.
      const [{ data: ready }, { data: status }, { data: overridden }, { data: items }] = await Promise.all([
        sb.rpc("is_work_ready_on", { p_candidate_id: candidateId, p_set_id: setId, p_as_of: shiftDate, p_buffer_days: bufferDays }),
        sb.rpc("work_ready_status_on", { p_candidate_id: candidateId, p_set_id: setId, p_as_of: shiftDate, p_buffer_days: bufferDays }),
        sb.rpc("has_active_override", { p_candidate_id: candidateId, p_set_id: setId, p_as_of: shiftDate }),
        sb.rpc("noncompliant_items_on", { p_candidate_id: candidateId, p_set_id: setId, p_as_of: shiftDate, p_buffer_days: bufferDays }),
      ]);
      const asOfStatus = (status as string) ?? "red";
      // A breach is STRICTLY a red light (a genuinely elapsed/unsatisfied blocking
      // doc). green/amber = compliant/placeable — a stray active override never
      // turns a compliant worker into a breach; it only explains why a RED worker
      // is bookable. So: compliant = green|amber; breach = red; via_override = the
      // booking is red yet permitted because a manager override is carrying it.
      const compliant = ["green", "amber"].includes(asOfStatus);
      const breachIfBooked = !compliant;                                  // === red
      const viaOverride = ready === true && overridden === true && breachIfBooked;

      // The elapsed/unsatisfied required docs (capped + serialised safely). Only
      // populated for a real breach — a compliant (green/amber) worker carries none.
      const blockingReasons = breachIfBooked
        ? (Array.isArray(items) ? items : []).slice(0, 50).map((r: any) => ({
            code: r?.code ?? null,
            name: r?.name ?? null,
            expires_at: r?.expires_at ?? null,
            status: r?.status ?? null,
          }))
        : [];

      let warning: string | null = null;
      if (breachIfBooked) {
        const names = blockingReasons.map((r) => r.name || r.code).filter(Boolean);
        const list = names.length ? names.join(", ") : "required documents";
        warning =
          `⚠ NOT COMPLIANT for ${shiftDate}: ${blockingReasons.length} required document(s) ` +
          `elapsed/unsatisfied (${list}). Booking will place a non-compliant worker and record a compliance breach.` +
          (viaOverride ? " (currently permitted only by a manager override)." : "");
      }

      return new Response(JSON.stringify({
        candidate_id: candidateId,
        set_id: setId,
        shift_date: shiftDate,
        work_ready: ready === true,
        status: asOfStatus,                      // the TRUE as-of colour (override not hidden)
        via_override: viaOverride,
        compliant,                               // genuinely compliant (not via override)
        breach_if_booked: breachIfBooked,        // booking this date creates a breach
        blocking_reasons: blockingReasons,       // WHICH docs are elapsed/unsatisfied
        warning,                                 // human string when breach_if_booked, else null
      }), { headers: CORS });
    }

    // Default (today) mode — unchanged: derive from the stored traffic light.
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
      via_override: false,
    }), { headers: CORS });
  } catch (_e) {
    // Never surface a 500 that could read as "unknown, proceed" — fail closed.
    return new Response(JSON.stringify(NOT_READY), { headers: CORS });
  }
});
