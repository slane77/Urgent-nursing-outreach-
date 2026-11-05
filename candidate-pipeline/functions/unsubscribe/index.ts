// ============================================================================
//  Day Webster — Candidate Pipeline · unsubscribe (Supabase Edge Function)
//
//  STATUS: DRAFT — NOT YET DEPLOYED. For review only.
//
//  Public one-click opt-out (PECR reg. 22 / UK-GDPR Art. 7(3)). Reached from
//  the List-Unsubscribe header and the footer link on every outreach email.
//  The link carries an HMAC tag (see _shared/unsubscribe.ts) so a recipient
//  can opt out without logging in, but nobody can suppress a third party.
//
//  On a valid request it:
//    1. adds the email to candidate.email_suppression (hard do-not-contact), and
//    2. writes withdrawal consent rows (granted=false) for marketing +
//       recruitment for any candidate with that email — so the append-only
//       consent history reflects the withdrawal.
//  Supports GET (footer link) and POST (RFC 8058 one-click). verify_jwt=false
//  at deploy (public); protection is the HMAC signature, which fails closed if
//  UNSUBSCRIBE_SECRET is unset. ISOLATION: `candidate` schema only.
// ============================================================================

import { createClient } from "npm:@supabase/supabase-js";
import { verifyUnsubscribe } from "../_shared/unsubscribe.ts";

const sb = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { db: { schema: "candidate" } },
);

function page(msg: string, ok = true): Response {
  const html = `<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
<div style="font-family:system-ui,Segoe UI,Roboto,sans-serif;max-width:32rem;margin:4rem auto;padding:0 1rem;color:#1f2937">
  <h1 style="font-size:1.25rem">${ok ? "You've been unsubscribed" : "Link not valid"}</h1>
  <p style="color:#4b5563;line-height:1.5">${msg}</p>
  <p style="color:#9ca3af;font-size:.85rem">Day Webster</p>
</div>`;
  return new Response(html, { status: ok ? 200 : 400, headers: { "Content-Type": "text/html; charset=utf-8" } });
}

// Record the opt-out: suppression row + withdrawal consent for both purposes.
async function suppress(email: string): Promise<void> {
  await sb.from("email_suppression").upsert(
    { email, reason: "unsubscribe link" },
    { onConflict: "email", ignoreDuplicates: true },
  );
  const { data: cands } = await sb.from("candidates").select("id").eq("email", email);
  for (const c of cands ?? []) {
    for (const purpose of ["marketing", "recruitment"]) {
      await sb.from("consent").insert({
        candidate_id: c.id, purpose, granted: false, evidence: "unsubscribe link",
      });
    }
  }
}

Deno.serve(async (req) => {
  const url = new URL(req.url);
  let email = (url.searchParams.get("e") ?? "").toLowerCase();
  let tag = url.searchParams.get("t") ?? "";

  // RFC 8058 one-click POST puts the params in the form body.
  if (req.method === "POST") {
    try {
      const form = new URLSearchParams(await req.text());
      email = (form.get("e") ?? email).toLowerCase();
      tag = form.get("t") ?? tag;
    } catch { /* keep query params */ }
  }

  const verified = await verifyUnsubscribe(email, tag);
  if (!verified) return page("This unsubscribe link isn't valid. Please contact us and we'll remove you.", false);

  try {
    await suppress(verified);
  } catch (_e) {
    return page("We couldn't complete the request just now. Please try again or contact us.", false);
  }
  return page(`<b>${verified}</b> has been removed from Day Webster outreach emails. You won't receive further messages of this kind.`);
});
