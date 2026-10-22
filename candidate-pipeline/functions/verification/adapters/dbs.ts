// ============================================================================
//  Day Webster — Candidate Pipeline · DBS Update Service adapter — SHELL
//  functions/verification/adapters/dbs.ts
//
//  The DBS Update Service has no gov API — it's an online status check needing
//  the candidate's consent + identifiers, or an aggregator (§1). Credential-gated
//  SHELL: until DBS_API_KEY (an aggregator/IDSP key) is set it returns
//  needs_human (never throws, never auto-passes). DBS also requires recorded
//  consent (verification_consent) before any real call — enforce that here when
//  the real flow lands.
// ============================================================================

import type { AdapterJob, AdapterProvider, VerificationAdapter, VerificationResult } from "./types.ts";
import { notConfigured } from "./types.ts";

export const dbsAdapter: VerificationAdapter = {
  async run(job: AdapterJob, provider: AdapterProvider): Promise<VerificationResult> {
    const secretRef = provider.config?.secret_ref ?? "DBS_API_KEY";
    const key = Deno.env.get(secretRef);
    if (!key) return notConfigured(provider);

    // TODO(real): with recorded candidate consent + identifiers, query the DBS
    // Update Service (via a licensed aggregator) and map the status to a
    // VerificationResult. matchConfidence:'exact' ONLY for a confirmed clear
    // status. Transport error => { outcome:'error', retryable:true }.
    return {
      outcome: "needs_human",
      matchConfidence: "none",
      raw: { note: "dbs adapter keyed but real call not implemented (POC)", job: job.jobId },
      notes: "dbs: real DBS Update Service call is a TODO — routed to human review",
    };
  },
};
