// ============================================================================
//  Day Webster — Candidate Pipeline · candidate-agent (Supabase Edge Function)
//
//  STATUS: DRAFT — NOT YET DEPLOYED. For review only. Deploying requires:
//    1. The `candidate` schema applied (candidate-pipeline/sql/10–12).
//    2. Secrets set:  ANTHROPIC_API_KEY  (and the function uses the project's
//       SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY, injected by Supabase).
//    3. §11 DATA-PROTECTION GATE confirmed before processing REAL candidate
//       PII through an LLM: Anthropic API does not train on API data by
//       default and offers a DPA / zero-data-retention terms — confirm and
//       record those terms first. Until then, run only on synthetic data.
//
//  WHAT IT DOES (the autonomous-to-a-line recruiter agent):
//    Given a candidate_id and an inbound message, it loads the candidate's
//    context from the isolated `candidate` schema, runs Claude as a recruiter
//    that ENGAGES -> QUALIFIES -> REQUESTS initial compliance, and writes
//    structured results back via tools. It NEVER decides compliance
//    acceptance or marks a candidate work-ready — that is human-gated (Tier H
//    / §7 of the compliance assessment). Ambiguous cases are flagged for a
//    human via the review queue.
//
//  ISOLATION: touches ONLY the `candidate` schema. The client/employer
//  outreach tables in `public` are never read or written here.
// ============================================================================

import Anthropic from "npm:@anthropic-ai/sdk";
import { createClient } from "npm:@supabase/supabase-js";
import { sendBrevoEmail, emailHtml } from "../_shared/email.ts";

const MODEL = "claude-opus-4-8";

const anthropic = new Anthropic({ apiKey: Deno.env.get("ANTHROPIC_API_KEY")! });

// Service-role client scoped to the candidate schema. RLS is bypassed by the
// service role, so this function is the trust boundary — keep it server-side.
const sb = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { db: { schema: "candidate" } },
);

// ---- Tools the agent can call (each maps to an isolated, audited DB write) --
const tools: Anthropic.Tool[] = [
  {
    name: "update_candidate_profile",
    description:
      "Record or correct qualification facts the candidate has given. Use the discipline/specialty CODES from the provided taxonomy. registration_number is STORED ONLY — never assert it is valid; verification is a separate human/authoritative step.",
    input_schema: {
      type: "object",
      properties: {
        discipline_code: { type: "string" },
        specialty_code: { type: "string" },
        right_to_work_status: {
          type: "string",
          enum: ["uk_citizen", "settled", "pre_settled", "visa", "unconfirmed", "no"],
        },
        registration_body: { type: "string", description: "NMC / GMC / HCPC / none" },
        registration_number: { type: "string" },
        availability: { type: "string" },
        town: { type: "string" },
        postcode: { type: "string" },
        shift_prefs: { type: "object", additionalProperties: true },
      },
      additionalProperties: false,
    },
  },
  {
    name: "record_employment",
    description:
      "Add an employment-history entry the candidate mentions. Feeds the >=3-year reference-coverage / CV reconciliation. Leave end_date null for current roles.",
    input_schema: {
      type: "object",
      properties: {
        employer: { type: "string" },
        job_title: { type: "string" },
        start_date: { type: "string", description: "ISO date or best-effort YYYY-MM" },
        end_date: { type: "string" },
      },
      required: ["employer"],
      additionalProperties: false,
    },
  },
  {
    name: "set_pipeline_status",
    description:
      "Advance the candidate's stage. You may set up to 'compliance'. You must NOT set 'ready'/'placed' — those are human-gated.",
    input_schema: {
      type: "object",
      properties: {
        status: {
          type: "string",
          enum: ["contacted", "engaged", "qualified", "compliance"],
        },
      },
      required: ["status"],
      additionalProperties: false,
    },
  },
  {
    name: "request_compliance_items",
    description:
      "Open compliance requirements for this candidate as 'requested' (e.g. references, proof_of_address, dbs). Requesting documents is allowed autonomously; DECIDING whether a returned document is acceptable is NOT — that is human-gated.",
    input_schema: {
      type: "object",
      properties: {
        requirement_codes: { type: "array", items: { type: "string" } },
      },
      required: ["requirement_codes"],
      additionalProperties: false,
    },
  },
  {
    name: "flag_for_human",
    description:
      "Route to the human review queue for anything high-stakes or ambiguous: adverse safeguarding disclosure, suspected mismatch, registration/right-to-work doubt, or any acceptance decision. Always prefer flagging over guessing.",
    input_schema: {
      type: "object",
      properties: { reason: { type: "string" } },
      required: ["reason"],
      additionalProperties: false,
    },
  },
  {
    name: "record_consent",
    description:
      "Record that the candidate has given (or withdrawn) consent to be contacted/processed for recruitment. Capture this before substantive engagement.",
    input_schema: {
      type: "object",
      properties: {
        purpose: { type: "string", enum: ["recruitment", "marketing", "data_storage"] },
        granted: { type: "boolean" },
        evidence: { type: "string" },
      },
      required: ["purpose", "granted"],
      additionalProperties: false,
    },
  },
];

