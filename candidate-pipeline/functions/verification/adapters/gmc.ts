// ============================================================================
//  Day Webster — Candidate Pipeline · GMC adapter (bulk_facility) — SHELL
//  functions/verification/adapters/gmc.ts
//
//  GMC LRMP multi-number search / the paid register download licence (§1).
//  Credential-gated SHELL: until GMC_API_KEY is set it returns needs_human
//  (never throws, never auto-passes). When credentialed, replace the TODO.
// ============================================================================

import type { AdapterJob, AdapterProvider, VerificationAdapter, VerificationResult } from "./types.ts";
import { notConfigured } from "./types.ts";

export const gmcAdapter: VerificationAdapter = {
  async run(job: AdapterJob, provider: AdapterProvider): Promise<VerificationResult> {
    const secretRef = provider.config?.secret_ref ?? "GMC_API_KEY";
    const key = Deno.env.get(secretRef);
    if (!key) return notConfigured(provider);

    // TODO(real): query the GMC LRMP by GMC number (or reconcile the licensed
    // register download) and map to a VerificationResult. matchConfidence:'exact'
    // ONLY for a single confirmed record; expiresAt = the revalidation date.
    // Transport error => { outcome:'error', retryable:true }.
    return {
      outcome: "needs_human",
      matchConfidence: "none",
      raw: { note: "gmc adapter keyed but real call not implemented (POC)", job: job.jobId },
      notes: "gmc: real LRMP lookup is a TODO — routed to human review",
    };
  },
};
