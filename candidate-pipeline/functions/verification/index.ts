// ============================================================================
//  Day Webster — Candidate Pipeline · verification (Supabase Edge Function)
//
//  STATUS: DRAFT — NOT YET DEPLOYED. For review only.
//
//  The provider/adapter WORKER over the fail-closed compliance gate (Phase 2).
//  One dispatcher, three modes:
//    · mode=check  — verify ONE candidate+requirement now (officer "Verify now"
//                    or an automation token): enqueue -> claim -> adapter ->
//                    apply/fail -> return the fresh work-ready status.
//    · mode=drain  — cron (~10 min): per active provider, claim <= max_concurrency
//                    queued jobs and process them.
//    · mode=sweep  — cron (daily): enqueue due annual/expiry re-checks, purge
//                    stale raw responses, return the dashboard counts.
//
//  FAIL-CLOSED: the worker reaches the DB ONLY through the SECURITY DEFINER RPCs.
//  It NEVER writes a status directly, and the dispatcher downgrades ANY
//  matchConfidence !== 'exact' verified result to needs_human — so no adapter can
//  auto-pass an ambiguous match, and there is no path from a provider error to
//  'verified'. Adapter attribution: a "Verify now" enqueue is run under the
//  officer's JWT (actor = the officer); claim/apply run as service (actor_kind
//  'service') — a complete, immutable request->result audit pair.
//
//  AUTH: drain/sweep require ?secret=CRON_SECRET (like early-warnings). check
//  accepts an officer JWT OR Bearer VERIFICATION_TOKEN. verify_jwt=false at
//  deploy. ISOLATION: the `candidate` schema only.
// ============================================================================

import { createClient } from "npm:@supabase/supabase-js";
import { resolveAdapter } from "./adapters/registry.ts";
import type { AdapterProvider, VerificationResult } from "./adapters/types.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;

// Service-role client — reaches the fail-closed definer RPCs.
const sb = createClient(SUPABASE_URL, SERVICE_KEY, { db: { schema: "candidate" }, auth: { persistSession: false } });

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Content-Type": "application/json",
};
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: CORS });

// A claimed job joined to its provider config (claim_provider_jobs row shape).
interface ClaimedJob {
  job_id: string;
  candidate_id: string;
  requirement_id: string | null;
  item_id: string | null;
  requirement_code: string | null;
  trigger: string;
  attempts: number;
  max_attempts: number;
  provider_key: string;
  provider_kind: AdapterProvider["kind"];
  regulator: string | null;
  endpoint: string | null;
  config: Record<string, unknown> | null;
}

// Run one claimed job through its adapter and write the result via the RPCs.
// Returns the EFFECTIVE outcome after the central no-auto-pass guard.
async function processJob(c: ClaimedJob): Promise<string> {
  const provider: AdapterProvider = {
    key: c.provider_key,
    kind: c.provider_kind,
    regulator: c.regulator,
    endpoint: c.endpoint,
    config: (c.config ?? {}) as AdapterProvider["config"],
  };
  const adapter = resolveAdapter(c.provider_key, provider);

  let result: VerificationResult;
  try {
    result = await adapter.run({
      jobId: c.job_id, candidateId: c.candidate_id, requirementId: c.requirement_id,
      itemId: c.item_id, requirementCode: c.requirement_code, trigger: c.trigger,
      attempts: c.attempts, maxAttempts: c.max_attempts,
    }, provider);
  } catch (e) {
    result = { outcome: "error", matchConfidence: "none", retryable: true, notes: `adapter threw: ${String(e)}` };
  }

  // CENTRAL fail-closed guard: never auto-pass a non-exact match.
  let outcome = result.outcome;
  if (outcome === "verified" && result.matchConfidence !== "exact") outcome = "needs_human";

  if (outcome === "error") {
    await sb.rpc("fail_provider_job", {
      p_job_id: c.job_id,
      p_error: result.notes ?? "adapter error",
      p_retryable: result.retryable !== false,
      p_response: result.raw ?? null,
    });
    return "error";
  }

  await sb.rpc("apply_verification_result", {
    p_job_id: c.job_id,
    p_outcome: outcome,
    p_expires_at: result.expiresAt ?? null,
    p_source_ref: result.sourceRef ?? null,
    p_registration_number: result.registrationNumber ?? null,
    p_response: result.raw ?? null,
    p_notes: result.notes ?? null,
  });
  return outcome;
}

// Resolve a set_code -> latest active set_id (for the work-ready return in check).
async function resolveSetId(setId: string | null, setCode: string | null): Promise<string | null> {
  if (setId) return setId;
  if (!setCode) return null;
  const { data } = await sb.from("requirement_sets")
    .select("id").eq("code", setCode).eq("status", "active")
    .order("version", { ascending: false }).limit(1).maybeSingle();
  return data?.id ?? null;
}

