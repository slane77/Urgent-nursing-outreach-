// ============================================================================
//  Day Webster — Candidate Pipeline · manual adapter
//  functions/verification/adapters/manual.ts
//
//  For sources a machine can't check unattended (DBS Update Service, RTW share
//  code without an IDSP). It performs NO check — it deterministically routes the
//  job to a human (needs_human) so a compliance officer completes it in-app. It
//  can never auto-pass.
// ============================================================================

import type { AdapterJob, AdapterProvider, VerificationAdapter, VerificationResult } from "./types.ts";

export const manualAdapter: VerificationAdapter = {
  run(_job: AdapterJob, provider: AdapterProvider): Promise<VerificationResult> {
    return Promise.resolve({
      outcome: "needs_human",
      matchConfidence: "none",
      raw: { note: "manual check — human task", provider: provider.key },
      notes: `${provider.key}: manual verification required — assigned to a compliance officer`,
    });
  },
};
