// ============================================================================
//  Day Webster — Candidate Pipeline · inbound-email (Supabase Edge Function)
//
//  STATUS: DRAFT — NOT YET DEPLOYED. For review only.
//
//  The inbound-email spine (assessment §8f / §9-component-11). An email
//  provider's inbound-parse webhook POSTs here; we:
//    1. Identify the candidate — by correlation TOKEN (plus-address/subject),
//       else by matching the sender's email.
//    2. Classify with Claude — reference / compliance document / candidate
//       reply / noise — and LOCATE the artefact (body vs attachment), mapping
//       it to a requirement code.
//    3. Ingest — store attachments to the private `candidate-docs` bucket, log
//       the message, and land it on a compliance_item as status='received'.
//    4. Anti-fraud signal — institutional vs free-webmail sender domain; low
//       confidence / webmail / judgement items are flagged needs_human.
//  It NEVER auto-verifies: acceptance is a human decision in the cockpit (§7).
//
//  Provider-agnostic: map your provider's inbound payload (Brevo Inbound /
//  SendGrid Inbound Parse / Mailgun Routes) to the JSON shape below, or add a
//  thin adapter at the top of Deno.serve.
//    { from, to, subject, text, html, attachments:[{filename,contentType,contentBase64}] }
//
//  Protect with ?secret=<INBOUND_SECRET> (set the env var; configure the
//  provider webhook URL to include it). verify_jwt=false at deploy (public).
//  ISOLATION: writes ONLY to the `candidate` schema + the candidate-docs bucket.
// ============================================================================

import Anthropic from "npm:@anthropic-ai/sdk";
import { createClient } from "npm:@supabase/supabase-js";
import { sendBrevoEmail, emailHtml, replyToFor } from "../_shared/email.ts";

const MODEL = "claude-opus-4-8";
const BUCKET = "candidate-docs";
const anthropic = new Anthropic({ apiKey: Deno.env.get("ANTHROPIC_API_KEY")! });
const sb = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { db: { schema: "candidate" } },
);

const FREE_WEBMAIL = ["gmail.com","yahoo.com","yahoo.co.uk","hotmail.com","hotmail.co.uk","outlook.com","live.com","icloud.com","me.com","aol.com","gmx.com","proton.me","protonmail.com","btinternet.com","sky.com"];

