// ============================================================================
//  Day Webster — Candidate Pipeline · booking-breach (Supabase Edge Function)
//
//  STATUS: DRAFT — NOT YET DEPLOYED. For review only.
//
//  The endpoint the booking/placement system (or a compliance officer) calls
//  when a booking PROCEEDS against a worker who is NOT compliant for the shift
//  date — either red, or ready ONLY via a manager override (see work-ready's
//  `breach_if_booked`). It does two things atomically-ish:
//
//    1. RECORD  — candidate.record_booking_breach() logs an immutable breach row
//       with a snapshot of the elapsed documents (idempotent on the booking).
//       If the candidate is actually compliant the RPC RAISES 'no breach' and we
//       return a clean 409 (nothing is logged — never a spurious breach).
//    2. ALERT   — one breach-alert email to the DEDUPED recipient list: the
//       candidate's compliance officer, that officer's overseeing manager
//       (staff.overseen_by), and the central compliance mailbox
//       (compliance_settings.compliance_alert_email, env COMPLIANCE_ALERT_EMAIL
//       fallback). The breach is recorded regardless of email success.
//
//  AUTH: the SAME shared bearer as work-ready (env WORK_READY_TOKEN), via
//  Authorization: Bearer or x-work-ready-token. FAIL-CLOSED: 401 if the token is
//  unset or mismatched. verify_jwt=false at deploy. DB access is service-role and
//  reads/writes ONLY the `candidate` schema. No secrets are returned to callers.
// ============================================================================

import { createClient } from "npm:@supabase/supabase-js";
import { sendBrevoEmail, emailHtml } from "../_shared/email.ts";

const sb = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { db: { schema: "candidate" } },
);

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-work-ready-token",
  "Content-Type": "application/json",
};

function authorised(req: Request): boolean {
  const need = Deno.env.get("WORK_READY_TOKEN");
  if (!need) return false;                       // fail closed: unconfigured => dead
  const tok = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  const alt = (req.headers.get("x-work-ready-token") ?? "").trim();
  return tok === need || alt === need;
}

