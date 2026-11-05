// ============================================================================
//  Day Webster — Candidate Pipeline · shared staff authentication
//
//  Verifies the SIGNATURE of the caller's Supabase access token — not just a
//  base64 decode of the payload — then enforces the authorised company
//  email-domain allow-list. This is the app-level identity check for every
//  staff-only edge function; it must NOT rely on the per-function `verify_jwt`
//  deploy toggle alone (a single mis-set flag would otherwise be a full bypass).
//
//  Verification order:
//    1. JWKS (asymmetric ES256/RS256 keys) at <SUPABASE_URL>/auth/v1/.well-known/jwks.json
//    2. HS256 shared secret (SUPABASE_JWT_SECRET), for legacy projects
//  A token that verifies under NEITHER is rejected. Fails CLOSED: if there is
//  no way to verify (no SUPABASE_URL and no SUPABASE_JWT_SECRET), every
//  request is denied.
//
//  The anon and service_role keys are themselves valid JWTs, so signature
//  alone is not enough — we additionally require a verified user `email` on an
//  allowed domain, which those machine tokens never carry.
// ============================================================================

import { jwtVerify, createRemoteJWKSet } from "npm:jose@5";

export const ALLOWED_DOMAINS = [
  "@daywebster.com",
  "@daywebstergroup.com",
  "@homecare-providers.com",
  "@homecareproviders.co.uk",
];

export const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Content-Type": "application/json",
};

let _jwks: ReturnType<typeof createRemoteJWKSet> | null = null;
function jwks() {
  const url = (Deno.env.get("SUPABASE_URL") ?? "").replace(/\/$/, "");
  if (!url) return null;
  if (!_jwks) _jwks = createRemoteJWKSet(new URL(`${url}/auth/v1/.well-known/jwks.json`));
  return _jwks;
}

export interface StaffClaims {
  email: string;
  sub?: string;
  role?: string;
}

// Verify the token against both possible signing schemes. Returns the payload
// only if the signature (and exp) check out under one of them.
async function verifiedPayload(token: string): Promise<Record<string, unknown> | null> {
  const ks = jwks();
  if (ks) {
    try { return (await jwtVerify(token, ks)).payload as Record<string, unknown>; } catch { /* try HS256 */ }
  }
  const secret = Deno.env.get("SUPABASE_JWT_SECRET");
  if (secret) {
    try { return (await jwtVerify(token, new TextEncoder().encode(secret))).payload as Record<string, unknown>; } catch { /* fall through */ }
  }
  return null;
}

// Returns the verified staff claims, or null if the caller is not an
// authenticated user on an authorised company domain.
export async function verifyStaff(req: Request): Promise<StaffClaims | null> {
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  if (!token || token.split(".").length !== 3) return null;

  const payload = await verifiedPayload(token);
  if (!payload) return null; // bad signature / expired / unverifiable — fail closed

  const role = String(payload.role ?? "");
  if (role === "anon" || role === "service_role") return null; // machine tokens, not a user
  const email = String(payload.email ?? "").toLowerCase();
  if (!email || !ALLOWED_DOMAINS.some((d) => email.endsWith(d))) return null;

  return { email, sub: payload.sub as string | undefined, role };
}

export function unauthorized(): Response {
  return new Response(JSON.stringify({ error: "unauthorized" }), { status: 401, headers: CORS });
}
