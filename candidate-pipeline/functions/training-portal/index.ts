// ============================================================================
//  Day Webster — Candidate Pipeline · training-portal (Supabase Edge Function)
//
//  STATUS: DRAFT — NOT YET DEPLOYED. For review only. Deploying requires:
//    1. Migrations applied through candidate-pipeline/sql/52 (47–52 = the
//       Mandatory-Training engine: catalogue, versions/RPCs, delivery RPCs,
//       records/certs, manual entry, seed).
//    2. A PRIVATE storage bucket `training-certs` (EU/UK region).
//    3. Deploy with **verify_jwt=false** — the candidate has NO account and sends
//       NO Authorization header. The opaque, hashed, single-use magic-link / short
//       session token IS the credential; this function is the trust boundary.
//
//  THE PASSWORDLESS CANDIDATE DELIVERY LAYER (design §4). Mirrors the
//  function-as-trust-boundary model: the candidate holds only an opaque token and
//  talks solely to this function, which runs as the SERVICE ROLE and forwards each
//  action to a SECURITY DEFINER RPC scoped to that token's candidate/assignment.
//  The tables are default-deny to the world; the candidate never touches Postgres.
//
//  THE ASSESSMENT INVARIANT: the correct-answer key NEVER reaches the browser.
//  start_training_attempt (sql/49) serves questions with correct_keys +
//  explanation stripped IN SQL; submit_training_attempt grades server-side. This
//  function never selects, logs or returns correct_keys — on a fail it may name
//  which question ids were wrong, never the answers.
//
//  TOKEN MODEL (raw -> hash split; symmetric for BOTH tokens):
//   * The MAGIC-LINK token is minted by assign_training (sql/49) which returns the
//     RAW token once and stores only sha256(raw). Here `consume` hashes the raw
//     token the candidate presents and passes the HASH to consume_training_link.
//   * The SESSION token is minted by consume_training_link, which stores only
//     sha256(raw) and returns the RAW token (`session_token`). We hand the raw
//     token to the client and, on every start/submit/status call, hash it again
//     before the lookup. So neither token is ever stored in the clear — a DB-read
//     compromise cannot replay an in-flight session.
//
//  Modes (POST JSON, no Authorization header):
//    consume {token}                         -> { session_token, module, content }
//    start   {session_token}                 -> { attempt_id, questions[] }  (keyless)
//    submit  {session_token, attempt_id,     -> pass: { passed, score, certificate_id, cert_url }
//             answers}                            fail: { passed:false, score, retake_allowed, wrong_ids? }
//    status  {session_token}                 -> { assignment_status, module, last_score?, passed? }
//
//  Fail-closed + no enumeration: every failure returns a GENERIC error with a
//  stable status (401 for a bad/expired token or session, 400 for a malformed
//  request, 429 when rate-limited, 500 otherwise). We never echo which of token /
//  session / attempt was wrong.
// ============================================================================

import { createClient } from "npm:@supabase/supabase-js";
import { renderCertificateHtml } from "../_shared/cert.ts";

const CERT_BUCKET = "training-certs";
const SIGNED_TTL = 300; // 300s signed URL (design §5 — PII-bearing, short-lived)

// Service-role client: this function is the trust boundary, tables are default-
// deny to the world, and every RPC it calls is itself token-scoped in SQL.
const sb = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { db: { schema: "candidate" }, auth: { persistSession: false } },
);

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: CORS });
}
// One generic shape for EVERY failure path (no enumeration / no key leak).
function fail(status = 401): Response {
  return json({ error: "invalid_request" }, status);
}

// ── sha256 hex (Web Crypto; matches the DB's encode(digest(x,'sha256'),'hex')) ──
async function sha256hex(raw: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(raw));
  return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

// ── Best-effort rate limit (per-isolate sliding window keyed by ip+mode+token) ──
// Not a hard guarantee across isolates, but it blunts brute-force / enumeration
// from a single source and is free. The real integrity boundary is the hashed,
// single-use, short-TTL tokens + the SECURITY DEFINER RPCs.
const WINDOW_MS = 60_000;
const MAX_HITS = 30;
const hits = new Map<string, number[]>();
function rateLimited(key: string): boolean {
  const now = Date.now();
  const arr = (hits.get(key) ?? []).filter((t) => now - t < WINDOW_MS);
  arr.push(now);
  hits.set(key, arr);
  if (hits.size > 5000) { // bound memory
    for (const [k, v] of hits) { if (v.every((t) => now - t >= WINDOW_MS)) hits.delete(k); }
  }
  return arr.length > MAX_HITS;
}
function clientIp(req: Request): string {
  return (req.headers.get("x-forwarded-for") ?? "").split(",")[0].trim() ||
    req.headers.get("cf-connecting-ip") || "unknown";
}

// ── consume: raw magic-link token -> session + KB content ────────────────────
async function doConsume(token: unknown) {
  if (typeof token !== "string" || token.length < 16) return fail();
  const hash = await sha256hex(token);
  const { data, error } = await sb.rpc("consume_training_link", { p_token_hash: hash });
  if (error || !data || !(data as any).session_token) return fail(); // generic
  const d = data as any;
  return json({
    session_token: d.session_token,          // RAW session token; the DB stored only its sha256
    module: {
      title: d.module?.title ?? null,
      framework: d.module?.framework ?? null,
      framework_subject: d.module?.framework_subject ?? null,
      question_count: d.module?.question_count ?? null,
      pass_threshold: d.module?.pass_threshold ?? null,
    },
    content: d.content ?? [],
  });
}

