// ============================================================================
//  Day Webster — Candidate Pipeline · job-advert (Supabase Edge Function)
//
//  STATUS: DRAFT — NOT YET DEPLOYED. For review only.
//
//  Staff/agent endpoint: create (or update) a vacancy and have Claude write the
//  human advert copy — a base description plus channel-tailored variants for
//  Indeed / Reed / CV-Library. The Google-for-Jobs JobPosting JSON-LD is built
//  deterministically in code (structured data must be exact), stored on a
//  'google_jobs' advert, and served by the public `jobs` function.
//
//  AUTH: staff-only (verify_jwt + authorised-domain). ISOLATION: candidate schema.
// ============================================================================

import Anthropic from "npm:@anthropic-ai/sdk";
import { createClient } from "npm:@supabase/supabase-js";
import { buildJobPosting, toHtml } from "../_shared/jobposting.ts";
import { verifyStaff, unauthorized, CORS } from "../_shared/auth.ts";

const MODEL = "claude-opus-4-8";
const anthropic = new Anthropic({ apiKey: Deno.env.get("ANTHROPIC_API_KEY")! });
const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { db: { schema: "candidate" } });
const CHANNELS = ["indeed","reed","cvlibrary"];

function slugify(s: string){ return s.toLowerCase().replace(/[^a-z0-9]+/g,"-").replace(/^-|-$/g,"").slice(0,60); }

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (!(await verifyStaff(req))) return unauthorized();
  try {
    const b = await req.json();

    // Resolve or create the vacancy.
    let vacancy: any;
    if (b.vacancy_id) {
      const { data } = await sb.from("vacancies").select("*").eq("id", b.vacancy_id).maybeSingle();
      vacancy = data;
    } else {
      const f = b.create ?? b;
      let disciplineId = null, specialtyId = null;
      if (f.discipline_code) { const { data } = await sb.from("disciplines").select("id").eq("code", f.discipline_code).maybeSingle(); disciplineId = data?.id ?? null; }
      if (f.specialty_code)  { const { data } = await sb.from("specialties").select("id").eq("code", f.specialty_code).maybeSingle(); specialtyId = data?.id ?? null; }
      const slug = `${slugify(f.title || "role")}-${slugify(f.town || "uk")}-${Math.random().toString(36).slice(2,7)}`;
      const { data, error } = await sb.from("vacancies").insert({
        slug, title: f.title, discipline_id: disciplineId, specialty_id: specialtyId,
        town: f.town || null, region: f.region || null, pay: f.pay || null,
        employment_type: f.employment_type || null,
        valid_through: f.valid_through || null,
      }).select("*").maybeSingle();
      if (error) return new Response(JSON.stringify({ error: error.message }), { status: 400, headers: CORS });
      vacancy = data;
      vacancy._notes = f.notes;
    }
    if (!vacancy) return new Response(JSON.stringify({ error: "vacancy not found" }), { status: 404, headers: CORS });

    // Claude writes the advert copy (structured output).
    const resp = await anthropic.messages.create({
      model: MODEL, max_tokens: 2500,
      output_config: { effort: "medium", format: { type: "json_schema", schema: {
        type: "object", properties: {
          description: { type: "string" },
          indeed: { type: "string" }, reed: { type: "string" }, cvlibrary: { type: "string" },
        }, required: ["description","indeed","reed","cvlibrary"], additionalProperties: false,
      } } },
      system: "You write UK healthcare/care recruitment adverts for Day Webster. Warm, specific, compliant — never overstate pay or guarantee work. 'description' is the main advert (~150–220 words, plain text with line breaks). 'indeed'/'reed'/'cvlibrary' are tighter board-tailored variants (~80–120 words). Mention discipline, location, pay if given, and a clear call to apply.",
      messages: [{ role: "user", content: JSON.stringify({
        title: vacancy.title, town: vacancy.town, region: vacancy.region, pay: vacancy.pay,
        employment_type: vacancy.employment_type, notes: vacancy._notes ?? b.notes ?? "",
      }) }],
    });
    const copy = JSON.parse(resp.content.filter(x=>x.type==="text").map((x:any)=>x.text).join(""));

    // Persist description + per-channel adverts + the Google-for-Jobs JSON-LD.
    await sb.from("vacancies").update({ description: copy.description }).eq("id", vacancy.id);
    const jobposting = buildJobPosting({ ...vacancy, description: copy.description }, toHtml(copy.description));

    const rows = [
      ...CHANNELS.map((ch) => ({ vacancy_id: vacancy.id, channel: ch, body: copy[ch], status: "draft" })),
      { vacancy_id: vacancy.id, channel: "google_jobs", body: copy.description, structured: jobposting, status: "draft" },
    ];
    // refresh any existing adverts for this vacancy, then insert the new set
    await sb.from("adverts").delete().eq("vacancy_id", vacancy.id).eq("status", "draft");
    await sb.from("adverts").insert(rows);

    return new Response(JSON.stringify({ ok: true, vacancy_id: vacancy.id, slug: vacancy.slug, description: copy.description, channels: { indeed: copy.indeed, reed: copy.reed, cvlibrary: copy.cvlibrary } }), { headers: CORS });
  } catch (e) {
    return new Response(JSON.stringify({ error: String(e) }), { status: 500, headers: CORS });
  }
});
