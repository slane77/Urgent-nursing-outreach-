// ============================================================================
//  Day Webster — Candidate Pipeline · adapter registry
//  functions/verification/adapters/registry.ts
//
//  Resolves a job's provider_key/kind to the adapter that handles it. Real
//  regulator adapters are matched by provider_key; everything else falls back to
//  its kind (manual / sim). An unknown provider resolves to the manual adapter,
//  so an unrecognised source degrades to human review — never an auto-pass.
// ============================================================================

import type { AdapterProvider, VerificationAdapter } from "./types.ts";
import { simAdapter } from "./sim.ts";
import { manualAdapter } from "./manual.ts";
import { hcpcAdapter } from "./hcpc.ts";
import { nmcAdapter } from "./nmc.ts";
import { gmcAdapter } from "./gmc.ts";
import { dbsAdapter } from "./dbs.ts";
import { rtwAdapter } from "./rtw.ts";

const byKey: Record<string, VerificationAdapter> = {
  nmc: nmcAdapter,
  gmc: gmcAdapter,
  hcpc: hcpcAdapter,
  dbs_update: dbsAdapter,
  rtw_share_code: rtwAdapter,
  sim: simAdapter,
};

export function resolveAdapter(providerKey: string, provider: AdapterProvider): VerificationAdapter {
  const byExactKey = byKey[providerKey];
  if (byExactKey) return byExactKey;
  if (provider.kind === "sim") return simAdapter;
  // manual / bulk_facility / realtime_api / aggregator with no keyed adapter:
  // route to a human rather than guess (fail-closed).
  return manualAdapter;
}