// ── start: session -> a fresh, keyless attempt ───────────────────────────────
async function doStart(session_token: unknown) {
  if (typeof session_token !== "string" || session_token.length < 16) return fail();
  const { data, error } = await sb.rpc("start_training_attempt", { p_session_hash: await sha256hex(session_token) });
  if (error || !data || !(data as any).attempt_id) return fail();
  const d = data as any;
  // d.questions is already keyless (id/stem/options only) from the RPC. We do NOT
  // enrich it — no correct_keys, no explanation ever leaves this function.
  return json({ attempt_id: d.attempt_id, questions: d.questions ?? [] });
}

// ── submit: grade server-side; on pass render + store + sign the certificate ──
async function doSubmit(session_token: unknown, attempt_id: unknown, answers: unknown) {
  if (typeof session_token !== "string" || session_token.length < 16) return fail();
  if (typeof attempt_id !== "string") return fail();
  if (answers === null || typeof answers !== "object" || Array.isArray(answers)) return fail(400);

  const { data, error } = await sb.rpc("submit_training_attempt", {
    p_session_hash: await sha256hex(session_token),
    p_attempt_id: attempt_id,
    p_answers: answers,
  });
  if (error || !data) return fail();
  const d = data as any; // { passed, score, certificate_id }

  if (!d.passed) {
    // Reveal only that it was not a pass + the score. NEVER the correct answers.
    return json({ passed: false, score: d.score ?? null, retake_allowed: true });
  }

  const certificate_id: string | null = d.certificate_id ?? null;
  let cert_url: string | null = null;

  // Render + store the branded HTML certificate, then hand back a short-lived
  // signed URL. A rendering/upload hiccup must NOT flip a genuine pass to a fail,
  // so it is caught and reported as passed-without-download (retryable via status).
  if (certificate_id) {
    try {
      const { data: rec } = await sb
        .from("training_records")
        .select("candidate_id, module_id, completion_date, expiry_date")
        .eq("certificate_id", certificate_id)
        .maybeSingle();
      if (rec) {
        const [{ data: cand }, { data: mod }] = await Promise.all([
          sb.from("candidates").select("first_name, last_name").eq("id", rec.candidate_id).maybeSingle(),
          sb.from("training_modules")
            .select("title, framework, framework_subject, sfh_accreditation_ref")
            .eq("id", rec.module_id).maybeSingle(),
        ]);
        const html = renderCertificateHtml({
          candidate_name: `${cand?.first_name ?? ""} ${cand?.last_name ?? ""}`.trim() || "Candidate",
          module_title: mod?.title ?? "Mandatory training",
          framework: mod?.framework ?? null,
          framework_subject: mod?.framework_subject ?? null,
          sfh_accreditation_ref: mod?.sfh_accreditation_ref ?? null,
          completion_date: rec.completion_date,
          expiry_date: rec.expiry_date,
          certificate_id,
        });
        const path = `${rec.candidate_id}/${certificate_id}.html`;
        const up = await sb.storage.from(CERT_BUCKET).upload(
          path, new Blob([html], { type: "text/html" }), { upsert: true, contentType: "text/html" },
        );
        if (!up.error) {
          await sb.from("training_records").update({ certificate_path: path }).eq("certificate_id", certificate_id);
          const signed = await sb.storage.from(CERT_BUCKET).createSignedUrl(path, SIGNED_TTL);
          cert_url = signed.data?.signedUrl ?? null;
        }
      }
    } catch (_e) {
      cert_url = null; // pass still stands; certificate can be re-fetched later
    }
  }

  return json({ passed: true, score: d.score ?? null, certificate_id, cert_url });
}

// ── status: progress for the current session (service-role, session-scoped) ──
// No Round-1 RPC covers this, so we read directly under the service role but
// STRICTLY scope every read to the session's own candidate/assignment.
async function doStatus(session_token: unknown) {
  if (typeof session_token !== "string" || session_token.length < 16) return fail();
  const { data: session } = await sb
    .from("training_sessions")
    .select("assignment_id, candidate_id, expires_at")
    .eq("token_hash", await sha256hex(session_token))
    .maybeSingle();
  if (!session || new Date(session.expires_at).getTime() < Date.now()) return fail();

  const { data: asg } = await sb
    .from("training_assignments")
    .select("status, module_id")
    .eq("id", session.assignment_id)
    .eq("candidate_id", session.candidate_id)
    .maybeSingle();
  if (!asg) return fail();

  const [{ data: mod }, { data: attempts }] = await Promise.all([
    sb.from("training_modules").select("title, framework_subject, question_count").eq("id", asg.module_id).maybeSingle(),
    sb.from("training_attempts")
      .select("score, passed, submitted_at")
      .eq("assignment_id", session.assignment_id)
      .eq("candidate_id", session.candidate_id)
      .not("submitted_at", "is", null)
      .order("submitted_at", { ascending: false })
      .limit(1),
  ]);
  const last = (attempts ?? [])[0];
  return json({
    assignment_status: asg.status,
    module: { title: mod?.title ?? null, framework_subject: mod?.framework_subject ?? null,
      question_count: mod?.question_count ?? null },
    last_score: last?.score ?? null,
    passed: last?.passed ?? null,
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return fail(405);

  let body: any;
  try { body = await req.json(); } catch { return fail(400); }
  const mode = body?.mode;

  // Rate limit per (ip, mode, token-ish) — generic 429, no enumeration.
  const idTok = (body?.token ?? body?.session_token ?? "").toString().slice(0, 24);
  if (rateLimited(`${clientIp(req)}|${mode}|${idTok}`)) return fail(429);

  try {
    switch (mode) {
      case "consume": return await doConsume(body.token);
      case "start":   return await doStart(body.session_token);
      case "submit":  return await doSubmit(body.session_token, body.attempt_id, body.answers);
      case "status":  return await doStatus(body.session_token);
      default:        return fail(400);
    }
  } catch (_e) {
    return fail(500); // generic — never leak internals to an unauthenticated caller
  }
});
