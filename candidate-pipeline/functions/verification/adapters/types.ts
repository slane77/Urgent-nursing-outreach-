// ============================================================================
//  Day Webster — Candidate Pipeline · verification adapter contract
//  functions/verification/adapters/types.ts
//
//  One interface every provider adapter implements. The adapter's ONLY job is to
//  ask the source "is this registration/DBS/RTW live?" and return a normalised
//  result. It NEVER writes to the DB and NEVER decides the gate — the dispatcher
//  maps the result through the fail-closed SECURITY DEFINER RPCs. An adapter can
//  never auto-pass an ambiguous match: the dispatcher downgrades any
//  matchConfidence !== 'exact' verified result to needs_human centrally.
// ============================================================================

// Outcome the adapter reports. Only 'verified' can ever credit the gate; every
// other value routes to human review or a definitive negative — never a pass.
export type VerificationOutcome =
  | "verified"     // live, unambiguous match
  | "expired"      // source says the registration has lapsed
  | "unsuitable"   // source says struck-off / barred / not suitable
  | "needs_human"  // ambiguous / not configured / can't decide -> human review
  | "error";       // transient failure -> retry, then human review (never a pass)

export type MatchConfidence = "exact" | "partial" | "ambiguous" | "none";

// The (non-secret) provider config the adapter is handed. `secretRef` NAMES the
// env var holding the credential; the adapter reads Deno.env.get(secretRef).
export interface AdapterProvider {
  key: string;
  kind: "realtime_api" | "bulk_facility" | "aggregator" | "manual" | "sim";
  regulator: string | null;
  endpoint: string | null;
  config: Record<string, unknown> & { secret_ref?: string };
}

// The claimed job the adapter is asked to resolve.
export interface AdapterJob {
  jobId: string;
  candidateId: string;
  requirementId: string | null;
  itemId: string | null;
  requirementCode: string | null;
  trigger: string;
  attempts: number;
  maxAttempts: number;
}

// The normalised result the dispatcher applies through the DB RPCs.
export interface VerificationResult {
  outcome: VerificationOutcome;
  matchConfidence: MatchConfidence;
  registrationNumber?: string | null;
  expiresAt?: string | null;   // ISO — the regulator's own renewal date
  sourceRef?: string | null;   // regulator/provider reference (audit)
  raw?: Record<string, unknown>;
  retryable?: boolean;         // only meaningful for outcome === 'error'
  notes?: string | null;
}

export interface VerificationAdapter {
  run(job: AdapterJob, provider: AdapterProvider): Promise<VerificationResult>;
}

// Helper: the "not configured" answer a credential-gated shell returns when its
// secret_ref env is unset. NEVER throws, NEVER auto-passes.
export function notConfigured(provider: AdapterProvider): VerificationResult {
  return {
    outcome: "needs_human",
    matchConfidence: "none",
    raw: { note: "provider not configured", provider: provider.key, secret_ref: provider.config?.secret_ref ?? null },
    notes: `${provider.key}: no credential (${provider.config?.secret_ref ?? "secret_ref"} unset) — routed to human review`,
  };
}
