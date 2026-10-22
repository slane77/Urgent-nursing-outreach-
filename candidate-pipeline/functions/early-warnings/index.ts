// ============================================================================
//  Day Webster — Candidate Pipeline · early-warnings (Supabase Edge Function)
//
//  STATUS: DRAFT — NOT YET DEPLOYED. For review only.
//
//  The assessment's highest-ROI loop (§6) + the CANDIDATE_EXPERIENCE §2a
//  pre-expiry ladder, automated end to end. Run on a schedule (Supabase Cron,
//  e.g. daily). Two steps per run:
//
//    1. EXPIRED sweep — any item already past expiry is marked 'expired' and
//       flagged for a human (a lapsed doc = a candidate who can't work).
//    2. PRE-EXPIRY LADDER — for every current, verified, blocking/standard item
//       with a FUTURE expiry, send the nearest-due rung (T-90/60/30/14/7/1) once
//       per item per expiry. Each email names the item + EXACT expiry date, gives
//       renewal advice, deep-links to the portal, and states the booking cut-off
//       (expiry minus the configured buffer). Renewal resets the ladder for free
//       (the ledger key includes expires_at) — a renewed item is never chased.
//
//  The ladder REPLACES the old ad-hoc weekly chase; the EXPIRED behaviour is
//  unchanged. Sends are structured so the future multi-channel comms engine can
//  take over (channel column already present; email now).
//
//  FAIL-CLOSED gate: the endpoint is DEAD unless CRON_SECRET is set AND matches
//  (like work-ready). ISOLATION: `candidate` schema only.
// ============================================================================

import { createClient } from "npm:@supabase/supabase-js";
import { sendBrevoEmail, emailHtml } from "../_shared/email.ts";

const sb = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { db: { schema: "candidate" } },
);

const DAY = 864e5;
const iso10 = (t: number) => new Date(t).toISOString().slice(0, 10);