async function executeTool(candidateId: string, name: string, input: any): Promise<string> {
  switch (name) {
    case "update_candidate_profile": {
      const patch: Record<string, unknown> = {};
      if (input.right_to_work_status) patch.right_to_work_status = input.right_to_work_status;
      if (input.registration_body) patch.registration_body = input.registration_body;
      if (input.registration_number) patch.registration_number = input.registration_number;
      if (input.availability) patch.availability = input.availability;
      if (input.town) patch.town = input.town;
      if (input.postcode) patch.postcode = input.postcode;
      if (input.shift_prefs) patch.shift_prefs = input.shift_prefs;
      if (input.discipline_code) {
        const { data } = await sb.from("disciplines").select("id").eq("code", input.discipline_code).maybeSingle();
        if (data) patch.discipline_id = data.id;
      }
      if (input.specialty_code) {
        const { data } = await sb.from("specialties").select("id").eq("code", input.specialty_code).maybeSingle();
        if (data) patch.primary_specialty_id = data.id;
      }
      const { error } = await sb.from("candidates").update(patch).eq("id", candidateId);
      return error ? `error: ${error.message}` : "profile updated";
    }
    case "record_employment": {
      const { error } = await sb.from("employment").insert({
        candidate_id: candidateId,
        employer: input.employer,
        job_title: input.job_title ?? null,
        start_date: input.start_date ?? null,
        end_date: input.end_date ?? null,
        source: "self",
      });
      return error ? `error: ${error.message}` : "employment recorded";
    }
    case "set_pipeline_status": {
      const { error } = await sb.from("candidates").update({ status: input.status }).eq("id", candidateId);
      return error ? `error: ${error.message}` : `status set to ${input.status}`;
    }
    case "request_compliance_items": {
      const opened: string[] = [];
      for (const code of input.requirement_codes as string[]) {
        const { data: req } = await sb.from("compliance_requirements").select("id").eq("code", code).limit(1).maybeSingle();
        const { error } = await sb.from("compliance_items").insert({
          candidate_id: candidateId,
          requirement_id: req?.id ?? null,
          status: "requested",
        });
        if (!error) opened.push(code);
      }
      return `requested: ${opened.join(", ") || "none"}`;
    }
    case "flag_for_human": {
      // Attach a flagged review-queue item so a human picks it up.
      const { error } = await sb.from("compliance_items").insert({
        candidate_id: candidateId,
        status: "verifying",
        needs_human: true,
        human_notes: input.reason,
      });
      return error ? `error: ${error.message}` : "flagged for human review";
    }
    case "record_consent": {
      const { error } = await sb.from("consent").insert({
        candidate_id: candidateId,
        purpose: input.purpose,
        granted: input.granted,
        evidence: input.evidence ?? "captured via agent conversation",
      });
      return error ? `error: ${error.message}` : "consent recorded";
    }
    default:
      return `unknown tool: ${name}`;
  }
}

function systemPrompt(ctx: any): string {
  return `You are Day Webster's AI recruiter agent. Your job: ENGAGE a prospective candidate, QUALIFY them, and BEGIN compliance intake — autonomously, but only up to a line.

AUTONOMY LINE (hard rules):
- You MAY: hold the conversation, capture consent, establish discipline/specialty/location/availability/right-to-work and registration number, record employment history, advance the pipeline up to "compliance", and REQUEST compliance documents.
- You MUST NOT: decide whether any document/reference is genuine or acceptable, assert that a registration (NMC/GMC/HCPC) is valid, or mark anyone work-ready. Those are human decisions.
- ALWAYS use flag_for_human for: any adverse safeguarding answer, a suspected identity/data mismatch, doubt over right-to-work or registration, or any acceptance judgement. When unsure, flag rather than guess.

CONDUCT:
- Capture consent (record_consent) before substantive data-gathering. Individuals require consent — be explicit and respectful.
- Multi-discipline: this candidate could be nursing, doctor, complex care, AHP, insurance (John Williams), children's services, or care home staff/registered manager. Identify which and use the correct taxonomy codes.
- Use the tools to persist what you learn as you go; don't just chat.
- Be warm, concise, professional. UK English. One clear ask at a time.
- Your final text message in each turn is the reply that will be sent to the candidate. Do not include internal notes in it.

AVAILABLE TAXONOMY (discipline_code -> [specialty_code]):
${ctx.taxonomy}

COMPLIANCE REQUIREMENTS FOR THIS CANDIDATE (request the required ones with request_compliance_items, using these exact codes, once you have established their discipline):
${ctx.requirements}
- You may REQUEST any of these. Items marked [human-decided] you request but never accept/verify — flag_for_human handles the decision.

CURRENT CANDIDATE STATE:
${ctx.state}`;
}