// ── mode=check ───────────────────────────────────────────────────────────────
async function handleCheck(req: Request): Promise<Response> {
  const bearer = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  const vtoken = Deno.env.get("VERIFICATION_TOKEN");

  // Choose the enqueue client so the REQUEST event is attributed correctly:
  //  · automation (Bearer VERIFICATION_TOKEN) -> service client (actor_kind service)
  //  · an officer JWT                         -> user client (actor = the officer)
  let enqClient = sb;
  if (vtoken && bearer === vtoken) {
    enqClient = sb;
  } else if (bearer) {
    enqClient = createClient(SUPABASE_URL, ANON_KEY, {
      db: { schema: "candidate" }, auth: { persistSession: false },
      global: { headers: { Authorization: `Bearer ${bearer}` } },
    });
  } else {
    return json({ error: "unauthorized" }, 401);
  }

  const b = await req.json().catch(() => ({}));
  const candidateId = (b.candidate_id ?? "").toString().trim();
  const requirementCode = (b.requirement_code ?? "").toString().trim();
  const trigger = (b.trigger ?? "manual").toString().trim();
  const setId = (b.set_id ?? "").toString().trim() || null;
  const setCode = (b.set_code ?? "").toString().trim() || null;
  if (!candidateId || !requirementCode) {
    return json({ error: "candidate_id and requirement_code are required" }, 400);
  }

  // Enqueue (idempotent). Authorization is enforced inside the definer RPC.
  const { data: jobId, error: enqErr } = await enqClient.rpc("enqueue_verification", {
    p_candidate_id: candidateId, p_requirement_code: requirementCode, p_trigger: trigger,
  });
  if (enqErr) {
    const status = /not authorized/i.test(enqErr.message) ? 403 : 400;
    return json({ error: enqErr.message }, status);
  }

  // Find the provider for this job, then claim + process it.
  let processed: string | null = null;
  const { data: jobRow } = await sb.from("provider_jobs")
    .select("provider_key,status").eq("id", jobId).maybeSingle();
  if (jobRow?.status === "queued") {
    const { data: claimed } = await sb.rpc("claim_provider_jobs", {
      p_worker: "check", p_provider_key: jobRow.provider_key, p_limit: 5,
    });
    const mine = ((claimed ?? []) as ClaimedJob[]).find((c) => c.job_id === jobId);
    // Process every job we claimed (ours + any siblings we happened to lock).
    for (const c of (claimed ?? []) as ClaimedJob[]) {
      const out = await processJob(c);
      if (c.job_id === jobId) processed = out;
    }
    if (!mine) processed = null; // someone else is processing it
  }

  // Return the fresh, fail-closed work-ready verdict.
  const resolvedSet = await resolveSetId(setId, setCode);
  let status = "red", ready = false;
  if (resolvedSet) {
    const [{ data: st }, { data: wr }] = await Promise.all([
      sb.rpc("work_ready_status", { p_candidate_id: candidateId, p_set_id: resolvedSet }),
      sb.rpc("is_work_ready", { p_candidate_id: candidateId, p_set_id: resolvedSet }),
    ]);
    status = (st as string) ?? "red";
    ready = wr === true;
  }
  return json({ job_id: jobId, outcome: processed, candidate_id: candidateId, set_id: resolvedSet, status, work_ready: ready });
}

// ── mode=drain ───────────────────────────────────────────────────────────────
async function handleDrain(): Promise<Response> {
  const { data: providers, error } = await sb.from("verification_providers")
    .select("provider_key,max_concurrency").eq("status", "active");
  if (error) return json({ error: error.message }, 500);

  const byOutcome: Record<string, number> = {};
  let processed = 0;
  for (const p of providers ?? []) {
    const { data: claimed } = await sb.rpc("claim_provider_jobs", {
      p_worker: "drain", p_provider_key: p.provider_key, p_limit: p.max_concurrency ?? 2,
    });
    for (const c of (claimed ?? []) as ClaimedJob[]) {
      const out = await processJob(c);
      byOutcome[out] = (byOutcome[out] ?? 0) + 1;
      processed++;
    }
  }
  return json({ mode: "drain", processed, byOutcome });
}

// ── mode=sweep ───────────────────────────────────────────────────────────────
async function handleSweep(): Promise<Response> {
  const { data: enqueued } = await sb.rpc("enqueue_due_rechecks", { p_limit: 500 });
  const { data: purged } = await sb.rpc("purge_provider_job_responses", { p_days: 90 });
  const { data: counts } = await sb.rpc("verification_counts");
  return json({ mode: "sweep", enqueued: enqueued ?? 0, purged: purged ?? 0, counts: counts ?? {} });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const url = new URL(req.url);
  const mode = (url.searchParams.get("mode") ?? "check").toLowerCase();

  try {
    if (mode === "drain" || mode === "sweep") {
      // Cron modes have real side effects (PII provider calls, retention purge),
      // so FAIL CLOSED like the work-ready gate: reject when CRON_SECRET is unset
      // OR mismatched (an unconfigured secret must not leave the endpoint open).
      const need = Deno.env.get("CRON_SECRET");
      if (!need || url.searchParams.get("secret") !== need) return json({ error: "forbidden" }, 403);
      return mode === "drain" ? await handleDrain() : await handleSweep();
    }
    if (mode === "check") return await handleCheck(req);
    return json({ error: `unknown mode: ${mode}` }, 400);
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
