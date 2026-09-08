// send-mailshot v26 — adds job-detail tokens ({{JobDays}}, {{JobHours}}, {{JobRate}},
// {{JobWard}}, {{JobPostcode}}, {{JobTown}}, {{JobStartDate}}, {{JobNotes}},
// {{JobSummary}}) sourced from an optional `jobDetails` object in the request body.
// These come from the job-email drag-and-drop feature (extract-job-email function)
// so a send that started from "find candidates near this job" can drop the
// extracted shift info straight into the template.
// v25 — candidate sends expose {{Specialty}} (candidates.specialty,
// e.g. "Mental Health", "ITU / Critical Care") alongside {{JobTitle}} (RMN, ITU...).
// v13 — adds locked-down CANDIDATE audience support.
// audience:'candidates' + candidateIds: sends to the candidates table (practice
// nurses etc.), access-checked against user_profiles.candidate_sectors (admins
// bypass). Candidate sends always go from the SIGNED-IN person's own address,
// log to candidate_sends, and stamp candidates.last_emailed_at. do_not_use and
// unsubscribed candidates are skipped server-side.
// v12: camhs added to AHP_SPECIALTIES (routes to Talking Therapies group inbox)
// and to SPECIALTY_LABELS ({{Specialty}} renders "CAMHS").
// Also: {{Group}} (care_group), «...» merge-field style, and [[ ... ]] optional
// segments that vanish when any token inside is blank.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const AHP_SPECIALTIES = new Set(["occupational_therapy","physiotherapy","radiography","speech_language","podiatry","pharmacy","dietetics","orthoptics","art_therapy","paramedic","prosthetics","audiology","biomedical_science","sterile_services","mental_health","camhs","operating_theatres"]);

const SPECIALTY_LABELS: Record<string, string> = {
  occupational_therapy: "Occupational Therapy",
  physiotherapy:        "Physiotherapy",
  radiography:          "Radiography",
  speech_language:      "Speech & Language Therapy",
  podiatry:             "Podiatry",
  pharmacy:             "Pharmacy",
  dietetics:            "Dietetics",
  orthoptics:           "Orthoptics",
  art_therapy:          "Art Therapy",
  paramedic:            "Paramedic",
  prosthetics:          "Prosthetics & Orthotics",
  audiology:            "Audiology",
  biomedical_science:   "Biomedical Science",
  sterile_services:     "Sterile Services",
  mental_health:        "Mental Health",
  camhs:                "CAMHS",
  operating_theatres:   "Operating Theatres",
};

interface JobDetails {
  postcode?: string; town_or_location?: string; job_title?: string;
  ward_or_department?: string; days?: string; hours?: string;
  rate?: string; start_date?: string; notes?: string;
}

function specialtyLabel(dept: unknown): string {
  const d = (dept == null ? "" : String(dept)).trim();
  if (!d) return "";
  if (SPECIALTY_LABELS[d]) return SPECIALTY_LABELS[d];
  return d.replace(/_/g, " ").replace(/\b\w/g, (ch) => ch.toUpperCase());
}

function jobSummary(j: JobDetails | undefined): string {
  if (!j) return "";
  const parts: string[] = [];
  if (j.job_title) parts.push(j.job_title);
  if (j.ward_or_department) parts.push(j.ward_or_department);
  if (j.town_or_location || j.postcode) parts.push([j.town_or_location, j.postcode].filter(Boolean).join(" "));
  if (j.days) parts.push(j.days);
  if (j.hours) parts.push(j.hours);
  if (j.rate) parts.push(j.rate);
  if (j.start_date) parts.push("Starting " + j.start_date);
  return parts.join(" · ");
}

