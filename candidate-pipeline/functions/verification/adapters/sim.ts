// ============================================================================
//  Day Webster — Candidate Pipeline · SIMULATION adapter (POC demo)
//  functions/verification/adapters/sim.ts
//
//  DETERMINISTIC, no-network simulation so the full pipeline can be demonstrated
//  before we hold any real regulator credential. The outcome is derived purely
//  from (candidateId + requirementCode), so the same candidate always resolves
//  the same way — and the demo set deliberately covers verified / expired /
//  unsuitable / ambiguous(->needs_human) so every gate branch is exercised.
// ============================================================================

import type { AdapterJob, AdapterProvider, VerificationAdapter, VerificationResult } from "./types.ts";

// FNV-1a 32-bit — small, deterministic, dependency-free.
function hash(s: string): number {
  let h = 0x811c9dc5;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  return h >>> 0;
}

function plusYears(years: number): string {
  const d = new Date();
  d.setFullYear(d.getFullYear() + years);
  return d.toISOString();
}
function minusDays(days: number): string {
  const d = new Date();
  d.setDate(d.getDate() - days);
  return d.toISOString();
}

export const simAdapter: VerificationAdapter = {
  run(job: AdapterJob, _provider: AdapterProvider): Promise<VerificationResult> {
    const seed = hash(`${job.candidateId}|${job.requirementCode ?? ""}`);
    const bucket = seed % 10;                         // 0..9, deterministic
    const ref = `SIM-${(job.requirementCode ?? "REQ").toUpperCase()}-${(seed % 100000).toString().padStart(5, "0")}`;
    const regNo = `${(seed % 90 + 10)}${String.fromCharCode(65 + (seed % 26))}${(seed % 9000 + 1000)}${String.fromCharCode(65 + ((seed >> 3) % 26))}`;

    // 0..6 verified · 7 expired · 8 unsuitable · 9 ambiguous(->needs_human).
    if (bucket <= 6) {
      return Promise.resolve({
        outcome: "verified", matchConfidence: "exact",
        registrationNumber: regNo, expiresAt: plusYears(1), sourceRef: ref,
        raw: { sim: true, bucket }, notes: "sim: clean unambiguous live match",
      });
    }
    if (bucket === 7) {
      return Promise.resolve({
        outcome: "expired", matchConfidence: "exact",
        registrationNumber: regNo, expiresAt: minusDays(14), sourceRef: ref,
        raw: { sim: true, bucket }, notes: "sim: registration lapsed",
      });
    }
    if (bucket === 8) {
      return Promise.resolve({
        outcome: "unsuitable", matchConfidence: "exact", sourceRef: ref,
        raw: { sim: true, bucket }, notes: "sim: struck-off / barred",
      });
    }
    // bucket === 9 — ambiguous: NON-exact confidence, so the dispatcher forces
    // needs_human centrally even though we report a nominal 'verified'.
    return Promise.resolve({
      outcome: "verified", matchConfidence: "ambiguous",
      registrationNumber: regNo, expiresAt: plusYears(1), sourceRef: ref,
      raw: { sim: true, bucket, note: "two registrants share this name" },
      notes: "sim: ambiguous match — must go to a human",
    });
  },
};
