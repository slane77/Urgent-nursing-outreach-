// ============================================================================
//  Day Webster — Candidate Pipeline · training-authoring (Supabase Edge Function)
//
//  STATUS: DRAFT — NOT YET DEPLOYED. For review only. Deploying requires:
//    1. Migrations applied through candidate-pipeline/sql/52.
//    2. Secrets: ANTHROPIC_API_KEY (reused from compliance-import / compliance-chat).
//       Also uses the project-injected SUPABASE_URL + SUPABASE_ANON_KEY.
//    3. Deploy with **verify_jwt=true** — staff only (a compliance officer).
//
//  AI-ASSISTED DRAFTING (design §8). Reuses the compliance-import Anthropic stack
//  (claude-opus-4-8 + a structured json_schema response). Given a module and a
//  short authoring brief it returns a DRAFT knowledge-base + question bank and
//  persists it as a NEW draft module_version (ai_generated=true, ai_model=<model>)
//  via the SECURITY DEFINER RPCs save_module_version + add_training_question.
//
//  THE APPROVAL GATE IS UNTOUCHED. This function ONLY creates a draft. It never
//  submits, approves or publishes — a human officer reviews and a manager
//  approves + publishes (accreditation gate). Because content is accreditation-
//  bearing, nothing here can reach candidates without that human sign-off.
//
//  RUNS AS THE CALLER, NOT SERVICE ROLE (like compliance-chat). The data client
//  is built with the ANON key + the caller's forwarded JWT, so save_module_version
//  / add_training_question execute under the officer's auth.uid() and their
//  is_compliance_officer() gate + RLS apply. A bug here cannot forge content as a
//  role the caller does not hold.
//
//  DATA ISOLATION: the AI prompt is built from the module's SUBJECT/TITLE + the
//  operator's content brief ONLY. NO candidate data — no names, no assignments, no
//  compliance items — is ever read here or placed in the prompt.
// ============================================================================

import Anthropic from "npm:@anthropic-ai/sdk";
import { createClient } from "npm:@supabase/supabase-js";

const MODEL = "claude-opus-4-8";
const anthropic = new Anthropic({ apiKey: Deno.env.get("ANTHROPIC_API_KEY")! });

const ALLOWED_DOMAINS = [
  "@daywebster.com", "@daywebstergroup.com",
  "@homecare-providers.com", "@homecareproviders.co.uk",
];

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Content-Type": "application/json",
};

// ---- Auth: decode caller JWT, verify email domain (same as compliance-import) --
function emailFromJwt(req: Request): string | null {
  const auth = req.headers.get("Authorization") ?? "";
  const token = auth.replace(/^Bearer\s+/i, "");
  const part = token.split(".")[1];
  if (!part) return null;
  try {
    const json = JSON.parse(atob(part.replace(/-/g, "+").replace(/_/g, "/")));
    return (json.email ?? "").toLowerCase() || null;
  } catch {
    return null;
  }
}
function authorized(req: Request): boolean {
  const email = emailFromJwt(req);
  return !!email && ALLOWED_DOMAINS.some((d) => email.endsWith(d));
}

