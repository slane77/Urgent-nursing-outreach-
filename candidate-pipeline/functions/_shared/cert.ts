// ============================================================================
//  Day Webster — Candidate Pipeline · _shared/cert.ts
//
//  STATUS: DRAFT — NOT YET DEPLOYED. For review only.
//
//  Pure, dependency-free renderer for the Phase-1 branded HTML training
//  certificate (design §5, [DECISION C1] — HTML now, PDF Phase 2). No Deno APIs,
//  no external assets, no network: given the frozen facts of a training_record it
//  returns one self-contained HTML string (inline CSS) that the training-portal /
//  manual-entry paths store as the certificate artefact in the private
//  `training-certs` bucket.
//
//  ── ACCREDITATION HONESTY (see sql/47 header) ──
//  `sfh_accreditation_ref` is a value we STORE and RENDER. Rendering it does NOT
//  make the content accredited — Skills for Health accreditation is Day Webster's
//  own business/legal fact, obtained out-of-band. So the "Skills for Health
//  accredited" line is emitted ONLY when a ref is actually present; when it is
//  absent (the seed default) the certificate asserts nothing about accreditation.
// ============================================================================

export interface CertificateFields {
  candidate_name: string;
  module_title: string;
  framework?: string | null;
  framework_subject?: string | null;
  sfh_accreditation_ref?: string | null;
  completion_date: string; // ISO date (YYYY-MM-DD)
  expiry_date: string;     // ISO date (YYYY-MM-DD)
  certificate_id: string;
}

// Minimal HTML escaper — every interpolated value passes through this so a
// candidate name / module title can never break out of the markup.
function esc(v: unknown): string {
  return (v ?? "").toString().replace(/[&<>"']/g, (c) => (
    { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c] as string
  ));
}

// Render an ISO date as a readable UK date (e.g. "25 July 2026"); falls back to
// the raw value if it is not a parseable ISO date (never throws).
function ukDate(iso: string): string {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec((iso ?? "").toString());
  if (!m) return esc(iso);
  const months = ["January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December"];
  const mo = months[parseInt(m[2], 10) - 1] ?? m[2];
  return `${parseInt(m[3], 10)} ${mo} ${m[1]}`;
}

export function renderCertificateHtml(f: CertificateFields): string {
  const subjectLine = f.framework_subject
    ? `${esc(f.framework_subject)}${f.framework ? ` &middot; ${esc(f.framework)}` : ""}`
    : (f.framework ? esc(f.framework) : "");

  // Emitted ONLY when a real accreditation ref is present (honesty rule above).
  const accreditation = f.sfh_accreditation_ref
    ? `<p class="accred">Skills for Health accredited &middot; ref ${esc(f.sfh_accreditation_ref)}</p>`
    : "";

  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Certificate ${esc(f.certificate_id)} — Day Webster</title>
<style>
  :root { --ink:#1a2330; --muted:#5b6472; --line:#d7dce4; --accent:#0b3d6b; --gold:#9a7b32; }
  * { box-sizing:border-box; }
  html,body { margin:0; padding:0; background:#eef1f5; color:var(--ink);
    font-family:Georgia,"Times New Roman",serif; }
  .sheet { max-width:820px; margin:28px auto; background:#fff; padding:56px 60px;
    border:1px solid var(--line); border-top:8px solid var(--accent);
    box-shadow:0 2px 18px rgba(20,35,60,.10); }
  .wordmark { font-family:Arial,Helvetica,sans-serif; font-weight:800; letter-spacing:.14em;
    text-transform:uppercase; font-size:15px; color:var(--accent); }
  .wordmark span { color:var(--gold); }
  .kicker { font-family:Arial,Helvetica,sans-serif; text-transform:uppercase;
    letter-spacing:.28em; font-size:11px; color:var(--muted); margin:30px 0 6px; }
  h1 { font-size:30px; margin:0 0 4px; color:var(--accent); }
  .subject { font-size:16px; color:var(--muted); margin:0 0 24px; }
  .awarded { font-size:13px; color:var(--muted); margin:24px 0 4px;
    font-family:Arial,Helvetica,sans-serif; text-transform:uppercase; letter-spacing:.12em; }
  .name { font-size:26px; font-weight:700; margin:0 0 18px; border-bottom:1px solid var(--line);
    padding-bottom:14px; }
  .accred { font-size:13px; color:var(--gold); font-weight:700;
    font-family:Arial,Helvetica,sans-serif; margin:0 0 18px; }
  .meta { display:flex; flex-wrap:wrap; gap:26px; margin:22px 0; }
  .meta .cell { min-width:150px; }
  .meta .lbl { font-family:Arial,Helvetica,sans-serif; text-transform:uppercase;
    letter-spacing:.1em; font-size:10.5px; color:var(--muted); margin-bottom:3px; }
  .meta .val { font-size:15px; font-weight:700; }
  .certid { font-family:"Courier New",monospace; letter-spacing:.06em; }
  .verify { margin-top:30px; padding-top:16px; border-top:1px solid var(--line);
    font-family:Arial,Helvetica,sans-serif; font-size:12px; color:var(--muted); }
  .verify strong { color:var(--ink); }
  @media print { html,body { background:#fff; } .sheet { box-shadow:none; margin:0; border:none; } }
</style>
</head>
<body>
  <div class="sheet">
    <div class="wordmark">Day&nbsp;<span>Webster</span></div>
    <p class="kicker">Certificate of Completion</p>
    <h1>${esc(f.module_title)}</h1>
    ${subjectLine ? `<p class="subject">${subjectLine}</p>` : ""}
    ${accreditation}
    <p class="awarded">This certifies that</p>
    <p class="name">${esc(f.candidate_name)}</p>
    <p>has successfully completed the above mandatory training module.</p>
    <div class="meta">
      <div class="cell"><div class="lbl">Completed</div><div class="val">${ukDate(f.completion_date)}</div></div>
      <div class="cell"><div class="lbl">Valid until</div><div class="val">${ukDate(f.expiry_date)}</div></div>
      <div class="cell"><div class="lbl">Certificate ID</div><div class="val certid">${esc(f.certificate_id)}</div></div>
    </div>
    <div class="verify">
      Verify this certificate at the Day Webster certificate checker using the
      Certificate ID <strong class="certid">${esc(f.certificate_id)}</strong>.
      This document is issued by Day Webster and remains valid until the date shown above.
    </div>
  </div>
</body>
</html>`;
}
