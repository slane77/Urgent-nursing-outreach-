// ============================================================================
//  Day Webster — Candidate Pipeline · HCPC adapter (realtime_api) — SHELL
//  functions/verification/adapters/hcpc.ts
//
//  HCPC offers a real Employer Check API (Phase 2 scoping §1). This is a
//  credential-gated SHELL: we hold no key yet. Until HCPC_API_KEY (the provider's
//  secret_ref) is set it returns needs_human — it NEVER throws and NEVER
//  auto-passes. When keyed, replace the TODO with the real request.
// ============================================================================

import type { AdapterJob, AdapterProvider, VerificationAdapter, VerificationResult } from "./types.ts";
import { notConfigured } from "./types.ts";

export const hcpcAdapter: VerificationAdapter = {
  async run(job: AdapterJob, provider: AdapterProvider): Promise<VerificationResult> {
    const secretRef = provider.config?.secret_ref ?? "HCPC_API_KEY";
    const key = Deno.env.get(secretRef);
    if (!key) return notConfigured(provider);

    // TODO(real): POST to provider.endpoint (HCPC Employer Check API) with the
    // candidate's registration number + the shared key; map the response to a
    // VerificationResult. Set matchConfidence:'exact' ONLY on an unambiguous
    // single match; expiresAt = the regulator's renewal date. Any transport
    // error => { outcome:'error', retryable:true } (the dispatcher retries).
    return {
      outcome: "needs_human",
      matchConfidence: "none",
      raw: { note: "hcpc adapter keyed but real call not implemented (POC)", job: job.jobId },
      notes: "hcpc: real Employer Check API call is a TODO — routed to human review",
    };
  },
};