// Raw (no-fallback) value for a token name — used to decide whether an optional [[...]] segment survives.
function rawVal(name: string, c: Record<string, unknown>): string {
  const s = (x: unknown) => (x == null ? "" : String(x).trim());
  const j = (c._jobDetails || {}) as JobDetails;
  switch (name) {
    case "FirstName":    return s(c.first_name);
    case "LastName":     return s(c.last_name);
    case "Name":         return [s(c.first_name), s(c.last_name)].filter(Boolean).join(" ");
    case "Title":        return s(c.title);
    case "Org":
    case "Surgery":      return s(c.org);
    case "Group":        return s(c.care_group);
    case "Town":         return s(c.town);
    case "Region":       return s(c.region);
    case "VacancyTitle":
    case "Vacancy":
    case "Role":         return s(c.vacancy_title);
    case "JobTitle":     return s(c.job_title);
    case "Band":         return s(c.band_requested);
    case "Specialty":    return specialtyLabel(c.department);
    case "SenderName":   return s(c._senderName);
    case "JobPostcode":  return s(j.postcode);
    case "JobTown":      return s(j.town_or_location);
    case "JobWard":      return s(j.ward_or_department);
    case "JobDays":      return s(j.days);
    case "JobHours":     return s(j.hours);
    case "JobRate":      return s(j.rate);
    case "JobStartDate": return s(j.start_date);
    case "JobNotes":     return s(j.notes);
    case "JobSummary":   return jobSummary(j);
    default:             return "";
  }
}

function personalize(text: string, c: Record<string, unknown>): string {
  if (!text) return "";
  const v = (x: unknown, fallback = "") => (x == null || String(x).trim() === "" ? fallback : String(x).trim());
  const j = (c._jobDetails || {}) as JobDetails;

  // Optional [[ ... ]] segments: drop the whole segment if ANY token inside has no value.
  text = String(text).replace(/\[\[([\s\S]*?)\]\]/g, (_m: string, inner: string) => {
    const names: string[] = [];
    inner.replace(/\{\{(\w+)\}\}|«(\w+)»/g, (mm: string, a?: string, b?: string) => {
      const nm = a || b;
      if (nm) names.push(nm);
      return mm;
    });
    return names.some((n) => rawVal(n, c) === "") ? "" : inner;
  });

  const first    = v(c.first_name, "there");
  const fullName = [v(c.first_name, ""), v(c.last_name, "")].filter(Boolean).join(" ") || "there";
  const vacancy  = v(c.vacancy_title, "the role you're advertising");
  const org      = v(c.org, "your organisation");
  const group    = v(c.care_group);
  const lastName = v(c.last_name);
  const title    = v(c.title);
  const town     = v(c.town, "your area");
  const region   = v(c.region, "your area");
  const jobTitle = v(c.job_title, vacancy);

  return text
    .replaceAll("{{FirstName}}",    first).replaceAll("«FirstName»", first)
    .replaceAll("{{LastName}}",     lastName).replaceAll("«LastName»", lastName)
    .replaceAll("{{Name}}",         fullName)
    .replaceAll("{{Title}}",        title).replaceAll("«Title»", title)
    .replaceAll("{{Org}}",          org).replaceAll("«Org»", org)
    .replaceAll("{{Surgery}}",      v(c.org, "your surgery"))
    .replaceAll("{{Group}}",        group).replaceAll("«Group»", group)
    .replaceAll("{{Town}}",         town).replaceAll("«Town»", town)
    .replaceAll("{{Region}}",       region).replaceAll("«Region»", region)
    .replaceAll("{{VacancyTitle}}", vacancy)
    .replaceAll("{{Vacancy}}",      vacancy)
    .replaceAll("{{Role}}",         vacancy)
    .replaceAll("{{JobTitle}}",     jobTitle).replaceAll("«JobTitle»", jobTitle)
    .replaceAll("{{Band}}",         v(c.band_requested))
    .replaceAll("{{Specialty}}",    specialtyLabel(c.department))
    .replaceAll("{{SenderName}}",   v(c._senderName, "Day Webster Group"))
    .replaceAll("{{JobPostcode}}",  v(j.postcode))
    .replaceAll("{{JobTown}}",      v(j.town_or_location))
    .replaceAll("{{JobWard}}",      v(j.ward_or_department))
    .replaceAll("{{JobDays}}",      v(j.days))
    .replaceAll("{{JobHours}}",     v(j.hours))
    .replaceAll("{{JobRate}}",      v(j.rate))
    .replaceAll("{{JobStartDate}}", v(j.start_date))
    .replaceAll("{{JobNotes}}",     v(j.notes))
    .replaceAll("{{JobSummary}}",   jobSummary(j));
}

