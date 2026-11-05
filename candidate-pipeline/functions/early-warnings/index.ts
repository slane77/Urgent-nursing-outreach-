// ============================================================================
//  Day Webster — Candidate Pipeline · early-warnings (Supabase Edge Function)
//
//  STATUS: DRAFT — NOT YET DEPLOYED. For review only.
//
//  The assessment's highest-ROI loop (§6), automated end to end. Run on a
//  schedule (Supabase Cron, e.g. daily). For every compliance item expiring
//  within 60 days it auto-chases the candidate (at most once a week); for
//  anything already expired it marks the item 'expired' and flags it for a
//  human (a lapsed doc = a candidate who can't work).
//
//  Protect with ?secret=<CRON_SECRET> if set. ISOLATION: `candidate` schema only.
// ============================================================================

import { createClient } from "npm:@supabase/supabase-js";
import { sendBrevoEmail, emailHtml } from "../_shared/email.ts";

const sb = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { db: { schema: "candidate" } },
);

Deno.serve(async (req) => {
  // Fail CLOSED: this endpoint is public (verify_jwt=false). If the secret is
  // not configured, reject — a missing env var must not leave it wide open.
  const need = Deno.env.get("CRON_SECRET");
  if (!need || new URL(req.url).searchParams.get("secret") !== need) return new Response("forbidden", { status: 403 });

  const now = Date.now();
  const cutoff = new Date(now + 60 * 864e5).toISOString();
  const chaseGate = now - 7 * 864e5; // re-chase at most weekly

  const { data: items, error } = await sb
    .from("compliance_items")
    .select("id,candidate_id,expires_at,chased_at,status,candidates(first_name,email),compliance_requirements(name)")
    .not("expires_at", "is", null)
    .neq("status", "expired")
    .lt("expires_at", cutoff);

  if (error) return new Response(JSON.stringify({ error: error.message }), { status: 500, headers: { "Content-Type": "application/json" } });

  let chased = 0, expired = 0;
  for (const it of items ?? []) {
    const reqName = (it as any).compliance_requirements?.name ?? "a document";
    const cand = (it as any).candidates ?? {};
    const when = (it.expires_at ?? "").slice(0, 10);
    const isExpired = new Date(it.expires_at!).getTime() < now;

    if (isExpired) {
      await sb.from("compliance_items").update({
        status: "expired", needs_human: true,
        human_notes: `${reqName} expired on ${when} — candidate not work-ready until renewed.`,
      }).eq("id", it.id);
      expired++;
      continue;
    }

    const due = !it.chased_at || new Date(it.chased_at).getTime() < chaseGate;
    if (due && cand.email) {
      const r = await sendBrevoEmail({
        to: cand.email, toName: cand.first_name,
        subject: `Action needed: your ${reqName} expires soon`,
        html: emailHtml(`Hi ${cand.first_name || "there"},\n\nA quick reminder from Day Webster: your ${reqName} is due to expire on ${when}. To stay available for work, please send us an up-to-date version as soon as you can.\n\nThank you!`),
      });
      if (r.ok) {
        await sb.from("compliance_items").update({ chased_at: new Date().toISOString() }).eq("id", it.id);
        await sb.from("messages").insert({
          candidate_id: it.candidate_id, direction: "outbound", channel: "email", author: "system",
          subject: `Expiry reminder: ${reqName}`, body: `Reminder sent — ${reqName} expires ${when}.`,
          status: "sent", external_ref: r.id ?? null,
        });
        chased++;
      }
    }
  }

  return new Response(JSON.stringify({ checked: items?.length ?? 0, chased, expired }), { headers: { "Content-Type": "application/json" } });
});
