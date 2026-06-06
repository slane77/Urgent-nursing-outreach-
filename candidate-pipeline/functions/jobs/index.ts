// ============================================================================
//  Day Webster — Candidate Pipeline · jobs (Supabase Edge Function, PUBLIC)
//
//  STATUS: DRAFT — NOT YET DEPLOYED. For review only.
//
//  Serves a public jobs board so vacancies are indexable by Google for Jobs:
//    /functions/v1/jobs              -> index of open vacancies
//    /functions/v1/jobs?slug=<slug>  -> one job page with JobPosting JSON-LD
//  Apply buttons go to intake.html?vacancy=<slug> (attribution + discipline tag).
//  verify_jwt=false (public). Reads via service role; only 'open' vacancies show.
//  ISOLATION: reads ONLY the `candidate` schema.
// ============================================================================

import { createClient } from "npm:@supabase/supabase-js";
import { buildJobPosting, toHtml, applyUrl } from "../_shared/jobposting.ts";

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { db: { schema: "candidate" } });
const esc = (s = "") => s.toString().replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;");
const html = (b: string) => new Response(`<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Day Webster — Jobs</title><style>body{font-family:system-ui,Segoe UI,Roboto,sans-serif;color:#1f2937;max-width:760px;margin:0 auto;padding:24px 16px;line-height:1.5}a{color:#16a34a}.job{border:1px solid #e5e7eb;border-radius:10px;padding:16px;margin:12px 0}.meta{color:#6b7280;font-size:14px}.btn{display:inline-block;background:#16a34a;color:#fff;text-decoration:none;padding:11px 18px;border-radius:8px;font-weight:600;margin-top:14px}h1{font-size:22px}</style></head><body>${b}</body></html>`, { headers: { "Content-Type": "text/html; charset=utf-8" } });

Deno.serve(async (req) => {
  const slug = new URL(req.url).searchParams.get("slug");

  if (slug) {
    const { data: v } = await sb.from("vacancies").select("*").eq("slug", slug).eq("status", "open").maybeSingle();
    if (!v) return html(`<h1>Job not found</h1><p><a href="?">See all jobs</a></p>`);
    const { data: adv } = await sb.from("adverts").select("structured").eq("vacancy_id", v.id).eq("channel", "google_jobs").maybeSingle();
    const jp = adv?.structured ?? buildJobPosting(v, toHtml(v.description || ""));
    const loc = [v.town, v.region].filter(Boolean).join(", ");
    return html(`
      <p><a href="?">← All jobs</a></p>
      <h1>${esc(v.title)}</h1>
      <p class="meta">${esc(loc)}${v.pay ? " · " + esc(v.pay) : ""}${v.employment_type ? " · " + esc(v.employment_type) : ""}</p>
      <div>${toHtml(v.description || "")}</div>
      <a class="btn" href="${esc(applyUrl(v.slug))}">Apply / register interest</a>
      <script type="application/ld+json">${JSON.stringify(jp)}</script>
    `);
  }

  const { data: vs } = await sb.from("vacancies").select("slug,title,town,region,pay").eq("status", "open").order("date_posted", { ascending: false }).limit(200);
  const items = (vs ?? []).map((v: any) =>
    `<div class="job"><a href="?slug=${encodeURIComponent(v.slug)}"><strong>${esc(v.title)}</strong></a><div class="meta">${esc([v.town, v.region].filter(Boolean).join(", "))}${v.pay ? " · " + esc(v.pay) : ""}</div></div>`
  ).join("") || "<p>No open vacancies right now — check back soon.</p>";
  return html(`<h1>Day Webster — current vacancies</h1>${items}`);
});
