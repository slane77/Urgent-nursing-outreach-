// ============================================================================
//  Day Webster — Candidate Pipeline · reference-request (Supabase Edge Function)
//
//  STATUS: DRAFT — NOT YET DEPLOYED. For review only.
//
//  Staff-triggered: emails a referee a reference request, embedding a
//  correlation TOKEN in the Reply-To so their reply (and the confirmation
//  handshake) routes back to the right candidate via `inbound-email`.
//  Opens/updates the candidate's reference requirement to 'requested'.
//
//  AUTH: staff-only (verify_jwt + authorised-domain check).
//  ISOLATION: writes ONLY to the `candidate` schema.
// ============================================================================

import { createClient } from "npm:@supabase/supabase-js";
import { sendBrevoEmail, emailHtml, newToken, replyToFor } from "../_shared/email.ts";

const sb = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { db: { schema: "candidate" } },
);
const ALLOWED = ["@daywebster.com","@daywebstergroup.com","@homecare-providers.com","@homecareproviders.co.uk"];
const CORS = { "Access-Control-Allow-Origin":"*", "Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type", "Content-Type":"application/json" };

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
    const { candidate_id, referee_email, referee_name, requirement_code = "references_3yr" } = await req.json();
    if (!candidate_id || !referee_email) return new Response(JSON.stringify({ error: "candidate_id and referee_email required" }), { status: 400, headers: CORS });

    const { data: cand } = await sb.from("candidates").select("first_name,last_name,discipline_id").eq("id", candidate_id).maybeSingle();
    if (!cand) return new Response(JSON.stringify({ error: "candidate not found" }), { status: 404, headers: CORS });
    const candName = [cand.first_name, cand.last_name].filter(Boolean).join(" ") || "the candidate";

    // Resolve the requirement (candidate's discipline or global).
    const { data: reqs } = await sb.from("compliance_requirements").select("id,code,discipline_id").eq("code", requirement_code).eq("active", true);
    const req2 = (reqs ?? []).find((r: any) => r.discipline_id === null || r.discipline_id === cand.discipline_id) ?? (reqs ?? [])[0];

    // Issue a correlation token and open/refresh the requirement as 'requested'.
    const token = newToken();
    await sb.from("email_tokens").insert({ token, candidate_id, requirement_id: req2?.id ?? null, purpose: "reference" });

    const { data: existing } = await sb.from("compliance_items")
      .select("id").eq("candidate_id", candidate_id).eq("requirement_id", req2?.id ?? null)
      .in("status", ["not_started","requested","received","verifying"]).limit(1).maybeSingle();
    if (existing) await sb.from("compliance_items").update({ status: "requested" }).eq("id", existing.id);
    else await sb.from("compliance_items").insert({ candidate_id, requirement_id: req2?.id ?? null, status: "requested" });

    // Email the referee.
    const replyTo = replyToFor(token);
    const body =
`Hello${referee_name ? " " + referee_name : ""},

${candName} has listed you as a referee for work with Day Webster, and has consented to us contacting you.

Please could you reply to this email with a brief reference covering their employment dates, role, and your view of their suitability? You can write it in your reply or attach a letter — whatever is easiest.

Thank you very much for your help.`;

    const r = await sendBrevoEmail({ to: referee_email, toName: referee_name, subject: `Reference request — ${candName}`, html: emailHtml(body), replyTo });

    // Log the outbound request against the candidate.
    await sb.from("messages").insert({
      candidate_id, direction: "outbound", channel: "email", author: "system",
      subject: `Reference request sent to ${referee_email}`, body, status: r.ok ? "sent" : "failed", external_ref: r.id ?? null,
    });

    return new Response(JSON.stringify({ ok: r.ok, error: r.error, token }), { headers: CORS });
  } catch (e) {
    return new Response(JSON.stringify({ error: String(e) }), { status: 500, headers: CORS });
  }
});