// Accept YYYY-MM-DD only.
function parseShiftDate(v: unknown): string | null {
  const s = (v ?? "").toString().trim();
  return /^\d{4}-\d{2}-\d{2}$/.test(s) ? s : null;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: CORS });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (!authorised(req)) return json({ error: "unauthorized" }, 401);

  try {
    const b = await req.json().catch(() => ({}));
    const candidateId = (b.candidate_id ?? "").toString().trim();
    let setId = (b.set_id ?? "").toString().trim() || null;
    const setCode = (b.set_code ?? "").toString().trim() || null;
    const shiftDate = parseShiftDate(b.shift_date);
    const bookingRef = (b.booking_ref ?? "").toString().trim() || null;
    const reason = (b.reason ?? "").toString().trim() || null;
    const bookedByEmail = (b.booked_by_email ?? "").toString().trim() || null;
    const bufferDays = Number.isFinite(Number(b.buffer_days)) && b.buffer_days != null
      ? Math.max(0, Math.trunc(Number(b.buffer_days))) : null;

    if (!candidateId || (!setId && !setCode) || !shiftDate) {
      return json({ error: "candidate_id, set_id (or set_code) and shift_date (YYYY-MM-DD) are required" }, 400);
    }

    // Resolve set_code -> the latest ACTIVE version's id (mirrors work-ready).
    if (!setId && setCode) {
      const { data: set } = await sb.from("requirement_sets")
        .select("id").eq("code", setCode).eq("status", "active")
        .order("version", { ascending: false }).limit(1).maybeSingle();
      if (!set?.id) return json({ error: `unknown or inactive set_code: ${setCode}` }, 400);
      setId = set.id;
    }

    // ── 1. RECORD the breach (idempotent). 'no breach' => the candidate was
    //    actually compliant: a clean 409, nothing logged. ────────────────────
    const { data: breachId, error: rpcErr } = await sb.rpc("record_booking_breach", {
      p_candidate_id: candidateId,
      p_set_id: setId,
      p_shift_date: shiftDate,
      p_booking_ref: bookingRef,
      p_reason: reason,
      p_booked_by_email: bookedByEmail,
      p_buffer_days: bufferDays,
    });
    if (rpcErr) {
      const msg = rpcErr.message ?? "error";
      if (/no breach/i.test(msg)) return json({ error: msg, breach: false }, 409);
      return json({ error: msg }, 400);
    }

    // ── Load the breach + candidate + routing for the alert (service role). ──
    const { data: breach } = await sb.from("compliance_breaches")
      .select("id,candidate_id,set_id,shift_date,booking_ref,via_override,expired_items,booked_by_email")
      .eq("id", breachId).maybeSingle();
    const { data: cand } = await sb.from("candidates")
      .select("first_name,last_name,email,compliance_officer")
      .eq("id", candidateId).maybeSingle();

    const candidateName = `${cand?.first_name ?? ""} ${cand?.last_name ?? ""}`.trim() || "candidate";

    // Officer email + that officer's overseeing manager's email.
    let officerEmail: string | null = null;
    let managerEmail: string | null = null;
    if (cand?.compliance_officer) {
      const { data: off } = await sb.from("app_users")
        .select("email").eq("user_id", cand.compliance_officer).maybeSingle();
      officerEmail = off?.email ?? null;
      const { data: st } = await sb.from("staff")
        .select("overseen_by").eq("user_id", cand.compliance_officer).maybeSingle();
      if (st?.overseen_by) {
        const { data: mgr } = await sb.from("app_users")
          .select("email").eq("user_id", st.overseen_by).maybeSingle();
        managerEmail = mgr?.email ?? null;
      }
    }

    // Central mailbox: DB setting, else env fallback.
    const { data: settings } = await sb.from("compliance_settings")
      .select("compliance_alert_email").eq("id", true).maybeSingle();
    const centralEmail = settings?.compliance_alert_email
      || Deno.env.get("COMPLIANCE_ALERT_EMAIL") || null;

    // Deduped recipient list (skip nulls, case-insensitive de-dup).
    const seen = new Set<string>();
    const recipients: string[] = [];
    for (const e of [officerEmail, managerEmail, centralEmail]) {
      const v = (e ?? "").trim();
      if (v && !seen.has(v.toLowerCase())) { seen.add(v.toLowerCase()); recipients.push(v); }
    }

    // ── 2. ALERT: one breach-alert email to every recipient. ────────────────
    const items = Array.isArray(breach?.expired_items) ? breach!.expired_items as any[] : [];
    const docLines = items.map((it) => {
      const exp = it?.expires_at ? ` (expired/uncovered ${String(it.expires_at).slice(0, 10)})` : "";
      return `  · ${it?.name || it?.code || "document"}${exp}`;
    }).join("\n") || "  · (see the compliance cockpit for details)";

    const subject = `COMPLIANCE BREACH: ${candidateName} booked non-compliant for ${shiftDate}`;
    const body =
      `A booking has been made against a NON-COMPLIANT worker.\n\n` +
      `Candidate: ${candidateName}\n` +
      `Shift date: ${shiftDate}\n` +
      `Booking ref: ${bookingRef ?? "(none)"}\n` +
      `Booked by: ${bookedByEmail ?? breach?.booked_by_email ?? "(unknown)"}\n` +
      (breach?.via_override ? `Currently permitted ONLY by a manager override.\n` : "") +
      `\nElapsed / unsatisfied required document(s):\n${docLines}\n\n` +
      `This worker has been booked while NON-COMPLIANT — please review.`;

    let sent = 0;
    let firstRef: string | null = null;
    for (const to of recipients) {
      const r = await sendBrevoEmail({ to, subject, html: emailHtml(body) });
      if (r.ok) { sent++; if (!firstRef) firstRef = r.id ?? null; }
    }
    const alerted = recipients.length > 0 && sent === recipients.length;

    // ── Log ONE outbound comms row (recipients captured in the body). ───────
    await sb.from("messages").insert({
      candidate_id: candidateId,
      direction: "outbound",
      channel: "email",
      author: "system",
      template: "breach_alert",
      subject,
      body: `Breach alert for shift ${shiftDate} sent to: ${recipients.join(", ") || "(no recipients configured)"}. ` +
            `${items.length} elapsed document(s).`,
      status: alerted ? "sent" : "failed",
      external_ref: firstRef,
    });

    return json({ breach_id: breachId, alerted, recipients_count: recipients.length });
  } catch (e) {
    return json({ error: (e as Error)?.message ?? "error" }, 500);
  }
});
