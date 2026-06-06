// ============================================================================
//  Day Webster — Candidate Pipeline · candidate-intake (Supabase Edge Function)
//
//  STATUS: DRAFT — NOT YET DEPLOYED. For review only.
//
//  Public handler behind the candidate self-registration form (intake.html).
//  Creates a candidate at status 'sourced' with consent recorded, deduping on
//  email. verify_jwt=false (public) — but RLS stays locked so only staff can
//  ever READ; writes go through this controlled function with the service role.
//
//  ISOLATION: writes ONLY to the `candidate` schema.
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

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const b = await req.json();

    // Honeypot: bots fill hidden fields. Silently accept and drop.
    if (b.website) return new Response(JSON.stringify({ ok: true }), { headers: CORS });

    const email = (b.email ?? "").toString().trim().toLowerCase();
    if (!email || !email.includes("@")) {
      return new Response(JSON.stringify({ error: "A valid email is required." }), { status: 400, headers: CORS });
    }
    if (b.consent !== true) {
      return new Response(JSON.stringify({ error: "Consent is required to register." }), { status: 400, headers: CORS });
    }

    // get-or-create the inbound_web source
    let sourceId: string | null = null;
    {
      const { data } = await sb.from("sources").select("id").eq("code", "inbound_web").maybeSingle();
      sourceId = data?.id ?? null;
      if (!sourceId) {
        const { data: c } = await sb.from("sources")
          .insert({ code: "inbound_web", name: "Inbound web enquiry", channel_type: "inbound", default_consent_basis: "consent" })
          .select("id").maybeSingle();
        sourceId = c?.id ?? null;
      }
    }

    // Optional attribution: applied to a specific vacancy and/or campaign.
    let vacancyId: string | null = null, campaignId: string | null = null, vacDiscipline: string | null = null;
    if (b.vacancy) {
      const { data: v } = await sb.from("vacancies").select("id,discipline_id").eq("slug", b.vacancy).maybeSingle();
      if (v) { vacancyId = v.id; vacDiscipline = v.discipline_id; }
    }
    if (b.campaign) {
      const { data: cm } = await sb.from("sourcing_campaigns").select("id").eq("id", b.campaign).maybeSingle();
      campaignId = cm?.id ?? null;
    }

    // Dedupe on email — if they already exist, just log a fresh enquiry note.
    const { data: existing } = await sb.from("candidates").select("id").eq("email", email).maybeSingle();
    let candidateId = existing?.id ?? null;

    if (!candidateId) {
      const { data, error } = await sb.from("candidates").insert({
        status: "sourced",
        source_id: sourceId,            // inbound_web; the vacancy carries the discipline
        vacancy_id: vacancyId,
        campaign_id: campaignId,
        discipline_id: vacDiscipline,
        first_name: (b.first_name ?? "").toString().trim() || null,
        last_name: (b.last_name ?? "").toString().trim() || null,
        email,
        phone: (b.phone ?? "").toString().trim() || null,
        town: (b.town ?? "").toString().trim() || null,
        postcode: (b.postcode ?? "").toString().trim() || null,
        availability: (b.availability ?? "").toString().trim() || null,
        notes: [b.discipline && `Discipline: ${b.discipline}`, b.specialty && `Specialty: ${b.specialty}`, b.message && `Message: ${b.message}`]
          .filter(Boolean).join("\n") || null,
        source_detail: { form: b },
      }).select("id").maybeSingle();
      if (error) return new Response(JSON.stringify({ error: error.message }), { status: 500, headers: CORS });
      candidateId = data?.id ?? null;
    } else {
      await sb.from("messages").insert({
        candidate_id: candidateId, direction: "inbound", channel: "web", author: "candidate",
        body: `Repeat web enquiry. ${b.message ?? ""}`.trim(),
      });
    }

    if (candidateId) {
      await sb.from("consent").insert({
        candidate_id: candidateId, purpose: "recruitment", basis: "consent",
        granted: true, evidence: "registration form opt-in",
      });
    }

    return new Response(JSON.stringify({ ok: true }), { headers: CORS });
  } catch (e) {
    return new Response(JSON.stringify({ error: String(e) }), { status: 500, headers: CORS });
  }
});