// ---- Ask Claude to draft the KB + question bank for a module's subject --------
// The prompt carries ONLY the subject/title/framework + the operator brief +
// how many questions the bank needs. Never any candidate data.
async function draftContent(
  subject: string, title: string, framework: string | null,
  brief: string, questionCount: number,
) {
  // Bank should comfortably exceed question_count so retakes re-randomise (AS3).
  const wantQuestions = Math.max(questionCount * 2, questionCount + 5);
  const resp = await anthropic.messages.create({
    model: MODEL,
    max_tokens: 8192,
    output_config: {
      effort: "high",
      format: {
        type: "json_schema",
        schema: {
          type: "object",
          properties: {
            content: {
              type: "array",
              items: {
                type: "object",
                properties: {
                  heading: { type: "string" },
                  body_md: { type: "string" },
                },
                required: ["heading", "body_md"],
                additionalProperties: false,
              },
            },
            questions: {
              type: "array",
              items: {
                type: "object",
                properties: {
                  stem: { type: "string" },
                  options: {
                    type: "array",
                    items: {
                      type: "object",
                      properties: {
                        key: { type: "string" },
                        text: { type: "string" },
                      },
                      required: ["key", "text"],
                      additionalProperties: false,
                    },
                  },
                  correct_keys: { type: "array", items: { type: "string" } },
                  explanation: { type: "string" },
                },
                required: ["stem", "options", "correct_keys", "explanation"],
                additionalProperties: false,
              },
            },
          },
          required: ["content", "questions"],
          additionalProperties: false,
        },
      },
    },
    system:
      "You are a UK healthcare mandatory-training author drafting accreditation-bearing " +
      "learning content for agency clinical/care staff. Write accurate, UK-context, plain-English " +
      "material aligned to CSTF / Skills for Health norms. Produce:\n" +
      "  content: 5-8 knowledge-base sections, each {heading, body_md} (body_md is short Markdown);\n" +
      `  questions: exactly ${wantQuestions} single-best-answer or select-all multiple-choice ` +
      "questions, each with 4 options keyed 'a'..'d', a non-empty correct_keys array of the correct " +
      "option keys (one key for single-answer, several for select-all), and a one-sentence explanation.\n" +
      "Every question must be answerable from the knowledge base you write. This is a DRAFT for human " +
      "review and approval; do not claim it is accredited. Do not invent statistics or named individuals.",
    messages: [{
      role: "user",
      content:
        `Module title: ${title}\n` +
        `Subject: ${subject}${framework ? `\nFramework: ${framework}` : ""}\n\n` +
        `Authoring brief from the compliance officer:\n${brief || "(no extra brief — use standard CSTF-level scope)"}`,
    }],
  });
  const text = resp.content.filter((b: any) => b.type === "text").map((b: any) => b.text).join("");
  return JSON.parse(text) as {
    content: { heading: string; body_md: string }[];
    questions: { stem: string; options: { key: string; text: string }[]; correct_keys: string[]; explanation: string }[];
  };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (!authorized(req)) {
    return new Response(JSON.stringify({ error: "unauthorized" }), { status: 401, headers: CORS });
  }

  try {
    const body = await req.json();
    const module_id = body?.module_id;
    const brief = (body?.brief ?? "").toString();
    if (typeof module_id !== "string" || !module_id) {
      return new Response(JSON.stringify({ error: "module_id is required" }), { status: 400, headers: CORS });
    }

    // Caller-JWT data client: writes run under the officer's auth.uid() so the RPC
    // is_compliance_officer() gate + RLS decide access (never this code).
    const sb = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { db: { schema: "candidate" }, global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } },
    );

    // Read ONLY the module's content metadata for the prompt (no candidate data).
    const { data: mod, error: modErr } = await sb
      .from("training_modules")
      .select("title, framework, framework_subject, question_count")
      .eq("id", module_id)
      .maybeSingle();
    if (modErr) return new Response(JSON.stringify({ error: modErr.message }), { status: 403, headers: CORS });
    if (!mod) return new Response(JSON.stringify({ error: "module not found" }), { status: 404, headers: CORS });

    const draft = await draftContent(
      mod.framework_subject ?? mod.title, mod.title, mod.framework ?? null,
      brief, mod.question_count ?? 10,
    );

    // Persist as a NEW draft module_version (ai_generated=true, ai_model=<model>).
    const { data: versionId, error: verErr } = await sb.rpc("save_module_version", {
      p_module_id: module_id,
      p_content: draft.content,
      p_version_id: null,
      p_ai_generated: true,
      p_ai_model: MODEL,
    });
    if (verErr || !versionId) {
      return new Response(JSON.stringify({ error: verErr?.message ?? "could not create draft version" }),
        { status: 403, headers: CORS });
    }

    // Add each question through the RPC (the table has no direct write path).
    let added = 0;
    const skipped: string[] = [];
    for (let i = 0; i < draft.questions.length; i++) {
      const q = draft.questions[i];
      if (!q?.stem || !Array.isArray(q.options) || !Array.isArray(q.correct_keys) || q.correct_keys.length === 0) {
        skipped.push(q?.stem ?? `#${i + 1}`);
        continue;
      }
      const { error: qErr } = await sb.rpc("add_training_question", {
        p_version_id: versionId,
        p_stem: q.stem,
        p_options: q.options,
        p_correct_keys: q.correct_keys,
        p_explanation: q.explanation ?? null,
        p_sort_order: (i + 1) * 10,
      });
      if (qErr) skipped.push(q.stem);
      else added++;
    }

    return new Response(JSON.stringify({
      version_id: versionId,
      ai_model: MODEL,
      content_sections: draft.content.length,
      questions_added: added,
      questions_skipped: skipped.length,
      note: "Draft created for human review. An officer reviews and a manager approves + publishes; " +
        "nothing here has been published or served to candidates.",
    }), { headers: CORS });
  } catch (e) {
    return new Response(JSON.stringify({ error: String(e) }), { status: 500, headers: CORS });
  }
});
