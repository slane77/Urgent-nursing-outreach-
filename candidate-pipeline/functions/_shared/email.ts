// ============================================================================
//  Day Webster — Candidate Pipeline · shared email helper
//  Sends candidate-side transactional email via Brevo. Imported by the
//  candidate edge functions (agent replies, reference requests, expiry chases).
//
//  Uses its OWN sender identity (CANDIDATE_SENDER_*) — separate from the
//  client/employer outreach mailshots. Reply-To can carry a correlation token
//  so the reply is routed back to the right candidate by `inbound-email`.
//
//  Env: BREVO_API_KEY, CANDIDATE_SENDER_EMAIL, CANDIDATE_SENDER_NAME,
//       REPLY_DOMAIN, REPLY_LOCAL
// ============================================================================

export interface SendArgs {
  to: string;
  toName?: string;
  subject: string;
  html: string;
  replyTo?: string;
  // One-click unsubscribe URL. When set, a List-Unsubscribe header +
  // List-Unsubscribe-Post are added so mail clients expose a native opt-out
  // (required for marketing/outreach sends — PECR reg. 22).
  unsubscribeUrl?: string;
}

export async function sendBrevoEmail(a: SendArgs): Promise<{ ok: boolean; id?: string; error?: string }> {
  const key = Deno.env.get("BREVO_API_KEY");
  if (!key) return { ok: false, error: "BREVO_API_KEY not set" };
  if (!a.to) return { ok: false, error: "no recipient" };

  const headers = a.unsubscribeUrl
    ? {
        "List-Unsubscribe": `<${a.unsubscribeUrl}>`,
        "List-Unsubscribe-Post": "List-Unsubscribe=One-Click",
      }
    : undefined;

  const res = await fetch("https://api.brevo.com/v3/smtp/email", {
    method: "POST",
    headers: { "api-key": key, "Content-Type": "application/json", "Accept": "application/json" },
    body: JSON.stringify({
      sender: {
        email: Deno.env.get("CANDIDATE_SENDER_EMAIL") ?? "candidates@daywebster.com",
        name: Deno.env.get("CANDIDATE_SENDER_NAME") ?? "Day Webster",
      },
      to: [{ email: a.to, name: a.toName }],
      replyTo: a.replyTo ? { email: a.replyTo } : undefined,
      subject: a.subject,
      htmlContent: a.html,
      headers,
    }),
  });
  if (!res.ok) return { ok: false, error: `brevo ${res.status}: ${await res.text()}` };
  const j = await res.json().catch(() => ({} as any));
  return { ok: true, id: j.messageId };
}

// 16-char correlation token (matches inbound-email's [a-z0-9]{6,} parser).
export function newToken(): string {
  return crypto.randomUUID().replace(/-/g, "").slice(0, 16);
}

// Reply-To address that embeds a token, e.g. compliance+<token>@<domain>.
export function replyToFor(token: string): string {
  const dom = Deno.env.get("REPLY_DOMAIN") ?? "candidates.daywebster.com";
  const local = Deno.env.get("REPLY_LOCAL") ?? "compliance";
  return `${local}+${token}@${dom}`;
}

// Wrap body text in a minimal branded HTML shell. Pass `unsubscribeUrl` on
// marketing/outreach sends to render a visible opt-out footer (PECR reg. 22).
export function emailHtml(body: string, unsubscribeUrl?: string): string {
  const safe = body.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/\n/g, "<br>");
  const footer = unsubscribeUrl
    ? `<br><br><span style="color:#9ca3af;font-size:12px">Don't want these emails? <a href="${unsubscribeUrl}" style="color:#9ca3af">Unsubscribe</a>.</span>`
    : "";
  return `<div style="font-family:system-ui,Segoe UI,Roboto,sans-serif;font-size:15px;color:#1f2937;line-height:1.5">${safe}<br><br><span style="color:#6b7280">Day Webster</span>${footer}</div>`;
}