function toHtml(text: string): string {
  return text.replaceAll("&","&amp;").replaceAll("<","&lt;").replaceAll(">","&gt;").replaceAll("\n","<br>");
}

export async function deliverRecipient(req: Request, user: {id: string; email?: string}, snapshot: {subject: string; body: string}) {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return new Response(JSON.stringify({ error: "Method not allowed" }), {
    status: 405, headers: { ...corsHeaders, "Content-Type": "application/json" }
  });

  try {
    const SUPABASE_URL  = Deno.env.get("SUPABASE_URL")!;
    const SERVICE_KEY   = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const ANON_KEY      = Deno.env.get("SUPABASE_ANON_KEY")!;
    const BREVO_API_KEY = Deno.env.get("BREVO_API_KEY");

    if (!BREVO_API_KEY) return new Response(JSON.stringify({
      error: "BREVO_API_KEY not set in Supabase secrets."
    }), { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } });

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);
    const body  = await req.json();
    const { templateId, contactIds, batchId, audience, candidateIds, jobDetails } = body;

    // ── Signed-in sender (the person actually sending) ──
    const { data: userProfile } = await admin
      .from('user_profiles')
      .select('sender_email, sender_name, full_name, role, candidate_sectors')
      .eq('user_id', user.id)
      .single();
    if (!userProfile) return new Response(JSON.stringify({error: 'Authorised profile required'}), {status:403});
    const fallbackEmail = userProfile?.sender_email || user.email || 'scott.lane@daywebster.com';
    const fallbackName  = userProfile?.sender_name  || userProfile?.full_name || 'Day Webster Group';

    // ════════════════════════════════════════════════════════════════════
    //  CANDIDATES AUDIENCE — locked-down candidate database sends
    // ════════════════════════════════════════════════════════════════════
    if (audience === 'candidates') {
      if (!templateId || !Array.isArray(candidateIds) || candidateIds.length === 0)
        return new Response(JSON.stringify({ error: "templateId and candidateIds required" }), {
          status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" }
        });
      if (candidateIds.length > 300)
        return new Response(JSON.stringify({ error: "Max 300 per batch" }), {
          status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" }
        });

      const isAdmin = userProfile?.role === 'admin';
      const mySectors: string[] = Array.isArray(userProfile?.candidate_sectors) ? userProfile!.candidate_sectors : [];
      if (!isAdmin && mySectors.length === 0)
        return new Response(JSON.stringify({ error: "No candidate access" }), {
          status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" }
        });

      const template = snapshot;
      if (!template) return new Response(JSON.stringify({ error: "Template not found" }), {
        status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" }
      });

      const { data: cands } = await admin.from("candidates").select("*").in("id", candidateIds);
      if (!cands) return new Response(JSON.stringify({ error: "Failed to load candidates" }), {
        status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" }
      });

      const theBatchId = batchId || `cand_batch_${Date.now()}`;
      const results: { candidateId: string; ok: boolean; error?: string }[] = [];
      const sendLog: Record<string, unknown>[] = [];
      const sentIds: string[] = [];

      for (const cand of cands) {
        if (!isAdmin && !mySectors.includes(cand.sector)) {
          results.push({ candidateId: cand.id, ok: false, error: "no access" });
          continue;
        }
        if (!cand.email || !cand.email.includes("@") || cand.unsubscribed || cand.status === 'do_not_use') {
          results.push({ candidateId: cand.id, ok: false, error: "skipped" });
          continue;
        }

        const pseudo = {
          id: cand.id,
          first_name: cand.first_name,
          last_name:  cand.last_name,
          email:      cand.email,
          town:       cand.town,
          region:     cand.county || cand.town,
          job_title:  cand.job_title,
          department: cand.specialty,
          org:        "",
          _senderName: fallbackName,
          _jobDetails: jobDetails || null,
        };
        const subject  = personalize(template.subject, pseudo);
        const textBody = personalize(template.body,    pseudo);
        const htmlBody = toHtml(textBody);

        try {
          const brevoRes = await fetch("https://api.brevo.com/v3/smtp/email", {
            method: "POST",
            signal: AbortSignal.timeout(15000),
            headers: { "api-key": BREVO_API_KEY, "Content-Type": "application/json", "Accept": "application/json" },
            body: JSON.stringify({
              sender: { email: fallbackEmail, name: fallbackName },
              to: [{
                email: cand.email,
                name:  [cand.first_name, cand.last_name].filter(Boolean).join(" ") || cand.email,
              }],
              subject,
              htmlContent: htmlBody,
              textContent: textBody,
              tags: [theBatchId, "candidates", templateId],
              replyTo: { email: fallbackEmail, name: fallbackName },
            }),
          });

          if (brevoRes.ok) {
            results.push({ candidateId: cand.id, ok: true });
            sendLog.push({ candidate_id: cand.id, template_id: templateId, batch_id: theBatchId, status: "sent", sent_by: user.id });
            sentIds.push(cand.id);
          } else {
            const errText = await brevoRes.text();
            results.push({ candidateId: cand.id, ok: false, error: `Brevo ${brevoRes.status}: ${errText.slice(0,100)}` });
          }
        } catch (e) {
          results.push({ candidateId: cand.id, ok: false, error: String(e) });
        }
        await new Promise(r => setTimeout(r, 120));
      }

      if (sendLog.length > 0) { const {error} = await admin.from("candidate_sends").insert(sendLog); if (error) throw new Error("Delivery accepted but audit insert failed"); }
      if (sentIds.length > 0) {
        await admin.from("candidates").update({ last_emailed_at: new Date().toISOString() }).in("id", sentIds);
      }

      return new Response(JSON.stringify({
        sent:   results.filter(r => r.ok).length,
        failed: results.filter(r => !r.ok).length,
        total:  results.length,
        from:   [`${fallbackName} <${fallbackEmail}>`],
        results,
      }), { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    // ════════════════════════════════════════════════════════════════════
    //  CONTACTS AUDIENCE (existing behaviour)
    // ════════════════════════════════════════════════════════════════════
    if (!templateId || !Array.isArray(contactIds) || contactIds.length === 0)
      return new Response(JSON.stringify({ error: "templateId and contactIds required" }), {
        status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" }
      });
    if (contactIds.length > 300)
      return new Response(JSON.stringify({ error: "Max 300 per batch" }), {
        status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" }
      });

    // ── Team sender mappings (AHP specialty inboxes) ──
    const { data: senderRows } = await admin
      .from('sender_addresses')
      .select('email, name, source, sub_source');
    const senderList = (senderRows || []) as Array<{ email: string; name: string; source: string; sub_source: string | null }>;

    const lookupSender = (source: string | null, sub: string | null): { email: string; name: string } | null => {
      if (!source) return null;
      let row = sub ? senderList.find(s => s.source === source && s.sub_source === sub) : null;
      if (!row) row = senderList.find(s => s.source === source && !s.sub_source) || null;
      return row ? { email: row.email, name: row.name || fallbackName } : null;
    };

    const deriveContactSource = (c: Record<string, unknown>): { source: string | null; sub: string | null } => {
      const dept = String(c.department || '').trim();
      const notes = String(c.notes || '');
      if (AHP_SPECIALTIES.has(dept)) return { source: 'ahp', sub: dept };
      if (dept === 'Advanced Nurse Practitioner' || /Source:\s*ANP/i.test(notes)) return { source: 'anp', sub: null };
      if (dept === 'Emergency Nurse Practitioner' || /Source:\s*ENP/i.test(notes)) return { source: 'enp', sub: null };
      if (/Source:\s*GP Surgery/i.test(notes)) return { source: 'gp_surgery', sub: null };
      return { source: null, sub: null };
    };

    // ── Resolve the "from" for this send ──
    // AHP / NHS Scotland campaigns keep their per-specialty Day Webster team
    // address (a single specialty if chosen, else per-contact derivation below).
    // EVERY other campaign — GP, agency, HSE, care home, ANP/ENP, all —
    // sends from the PERSON who is signed in and sending (their own address),
    // never a team address and never another user's.
    const AHP_CAMPAIGN = new Set(["ahp", "nhs_scotland"]);
    const campaignSource = body.source ? String(body.source) : null;
    const campaignSub    = body.subSource ? String(body.subSource) : null;
    let batchFrom: { email: string; name: string } | null = null;
    if (body.fromEmail) {
      batchFrom = { email: String(body.fromEmail), name: String(body.fromName || body.fromEmail) };
    } else if (campaignSource && AHP_CAMPAIGN.has(campaignSource)) {
      if (campaignSub) batchFrom = lookupSender(campaignSource, campaignSub);
      // no specialty chosen → batchFrom stays null → per-contact team address below
    } else if (campaignSource) {
      // Non-AHP campaign → the signed-in sender, one address for the whole batch.
      batchFrom = { email: fallbackEmail, name: fallbackName };
    }

    const template = snapshot;
    if (!template) return new Response(JSON.stringify({ error: "Template not found" }), {
      status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" }
    });

    const { data: contacts } = await admin.from("contacts").select("*").in("id", contactIds);
    if (!contacts) return new Response(JSON.stringify({ error: "Failed to load contacts" }), {
      status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" }
    });

    const theBatchId = batchId || `batch_${Date.now()}`;
    const results: { contactId: string; ok: boolean; error?: string }[] = [];
    const sendLog: Record<string, unknown>[] = [];
    const sentContactIds: string[] = [];
    const fromsUsed = new Set<string>();

    for (const contact of contacts) {
      if (!contact.email || !contact.email.includes("@") || contact.status === "unsubscribed") {
        results.push({ contactId: contact.id, ok: false, error: "skipped" });
        continue;
      }

      // Resolve the "send from" for THIS contact.
      let resolved = batchFrom;
      if (!resolved) { const d = deriveContactSource(contact); resolved = lookupSender(d.source, d.sub); }
      const fromEmail = resolved?.email || fallbackEmail;
      const fromName  = resolved?.name  || fallbackName;
      fromsUsed.add(`${fromName} <${fromEmail}>`);

      const contactWithSender = { ...contact, _senderName: fromName, _jobDetails: jobDetails || null };
      const subject  = personalize(template.subject, contactWithSender);
      const textBody = personalize(template.body,    contactWithSender);
      const htmlBody = toHtml(textBody);

      try {
        const brevoRes = await fetch("https://api.brevo.com/v3/smtp/email", {
          method: "POST",
          signal: AbortSignal.timeout(15000),
          headers: { "api-key": BREVO_API_KEY, "Content-Type": "application/json", "Accept": "application/json" },
          body: JSON.stringify({
            sender: { email: fromEmail, name: fromName },
            to: [{
              email: contact.email,
              name:  [contact.first_name, contact.last_name].filter(Boolean).join(" ") || contact.email,
            }],
            subject,
            htmlContent: htmlBody,
            textContent: textBody,
            customId: contact.id,
            tags: [theBatchId, templateId],
            replyTo: { email: fromEmail, name: fromName },
          }),
        });

        if (brevoRes.ok) {
          results.push({ contactId: contact.id, ok: true });
          sendLog.push({ contact_id: contact.id, template_id: templateId, batch_id: theBatchId, status: "sent", sent_by: user.id });
          sentContactIds.push(contact.id);
        } else {
          const errText = await brevoRes.text();
          results.push({ contactId: contact.id, ok: false, error: `Brevo ${brevoRes.status}: ${errText.slice(0,100)}` });
        }
      } catch (e) {
        results.push({ contactId: contact.id, ok: false, error: String(e) });
      }
      await new Promise(r => setTimeout(r, 120));
    }

    if (sendLog.length > 0) { const {error} = await admin.from("email_sends").insert(sendLog); if (error) throw new Error("Delivery accepted but audit insert failed"); }

    if (sentContactIds.length > 0) {
      const followUpDate = new Date();
      followUpDate.setDate(followUpDate.getDate() + 14);
      await admin.from("contacts").update({
        stage: "contacted",
        follow_up_date: followUpDate.toISOString().split("T")[0]
      }).in("id", sentContactIds).eq("stage", "new");
    }

    return new Response(JSON.stringify({
      sent:   results.filter(r => r.ok).length,
      failed: results.filter(r => !r.ok).length,
      total:  results.length,
      from:   Array.from(fromsUsed),
      results,
    }), { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } });

  } catch (e) {
    return new Response(JSON.stringify({ error: "Unexpected error: " + String(e) }), {
      status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" }
    });
  }
}
