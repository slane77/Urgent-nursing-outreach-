// ============================================================================
//  Day Webster — Candidate Pipeline · shared unsubscribe helpers
//
//  Builds and verifies signed one-click unsubscribe links (PECR reg. 22 /
//  UK-GDPR Art. 7(3)). The link carries the email plus an HMAC-SHA256 tag so
//  a recipient can opt out without logging in, but nobody can suppress a third
//  party's address by guessing a URL.
//
//  Env: UNSUBSCRIBE_SECRET (required to mint/verify links), PUBLIC_SITE_URL,
//       SUPABASE_URL (used to locate the public `unsubscribe` function).
// ============================================================================

async function hmac(email: string, secret: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(email.toLowerCase()));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

// Constant-time-ish string compare (avoids leaking length/prefix via early exit).
function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

// The public endpoint that records the opt-out.
function unsubscribeBase(): string {
  const site = (Deno.env.get("PUBLIC_SITE_URL") ?? "").replace(/\/$/, "");
  const sb = (Deno.env.get("SUPABASE_URL") ?? "").replace(/\/$/, "");
  // Prefer the edge function; the site URL is only used for the branded page.
  return `${sb}/functions/v1/unsubscribe`;
}

// Full signed unsubscribe URL for an email, or null if no secret is configured.
export async function unsubscribeUrl(email: string): Promise<string | null> {
  const secret = Deno.env.get("UNSUBSCRIBE_SECRET");
  if (!secret || !email) return null;
  const t = await hmac(email, secret);
  return `${unsubscribeBase()}?e=${encodeURIComponent(email.toLowerCase())}&t=${t}`;
}

// Verify a link's signature. Returns the normalised email if valid, else null.
export async function verifyUnsubscribe(email: string, tag: string): Promise<string | null> {
  const secret = Deno.env.get("UNSUBSCRIBE_SECRET");
  if (!secret || !email || !tag) return null; // fail closed
  const expected = await hmac(email, secret);
  return safeEqual(expected, tag.toLowerCase()) ? email.toLowerCase() : null;
}