Deno.serve(async (req) => {
  try {
    const { candidate_id, inbound_message, channel = "web", no_send = false } = await req.json();
    if (!candidate_id) return new Response(JSON.stringify({ error: "candidate_id required" }), { status: 400 });

    // --- Load context (taxonomy, candidate, recent transcript) ---
    const [{ data: disciplines }, { data: specialties }, { data: cand }, { data: history }, { data: allReqs }] = await Promise.all([
      sb.from("disciplines").select("code,name").eq("active", true),
      sb.from("specialties").select("code,name,discipline_id,is_registered_manager"),
      sb.from("candidates").select("*").eq("id", candidate_id).maybeSingle(),
      sb.from("messages").select("direction,body,author").eq("candidate_id", candidate_id).order("created_at").limit(30),
      sb.from("compliance_requirements").select("code,name,required,needs_human,discipline_id").eq("active", true),
    ]);
    if (!cand) return new Response(JSON.stringify({ error: "candidate not found" }), { status: 404 });

    // Requirements that apply to this candidate: global (null discipline) + their discipline's.
    const reqs = (allReqs ?? []).filter((r: any) => r.discipline_id === null || r.discipline_id === cand.discipline_id);
    const requirements = reqs.length
      ? reqs.map((r: any) => `${r.code} — ${r.name}${r.required ? " (required)" : " (optional)"}${r.needs_human ? " [human-decided]" : ""}`).join("\n")
      : "(no requirements configured for this discipline yet — qualify first, then a human will set them)";

    const taxonomy = (disciplines ?? [])
      .map((d: any) => `${d.code} (${d.name}): ${(specialties ?? []).filter((s: any) => s.discipline_id).map((s: any) => s.code).join(", ")}`)
      .join("\n");
    const ctx = {
      taxonomy,
      requirements,
      state: JSON.stringify({
        status: cand.status,
        discipline_id: cand.discipline_id,
        right_to_work_status: cand.right_to_work_status,
        registration_body: cand.registration_body,
        availability: cand.availability,
      }),
    };

    // Log the inbound turn (if any).
    if (inbound_message) {
      await sb.from("messages").insert({
        candidate_id, direction: "inbound", channel,
        body: inbound_message, author: "candidate",
      });
    }

    const messages: Anthropic.MessageParam[] = (history ?? []).map((m: any) => ({
      role: m.direction === "inbound" ? "user" : "assistant",
      content: m.body ?? "",
    }));
    if (inbound_message) messages.push({ role: "user", content: inbound_message });
    if (messages.length === 0) messages.push({ role: "user", content: "[New candidate — open the conversation: greet, capture consent, and begin qualifying.]" });

    // --- Manual agentic loop: keep going while Claude calls tools ---
    let reply = "";
    for (let i = 0; i < 6; i++) {
      const resp = await anthropic.messages.create({
        model: MODEL,
        max_tokens: 4096,
        thinking: { type: "adaptive" },
        output_config: { effort: "medium" }, // tune: 'high' for harder qualification judgement
        system: systemPrompt(ctx),
        tools,
        messages,
      });

      messages.push({ role: "assistant", content: resp.content });

      if (resp.stop_reason !== "tool_use") {
        reply = resp.content.filter((b) => b.type === "text").map((b: any) => b.text).join("\n").trim();
        break;
      }

      const toolResults: Anthropic.ToolResultBlockParam[] = [];
      for (const block of resp.content) {
        if (block.type === "tool_use") {
          const result = await executeTool(candidate_id, block.name, block.input);
          toolResults.push({ type: "tool_result", tool_use_id: block.id, content: result });
        }
      }
      messages.push({ role: "user", content: toolResults });
    }

    // Send the agent's reply to the candidate by email (replies route back via
    // inbound-email, matched by the candidate's address). Falls back to a draft
    // if sending is disabled, the candidate has no email, or Brevo isn't set up.
    let sendStatus = "draft", sendId: string | undefined, sent = false;
    if (reply && !no_send && cand.email) {
      const r = await sendBrevoEmail({
        to: cand.email, toName: [cand.first_name, cand.last_name].filter(Boolean).join(" "),
        subject: "Day Webster — your registration", html: emailHtml(reply),
      });
      sent = r.ok; sendStatus = r.ok ? "sent" : "draft"; sendId = r.id;
    }
    if (reply) {
      await sb.from("messages").insert({
        candidate_id, direction: "outbound", channel: sent ? "email" : channel,
        body: reply, author: "agent", llm_generated: true, status: sendStatus, external_ref: sendId ?? null,
      });
    }

    return new Response(JSON.stringify({ reply, sent }), { headers: { "Content-Type": "application/json" } });
  } catch (e) {
    return new Response(JSON.stringify({ error: String(e) }), { status: 500 });
  }
});