function domainOf(addr = ""){ const m = addr.toLowerCase().match(/@([^>\s]+)/); return m ? m[1] : ""; }
function tokenFrom(to = "", subject = ""){
  const plus = to.toLowerCase().match(/\+([a-z0-9]{6,})@/);      // local+TOKEN@domain
  if (plus) return plus[1];
  const subj = subject.match(/\[#([a-z0-9]{6,})\]/i);            // [#TOKEN] in subject
  return subj ? subj[1] : null;
}
function b64ToBytes(b64: string){
  const bin = atob(b64); const out = new Uint8Array(bin.length);
  for (let i=0;i<bin.length;i++) out[i] = bin.charCodeAt(i);
  return out;
}

async function classify(subject: string, body: string, attachments: any[], reqCodes: string[]) {
  const resp = await anthropic.messages.create({
    model: MODEL, max_tokens: 1500,
    output_config: { effort: "low", format: { type: "json_schema", schema: {
      type: "object", properties: {
        type: { type: "string", enum: ["reference","compliance_document","candidate_reply","noise"] },
        requirement_code: { type: "string" },          // best match from the provided list, or ""
        artefact_location: { type: "string", enum: ["body","attachment","none"] },
        attachment_index: { type: "integer" },          // -1 if none
        extracted: { type: "object", additionalProperties: true },
        summary: { type: "string" },
      },
      required: ["type","requirement_code","artefact_location","attachment_index","extracted","summary"],
      additionalProperties: false,
    } } },
    system: "You triage inbound recruitment-compliance emails. Decide the type, and if it's a reference or compliance document, which requirement_code it satisfies (choose ONLY from the provided codes; '' if none fits). Say where the evidence is (email body vs an attachment) and the attachment index (0-based, -1 if none). Pull a few key fields into 'extracted' (e.g. dates, referee name/role, document number) — but never assert a registration or reference is genuine. Forwarded chains are common; find the actual artefact.",
    messages: [{ role: "user", content:
      `Valid requirement codes: ${reqCodes.join(", ") || "(none)"}\n\nSubject: ${subject}\n\nBody:\n${body.slice(0, 6000)}\n\nAttachments: ${JSON.stringify(attachments.map((a,i)=>({i, filename:a.filename, type:a.contentType})))}` }],
  });
  const text = resp.content.filter(b => b.type === "text").map((b: any)=>b.text).join("");
  return JSON.parse(text);
}

Deno.serve(async (req) => {
  const url = new URL(req.url);
  const need = Deno.env.get("INBOUND_SECRET");
  if (need && url.searchParams.get("secret") !== need) return new Response("forbidden", { status: 403 });

  try {
    const p = await req.json();
    const from = p.from ?? p.sender ?? "";
    const to = p.to ?? p.recipient ?? "";
    const subject = p.subject ?? "";
    const body = (p.text ?? p.html ?? "").toString();
    const attachments = Array.isArray(p.attachments) ? p.attachments : [];
    const senderDomain = domainOf(from);
    const senderEmail = (from.match(/[^<\s]+@[^>\s]+/) ?? [""])[0].toLowerCase();
    const institutional = senderDomain && !FREE_WEBMAIL.includes(senderDomain);

    // 1. Identify candidate (token first, else sender email).
    let candidateId: string | null = null, tokenReqId: string | null = null, purpose = "document";
    const tok = tokenFrom(to, subject);
    if (tok) {
      const { data } = await sb.from("email_tokens").select("candidate_id,requirement_id,purpose").eq("token", tok).maybeSingle();
      if (data) { candidateId = data.candidate_id; tokenReqId = data.requirement_id; purpose = data.purpose; }
    }
    if (!candidateId && senderEmail) {
      const { data } = await sb.from("candidates").select("id").eq("email", senderEmail).maybeSingle();
      candidateId = data?.id ?? null;
    }
    if (!candidateId) return new Response(JSON.stringify({ ok: true, matched: false }), { headers: { "Content-Type": "application/json" } });

    // Load the candidate's applicable requirement codes for classification.
    const { data: cand } = await sb.from("candidates").select("discipline_id").eq("id", candidateId).maybeSingle();
    const { data: allReqs } = await sb.from("compliance_requirements").select("id,code,needs_human,discipline_id").eq("active", true);
    const reqs = (allReqs ?? []).filter((r: any) => r.discipline_id === null || r.discipline_id === cand?.discipline_id);

    // 2. Classify + locate artefact.
    const c = await classify(subject, body, attachments, reqs.map((r: any)=>r.code));

    // 3. Log the inbound message.
    await sb.from("messages").insert({
      candidate_id: candidateId, direction: "inbound", channel: "email",
      author: "candidate", subject, body: `${c.summary}\n\n${body.slice(0, 4000)}`,
      external_ref: from,
    });

    // Confirmation handshake: a short "yes I confirm" on a reference token, when
    // we're already awaiting confirmation, marks that reference confirmed.
    if (tok && purpose === "reference" && body.length < 600 &&
        /\b(yes|i can confirm|confirmed?|that'?s correct|i wrote|i completed)\b/i.test(body)) {
      const { data: item } = await sb.from("compliance_items")
        .select("id,extracted,human_notes").eq("candidate_id", candidateId).eq("requirement_id", tokenReqId)
        .order("created_at", { ascending: false }).limit(1).maybeSingle();
      if (item && (item.extracted as any)?.confirmation === "requested") {
        await sb.from("compliance_items").update({
          extracted: { ...(item.extracted as any), confirmation: "confirmed" },
          source_confidence: "high",
          human_notes: `${item.human_notes ? item.human_notes + " " : ""}Referee confirmed authorship via handshake.`,
        }).eq("id", item.id);
        return new Response(JSON.stringify({ ok: true, matched: true, type: "reference_confirmation", confirmed: true }), { headers: { "Content-Type": "application/json" } });
      }
    }

    if (c.type === "candidate_reply" || c.type === "noise") {
      return new Response(JSON.stringify({ ok: true, matched: true, type: c.type }), { headers: { "Content-Type": "application/json" } });
    }

    // 4. Ingest attachment(s) to private storage.
    let artefactPath: string | null = null;
    const idx = typeof c.attachment_index === "number" ? c.attachment_index : -1;
    const att = idx >= 0 ? attachments[idx] : null;
    if (att?.contentBase64) {
      const path = `${candidateId}/${Date.now()}-${(att.filename || "doc").replace(/[^\w.\-]/g, "_")}`;
      const { error } = await sb.storage.from(BUCKET).upload(path, b64ToBytes(att.contentBase64), {
        contentType: att.contentType || "application/octet-stream", upsert: false,
      });
      if (!error) artefactPath = path;
    }

    // Resolve which requirement this satisfies.
    const reqId = tokenReqId ?? reqs.find((r: any) => r.code === c.requirement_code)?.id ?? null;
    const reqRow = reqs.find((r: any) => r.id === reqId);

    // Confidence + human-gate: judgement items, free-webmail senders, or
    // references always go to a human; clear institutional docs are higher
    // confidence but still land as 'received' (acceptance is human, §7).
    const isReference = c.type === "reference" || purpose === "reference";
    const confidence = institutional && artefactPath ? "high" : institutional ? "medium" : "low";
    const needsHuman = isReference || !institutional || !!reqRow?.needs_human || confidence === "low";

    // Upsert onto an existing requested item if present, else create one.
    let itemId: string | null = null;
    if (reqId) {
      const { data: existing } = await sb.from("compliance_items")
        .select("id").eq("candidate_id", candidateId).eq("requirement_id", reqId)
        .in("status", ["requested","not_started","received","verifying"]).limit(1).maybeSingle();
      itemId = existing?.id ?? null;
    }
    const payload: any = {
      candidate_id: candidateId, requirement_id: reqId, status: "received",
      channel: att ? "pdf_attachment" : "email_body",
      source_confidence: confidence, received_at: new Date().toISOString(),
      extracted: { ...(c.extracted || {}), sender_domain: senderDomain, institutional, type: c.type },
      artefact_path: artefactPath, needs_human: needsHuman,
      human_notes: needsHuman ? `Inbound ${c.type} from ${senderDomain || "unknown"} — needs review. ${c.summary}` : null,
    };
    let finalItemId = itemId;
    if (itemId) {
      await sb.from("compliance_items").update(payload).eq("id", itemId);
    } else {
      const { data: ins } = await sb.from("compliance_items").insert(payload).select("id").maybeSingle();
      finalItemId = ins?.id ?? null;
    }

    // Confirmation handshake (send): for an institutional reference received via
    // token, email the referee to confirm authorship and mark it 'requested'.
    let confirmationRequested = false;
    if (isReference && tok && institutional && senderEmail && finalItemId && !(c.extracted?.confirmation)) {
      const r = await sendBrevoEmail({
        to: senderEmail,
        subject: "Please confirm your reference",
        html: emailHtml(`Thank you for the reference you've provided. For our records, could you simply reply "Yes, I can confirm" to verify that you completed it yourself?`),
        replyTo: replyToFor(tok),
      });
      if (r.ok) {
        await sb.from("compliance_items").update({ extracted: { ...payload.extracted, confirmation: "requested" } }).eq("id", finalItemId);
        confirmationRequested = true;
      }
    }

    return new Response(JSON.stringify({ ok: true, matched: true, type: c.type, requirement: c.requirement_code, confidence, needs_human: needsHuman, confirmation_requested: confirmationRequested }), { headers: { "Content-Type": "application/json" } });
  } catch (e) {
    return new Response(JSON.stringify({ error: String(e) }), { status: 500, headers: { "Content-Type": "application/json" } });
  }
});
