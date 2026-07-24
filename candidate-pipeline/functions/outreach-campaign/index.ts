// ============================================================================
//  Day Webster — Candidate Pipeline · outreach-campaign (Supabase Edge Function)
//
//  STATUS: NOT YET DEPLOYED. For review only.
//
//  Two credential-free, high-leverage sourcing motions over the EXISTING bench:
//    kind="referral"     -> ask engaged/placed candidates to refer a friend
//                           (link carries campaign attribution + bounty line)
//    kind="reengagement" -> re-contact dormant/early-stage candidates
//  Only candidates with a granted consent record and an email are contacted
//  (PECR). Batches are capped; re-engaged candidates move to 'contacted' so they
//  aren't hit repeatedly.
//
//  AUTH: staff-only. ISOLATION: `candidate` schema + the shared Brevo sender.
// ============================================================================

import { createClient } from "npm:@supabase/supabase-js";
import { sendBrevoEmail, emailHtml } from "../_shared/email.ts";
import { unsubscribeUrl } from "../_shared/unsubscribe.ts";
import { verifyStaff, unauthorized, CORS } from "../_shared/auth.ts";

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { db: { schema: "candidate" } });
const SITE = (Deno.env.get("PUBLIC_SITE_URL") ?? "").replace(/\/$/, "");

// Which consent purpose each motion needs. "Refer a friend, earn £250" is
// marketing; re-engaging a dormant candidate about work is recruitment.
const PURPOSE: Record<string, string> = { referral: "marketing", reengagement: "recruitment" };

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (!(await verifyStaff(req))) return unauthorized();
  try {
    const { kind, discipline_id = null, limit = 200, bounty = "£250", campaign_name } = await req.json();
    if (!["referral","reengagement"].includes(kind)) return new Response(JSON.stringify({ error: "kind must be 'referral' or 'reengagement'" }), { status: 400, headers: CORS });
    const cap = Math.min(Number(limit) || 200, 500);

    // Create the campaign (for attribution + cost/outcome tracking).
    const { data: camp } = await sb.from("sourcing_campaigns").insert({
      name: campaign_name ?? `${kind} ${new Date().toISOString().slice(0,10)}`,
      kind, channel: kind === "referral" ? "referral" : "reengagement", discipline_id,
    }).select("id").maybeSingle();
    const campaignId = camp?.id;

    // Target the existing bench via the PECR-safe RPC: only candidates whose
    // LATEST consent for this motion's purpose is granted, who have an email,
    // are in the right status, and are NOT on the suppression list — one row
    // per candidate (no duplicate/withdrawn sends). See sql/20_consent_suppression.
    const statuses = kind === "referral"
      ? ["engaged","qualified","compliance","ready","placed"]   // people who like us
      : ["sourced","contacted","dormant"];                       // gone quiet
    const { data: targets, error } = await sb.rpc("campaign_targets", {
      p_purpose: PURPOSE[kind],
      p_statuses: statuses,
      p_discipline: discipline_id,
      p_limit: cap,
    });
    if (error) return new Response(JSON.stringify({ error: error.message }), { status: 500, headers: CORS });

    const link = `${SITE}/intake.html?campaign=${campaignId}`;
    let sent = 0;
    for (const c of (targets ?? []) as { id: string; first_name: string; email: string }[]) {
      const body = kind === "referral"
        ? `Hi ${c.first_name || "there"},\n\nKnow someone brilliant looking for work? Refer a friend to Day Webster and you could earn ${bounty} once they're placed.\n\nJust share this link with them: ${link}\n\nThank you!`
        : `Hi ${c.first_name || "there"},\n\nWe'd love to help you find your next role with Day Webster. If you're open to work, take a moment to update your details and we'll be in touch with suitable opportunities:\n\n${link}\n\nThank you!`;
      const unsub = await unsubscribeUrl(c.email);
      const r = await sendBrevoEmail({
        to: c.email, toName: c.first_name,
        subject: kind === "referral" ? `Refer a friend, earn ${bounty}` : "Still looking for work? We can help",
        html: emailHtml(body, unsub ?? undefined),
        unsubscribeUrl: unsub ?? undefined,
      });
      if (r.ok) {
        sent++;
        await sb.from("messages").insert({ candidate_id: c.id, direction: "outbound", channel: "email", author: "system", subject: kind, body, status: "sent", external_ref: r.id ?? null });
        if (kind === "reengagement") await sb.from("candidates").update({ status: "contacted", campaign_id: campaignId }).eq("id", c.id);
      }
    }

    return new Response(JSON.stringify({ ok: true, kind, campaign_id: campaignId, targeted: targets?.length ?? 0, sent }), { headers: CORS });
  } catch (e) {
    return new Response(JSON.stringify({ error: String(e) }), { status: 500, headers: CORS });
  }
});