Deno.serve(async (req) => {
  // FAIL-CLOSED: no secret configured, or a mismatch, => forbidden. Never runs open.
  const need = Deno.env.get("CRON_SECRET");
  if (!need || new URL(req.url).searchParams.get("secret") !== need) {
    return new Response("forbidden", { status: 403 });
  }

  const now = Date.now();
  const portal = Deno.env.get("PUBLIC_SITE_URL") ?? "https://portal.daywebster.com"; // portal link TBD

  // ── Step 1: EXPIRED sweep (unchanged behaviour) ───────────────────────────
  let expired = 0;
  {
    const { data: items, error } = await sb
      .from("compliance_items")
      .select("id,expires_at,status,compliance_requirements(name)")
      .not("expires_at", "is", null)
      .neq("status", "expired")
      .lt("expires_at", new Date(now).toISOString());
    if (error) return new Response(JSON.stringify({ error: error.message }), { status: 500, headers: { "Content-Type": "application/json" } });

    for (const it of items ?? []) {
      const reqName = (it as any).compliance_requirements?.name ?? "a document";
      const when = (it.expires_at ?? "").slice(0, 10);
      await sb.from("compliance_items").update({
        status: "expired", needs_human: true,
        human_notes: `${reqName} expired on ${when} — candidate not work-ready until renewed.`,
      }).eq("id", it.id);
      expired++;
    }
  }

  // ── Step 2: PRE-EXPIRY LADDER (the new work) ──────────────────────────────
  let reminded = 0;
  {
    const { data: due, error } = await sb.rpc("due_expiry_reminders", {
      p_now: new Date(now).toISOString(),
      p_limit: 1000,
    });
    if (error) return new Response(JSON.stringify({ error: error.message, expired }), { status: 500, headers: { "Content-Type": "application/json" } });

    for (const d of (due ?? []) as any[]) {
      if (!d.email) continue;

      const label = d.candidate_label || d.requirement_name || "a document";
      const expiryStr = (d.expires_at ?? "").slice(0, 10);
      const expiryMs = new Date(d.expires_at).getTime();
      const cutoffStr = iso10(expiryMs - (d.buffer_days ?? 0) * DAY); // booking cut-off = expiry − buffer
      const advice = d.candidate_help
        || `Please renew ${label} and upload the new document as soon as you can.`;
      const template = `pre_expiry_Tminus${d.offset_days}`;

      const body =
        `Hi ${d.first_name || "there"},\n\n` +
        `This is a reminder from Day Webster: ${label} expires on ${expiryStr}.\n\n` +
        `${advice}\n\n` +
        `Upload your renewed document here: ${portal}\n\n` +
        `You must renew ${label} by ${expiryStr} or you will not be able to be booked for shifts from ${cutoffStr}.`;

      const r = await sendBrevoEmail({
        to: d.email, toName: d.first_name,
        subject: `Action needed: ${label} expires on ${expiryStr}`,
        html: emailHtml(body),
      });
      if (!r.ok) continue;

      // Log the comms + record the once-only ledger row (resets on renewal).
      const { data: msg } = await sb.from("messages").insert({
        candidate_id: d.candidate_id, direction: "outbound", channel: "email", author: "system",
        template, subject: `Renewal reminder (T-${d.offset_days}): ${label}`,
        body: `Reminder sent — ${label} expires ${expiryStr}; booking cut-off ${cutoffStr}.`,
        status: "sent", external_ref: r.id ?? null,
      }).select("id").maybeSingle();

      const { error: ledgerErr } = await sb.from("expiry_reminders_sent").insert({
        item_id: d.item_id, candidate_id: d.candidate_id, expires_at: d.expires_at,
        offset_days: d.offset_days, channel: "email", message_id: msg?.id ?? null,
      });
      // Unique(item,expiry,offset) makes a concurrent duplicate a harmless no-op.
      if (!ledgerErr) reminded++;
    }
  }

  // ── Step 3: OPEN-BREACH backstop digest (daily safety net) ────────────────
  // The real-time booking-breach function already alerts per breach; this is a
  // LIGHT daily catch-all so nothing sits unnoticed. ONE digest to the central
  // compliance mailbox summarising open breaches + DISTINCT candidates currently
  // working non-compliant (shift_date >= today). Skips silently if no mailbox is
  // configured or there are zero open breaches. Never re-alerts per breach.
  let open_breaches = 0;
  {
    const today = iso10(now);
    const { data: openRows } = await sb
      .from("compliance_breaches")
      .select("candidate_id,shift_date,status")
      .neq("status", "resolved");
    const rows = (openRows ?? []) as any[];
    open_breaches = rows.length;

    if (open_breaches > 0) {
      const { data: settings } = await sb
        .from("compliance_settings").select("compliance_alert_email").eq("id", true).maybeSingle();
      const mailbox = settings?.compliance_alert_email || Deno.env.get("COMPLIANCE_ALERT_EMAIL") || null;

      if (mailbox) {
        const workingNow = new Set(
          rows.filter((r) => (r.shift_date ?? "") >= today).map((r) => r.candidate_id),
        ).size;
        const subject = `Compliance breach digest: ${open_breaches} open · ${workingNow} working non-compliant`;
        const body =
          `Daily compliance-breach backstop (${today}).\n\n` +
          `Open breaches (not yet resolved): ${open_breaches}\n` +
          `Candidates currently/future working while non-compliant (shift on/after today): ${workingNow}\n\n` +
          `Review and clear these in the compliance cockpit → Breaches.`;
        const r = await sendBrevoEmail({ to: mailbox, subject, html: emailHtml(body) });
        if (r.ok) {
          await sb.from("messages").insert({
            candidate_id: null, direction: "outbound", channel: "email", author: "system",
            template: "breach_digest", subject,
            body: `Digest to ${mailbox}: ${open_breaches} open breach(es), ${workingNow} working non-compliant.`,
            status: "sent", external_ref: r.id ?? null,
          });
        }
      }
    }
  }

  return new Response(JSON.stringify({ expired, reminded, open_breaches }), { headers: { "Content-Type": "application/json" } });
});
