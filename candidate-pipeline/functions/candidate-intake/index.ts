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
//  Captures the STRUCTURED "features" the form collects (profession/specialty,
//  channel attribution, geo, availability, registration, right-to-work) instead
//  of dropping them into a raw JSON blob, records referrals as data, and honours
//  a separate marketing opt-in.
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

const str = (v: unknown) => (v ?? "").toString().trim() || null;
const num = (v: unknown) => { const n = Number(v); return Number.isFinite(n) && v !== "" && v != null ? n : null; };
const bool = (v: unknown) => (v === true || v === "true" || v === "yes" || v === "on") ? true : (v === false || v === "false" || v === "no") ? false : null;
const slug = (s: string) => s.toLowerCase().replace(/[^a-z0-9]+/g, "_").replace(/^_|_$/g, "").slice(0, 40);
// Only accept values the DB CHECK constraints allow; anything else -> null.
const RTW = new Set(["uk_citizen", "settled", "pre_settled", "visa", "unconfirmed", "no"]);
const PAY_PERIOD = new Set(["hour", "day", "week", "annum"]);
const oneOf = (v: unknown, set: Set<string>) => { const s = str(v); return s && set.has(s) ? s : null; };
// A date column value: accept only YYYY-MM-DD that actually parses, else null.
const dateStr = (v: unknown) => { const s = str(v); return s && /^\d{4}-\d{2}-\d{2}$/.test(s) && !Number.isNaN(Date.parse(s)) ? s : null; };

// "How did you hear about us" label -> a sources.code (16_sourcing / 21 seed it).
const HEARD_MAP: Record<string, string> = {
  "indeed": "indeed", "reed": "reed", "cv-library / totaljobs": "cvlibrary",
  "nhs jobs": "nhs_jobs", "google search": "google_search", "day webster website": "careers_site",
  "facebook": "social", "instagram": "social", "tiktok": "social", "linkedin": "social",
  "x / twitter": "social", "whatsapp": "social",
  "word of mouth": "word_of_mouth", "day webster staff": "staff_referral",
  "returning candidate": "reengagement", "flyer / poster / qr": "flyer",
  "job fair / event": "event", "email": "email",
};

async function getOrCreateSource(code: string, name: string, channel = "other"): Promise<string | null> {
  const { data } = await sb.from("sources").select("id").eq("code", code).maybeSingle();
  if (data?.id) return data.id;
  const { data: c } = await sb.from("sources")
    .insert({ code, name, channel_type: channel, default_consent_basis: "consent" })
    .select("id").maybeSingle();
  return c?.id ?? null;
}

async function sourceForHeardAbout(label: string | null): Promise<string | null> {
  const base = await getOrCreateSource("inbound_web", "Inbound web enquiry", "inbound");
  if (!label) return base;
  const norm = label.toLowerCase().trim();
  const code = HEARD_MAP[norm] ?? (norm ? slug(norm) : "inbound_web");
  if (code === "inbound_web") return base;
  return (await getOrCreateSource(code, label, "other")) ?? base;
}

async function disciplineId(code: string | null): Promise<string | null> {
  if (!code) return null;
  const { data } = await sb.from("disciplines").select("id").eq("code", code).maybeSingle();
  return data?.id ?? null;
}
// Specialty codes are unique only WITHIN a discipline — always scope the lookup.
async function specialtyId(code: string | null, discId: string | null): Promise<string | null> {
  if (!code) return null;
  let q = sb.from("specialties").select("id").eq("code", code);
  q = discId ? q.eq("discipline_id", discId) : q;
  const { data } = await q.limit(1).maybeSingle();
  return data?.id ?? null;
}

// Build the structured candidate column patch from the form body.
function buildProfile(b: any) {
  const shift: Record<string, boolean> = {};
  for (const k of ["days", "nights", "long_days"]) { const v = bool(b[k]); if (v !== null) shift[k] = v; }
  const p: Record<string, unknown> = {
    first_name: str(b.first_name), last_name: str(b.last_name),
    phone: str(b.phone), town: str(b.town), postcode: str(b.postcode), region: str(b.region),
    ni_number: str(b.ni_number),
    latitude: num(b.latitude), longitude: num(b.longitude),
    band: str(b.band), pay_expectation: num(b.pay_expectation), pay_period: oneOf(b.pay_period, PAY_PERIOD),
    max_travel_miles: num(b.max_travel_miles),
    availability: str(b.availability), available_from: dateStr(b.available_from), notice_period: str(b.notice_period),
    has_car: bool(b.has_car), driving_licence: bool(b.driving_licence),
    right_to_work_status: oneOf(b.right_to_work_status, RTW),
    registration_body: str(b.registration_body), registration_number: str(b.registration_number),
    register_part: str(b.register_part), rtw_share_code: str(b.rtw_share_code),
  };
  if (Object.keys(shift).length) p.shift_prefs = shift;
  // Drop null/undefined so a refresh never overwrites existing data with blanks.
  return Object.fromEntries(Object.entries(p).filter(([, v]) => v !== null && v !== undefined));
}

