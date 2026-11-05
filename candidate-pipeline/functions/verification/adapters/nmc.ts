// ============================================================================
//  Day Webster — Candidate Pipeline · NMC adapter (bulk_facility) — SHELL
//  functions/verification/adapters/nmc.ts
//
//  NMC has no public API — checks go through the Employer Confirmations bulk
//  facility (§1). Credential-gated SHELL: until NMC_API_KEY is set it returns
//  needs_human (never throws, never auto-passes). When credentialed, replace the
//  TODO with the batched confirmation flow.
// ============================================================================

import type { AdapterJob, AdapterProvider, VerificationAdapter, VerificationResult } from "./types.ts";
import { notConfigured } from "./types.ts";

export const nmcAdapter: VerificationAdapter = {
  async run(job: AdapterJob, provider: AdapterProvider): Promise<VerificationResult> {
    const secretRef = provider.config?.secret_ref ?? "NMC_API_KEY";
    const key = Deno.env.get(secretRef);
    if (!key) return notConfigured(provider);

    // TODO(real): submit the PIN to the NMC Employer Confirmations facility (or a
    // licensed aggregator's NMC endpoint) and map the confirmation to a
    // VerificationResult. matchConfidence:'exact' ONLY for a single confirmed
    // match; expiresAt = the revalidation/renewal date. Transport error =>
    // { outcome:'error', retryable:true }.
    return {
      outcome: "needs_human",
      matchConfidence: "none",
      raw: { note: "nmc adapter keyed but real call not implemented (POC)", job: job.jobId },
      notes: "nmc: real Employer Confirmations call is a TODO — routed to human review",
    };
  },
};
