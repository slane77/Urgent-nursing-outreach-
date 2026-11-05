// ============================================================================
//  Day Webster — Candidate Pipeline · Right-to-Work adapter — SHELL
//  functions/verification/adapters/rtw.ts
//
//  RTW = the gov share-code online check + IDVT via a certified IDSP (§1).
//  Credential-gated SHELL: until RTW_API_KEY (an IDSP key) is set it returns
//  needs_human (never throws, never auto-passes). RTW also requires recorded
//  consent (verification_consent) before any real call.
// ============================================================================

import type { AdapterJob, AdapterProvider, VerificationAdapter, VerificationResult } from "./types.ts";
import { notConfigured } from "./types.ts";

export const rtwAdapter: VerificationAdapter = {
  async run(job: AdapterJob, provider: AdapterProvider): Promise<VerificationResult> {
    const secretRef = provider.config?.secret_ref ?? "RTW_API_KEY";
    const key = Deno.env.get(secretRef);
    if (!key) return notConfigured(provider);

    // TODO(real): with recorded consent, resolve the candidate's share code via
    // the gov RTW check / a certified IDSP (Yoti/TrustID/Credas) and map to a
    // VerificationResult. matchConfidence:'exact' ONLY for a confirmed right to
    // work. Transport error => { outcome:'error', retryable:true }.
    return {
      outcome: "needs_human",
      matchConfidence: "none",
      raw: { note: "rtw adapter keyed but real call not implemented (POC)", job: job.jobId },
      notes: "rtw: real share-code / IDVT call is a TODO — routed to human review",
    };
  },
};
