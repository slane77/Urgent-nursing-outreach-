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

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { db: { schema: "candidate" } });
const ALLOWED = ["@daywebster.com","@daywebstergroup.com","@homecare-providers.com","@homecareproviders.co.uk"];
const CORS = { "Access-Control-Allow-Origin":"*", "Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type", "Content-Type":"application/json" };
const SITE = (Deno.env.get("PUBLIC_SITE_URL") ?? "").replace(/\/$/, "");

function authorized(req: Request): boolean {
  const t = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "").split(".")[1];
  if (!t) return false;
  try { const e = (JSON.parse(atob(t.replace(/-/g,"+").replace(/_/g,"/"))).email ?? "").toLowerCase(); return ALLOWED.some(d=>e.endsWith(d)); }
  catch { return false; }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (!authorized(req)) return new Response(JSON.stringify({ error: "unauthorized" }), { status: 401, headers: CORS });
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

    // Target the existing bench: must have email + a granted consent (PECR).
    const statuses = kind === "referral"
      ? ["engaged","qualified","compliance","ready","placed"]   // people who like us
      : ["sourced","contacted","dormant"];                       // gone quiet
    let q = sb.from("candidates")
      .select("id,first_name,email,consent!inner(granted)")
      .not("email", "is", null)
      .eq("consent.granted", true)
      .in("status", statuses)
      .limit(cap);
    if (discipline_id) q = q.eq("discipline_id", discipline_id);
    const { data: targets, error } = await q;
    if (error) return new Response(JSON.stringify({ error: error.message }), { status: 500, headers: CORS });

    const link = `${SITE}/intake.html?campaign=${campaignId}`;
    let sent = 0;
    for (const c of targets ?? []) {
      const body = kind === "referral"
        ? `Hi ${c.first_name || "there"},\n\nKnow someone brilliant looking for work? Refer a friend to Day Webster and you could earn ${bounty} once they're placed.\n\nJust share this link with them: ${link}\n\nThank you!`
        : `Hi ${c.first_name || "there"},\n\nWe'd love to help you find your next role with Day Webster. If you're open to work, take a moment to update your details and we'll be in touch with suitable opportunities:\n\n${link}\n\nThank you!`;
      const r = await sendBrevoEmail({ to: c.email, toName: c.first_name, subject: kind === "referral" ? `Refer a friend, earn ${bounty}` : "Still looking for work? We can help", html: emailHtml(body) });
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