// Record a friend referral: reuse an existing candidate or create a lead
// (WITHOUT consent — we never opt someone in on another person's say-so), and
// log it in the referrals ledger.
async function recordReferral(referrerId: string | null, campaignId: string | null, f: any): Promise<boolean> {
  const name = str(f.name), email = (f.email ?? "").toString().trim().toLowerCase() || null;
  const phone = str(f.phone), discCode = str(f.discipline_code);
  if (!name && !email && !phone) return false;

  const discId = await disciplineId(discCode);
  const specId = await specialtyId(str(f.specialty_code), discId);

  let referredId: string | null = null;
  if (email) {
    const { data: ex } = await sb.from("candidates").select("id").eq("email", email).maybeSingle();
    referredId = ex?.id ?? null;
  }
  if (!referredId) {
    const referralSource = await getOrCreateSource("referral", "Referral", "other");
    const [first, ...rest] = (name ?? "").split(/\s+/);
    const { data: ins } = await sb.from("candidates").insert({
      status: "sourced", source_id: referralSource,
      first_name: first || null, last_name: rest.length ? rest.join(" ") : null,
      email, phone, discipline_id: discId, primary_specialty_id: specId,
      source_detail: { referred_by: referrerId },
    }).select("id").maybeSingle();
    referredId = ins?.id ?? null;
    if (referredId && specId) await sb.from("candidate_specialties").upsert({ candidate_id: referredId, specialty_id: specId }, { onConflict: "candidate_id,specialty_id", ignoreDuplicates: true });
  }
  await sb.from("referrals").insert({
    referrer_candidate_id: referrerId, referred_candidate_id: referredId,
    referred_name: name, referred_email: email, referred_phone: phone,
    referred_discipline_code: discCode, campaign_id: campaignId,
  });
  return true;
}

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

    // Attribution: channel from "how did you hear about us", plus optional
    // vacancy/campaign from the URL.
    const sourceId = await sourceForHeardAbout(str(b.heard_about));
    let vacancyId: string | null = null, campaignId: string | null = null, vacDiscipline: string | null = null;
    if (b.vacancy) {
      const { data: v } = await sb.from("vacancies").select("id,discipline_id").eq("slug", b.vacancy).maybeSingle();
      if (v) { vacancyId = v.id; vacDiscipline = v.discipline_id; }
    }
    if (b.campaign) {
      const { data: cm } = await sb.from("sourcing_campaigns").select("id").eq("id", b.campaign).maybeSingle();
      campaignId = cm?.id ?? null;
    }

    // Resolve the profession the candidate chose (fall back to the vacancy's).
    const discId = (await disciplineId(str(b.discipline_code))) ?? vacDiscipline;
    const specId = await specialtyId(str(b.specialty_code), discId);
    const profile = buildProfile(b);

    // Dedupe on email. New -> insert; returning -> refresh their details.
    const { data: existing } = await sb.from("candidates").select("id").eq("email", email).maybeSingle();
    let candidateId = existing?.id ?? null;

    let referred = 0;

    if (!candidateId) {
      // A brand-new self-registration: the submitter owns this email, so we
      // capture their profile, consent and referrals. Store a trimmed copy of
      // the raw form for provenance — WITHOUT the referred friends' PII or the
      // NI number (which is kept in its own column).
      const { friends: _friends, ni_number: _ni, ...formSafe } = b;
      const { data, error } = await sb.from("candidates").insert({
        status: "sourced", source_id: sourceId, vacancy_id: vacancyId, campaign_id: campaignId,
        discipline_id: discId, primary_specialty_id: specId,
        email, notes: str(b.message) ? `Message: ${str(b.message)}` : null,
        source_detail: { heard_about: str(b.heard_about), address: str(b.address), form: formSafe },
        ...profile,
      }).select("id").maybeSingle();
      if (error) {
        console.error("intake insert:", error.message);
        return new Response(JSON.stringify({ error: "Could not complete registration. Please try again." }), { status: 500, headers: CORS });
      }
      candidateId = data?.id ?? null;

      if (candidateId && specId) {
        await sb.from("candidate_specialties").upsert({ candidate_id: candidateId, specialty_id: specId }, { onConflict: "candidate_id,specialty_id", ignoreDuplicates: true });
      }
      if (candidateId) {
        // Recruitment consent (required to register) + optional marketing opt-in.
        await sb.from("consent").insert({
          candidate_id: candidateId, purpose: "recruitment", basis: "consent",
          granted: true, evidence: "registration form opt-in",
        });
        if (bool(b.marketing_consent) === true) {
          await sb.from("consent").insert({
            candidate_id: candidateId, purpose: "marketing", basis: "consent",
            granted: true, evidence: "registration form marketing opt-in",
          });
        }
      }

      // Referred friends (leads only — no consent recorded on their behalf).
      if (candidateId && Array.isArray(b.friends)) {
        for (const f of b.friends.slice(0, 10)) {
          if (await recordReferral(candidateId, campaignId, f)) referred++;
        }
      }
    } else {
      // Email already on file. The submitter is UNVERIFIED (email is a weak
      // key), so we NEVER modify the existing record, its consent, or accept
      // referrals in their name from this public endpoint — we only log the
      // resubmission for a staff member to review and reconcile.
      const submitted = Object.entries(profile).filter(([k]) => k !== "ni_number").map(([k, v]) => `${k}: ${v}`).join(", ");
      await sb.from("messages").insert({
        candidate_id: candidateId, direction: "inbound", channel: "web", author: "candidate",
        body: `Repeat web enquiry (not auto-applied — staff to review). ${str(b.message) ?? ""}${submitted ? `\nSubmitted: ${submitted}` : ""}`.trim(),
      });
    }

    return new Response(JSON.stringify({ ok: true, referred }), { headers: CORS });
  } catch (e) {
    return new Response(JSON.stringify({ error: String(e) }), { status: 500, headers: CORS });
  }
});
