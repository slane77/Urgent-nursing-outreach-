// ============================================================================
//  Day Webster — Candidate Pipeline · checklist-fill (Supabase Edge Function)
//
//  STATUS: DRAFT — NOT YET DEPLOYED. For review only.
//
//  The Client Checklist Auto-Fill engine (design §3). Pick a client template,
//  resolve the candidate's Compliance Passport, merge it into the client's exact
//  tokenized .docx (docxtemplater — surrounding XML/branding untouched), and
//  either preview (dry_run) or generate + record an immutable fill.
//
//  POST JSON: { candidate_id, template_id, dry_run? }
//    auth: officer session (Authorization: Bearer <user jwt>); email-domain gate
//          (same pattern as compliance-import). We call the DB with the SERVICE
//          role, but only AFTER the caller's email domain is verified.
//
//  Flow: auth-gate -> compliance_passport(candidate_id) -> load template ->
//        download tokenized .docx -> build render data from field_map (resolve
//        passport.fields[field].value, apply a SAFE transform allow-list, or a
//        static) -> render with a nullGetter that returns a VISIBLE sentinel
//        («NEEDS ATTENTION: <label>») and collects the field into missing_fields.
//
//  Missing-value handling (never a silent blank):
//    · a REQUIRED field resolving empty + template.missing_policy='block'
//      -> status='needs_attention' (still rendered so the officer sees the gap;
//         mark-as-sent stays disabled until an admin overrides).
//    · missing_policy='annotate' -> render the sentinel in place, status='generated'.
//
//  dry_run  -> returns { values (with provenance), missing_fields, status } and
//              WRITES NOTHING (the review view).
//  real run -> upload to checklist-outputs/<cand>/<template>/<uuid>.docx, call
//              record_checklist_fill(), return { fill_id, signed_url (TTL 300s),
//              missing_fields, status }.
//
//  Fail-closed: auth fail => 401; any resolver/render/upload error => 5xx and
//  NOTHING is written (record_checklist_fill runs only after a successful upload).
//  PII: NI/DBS/share-code are merged into the client's own form only; they are
//  never logged to provider_jobs and never sent to any AI prompt.
// ============================================================================

import { createClient } from "npm:@supabase/supabase-js";
import Docxtemplater from "npm:docxtemplater";
import PizZip from "npm:pizzip";

const sb = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { db: { schema: "candidate" } },
);

const ALLOWED_DOMAINS = [
  "@daywebster.com", "@daywebstergroup.com",
  "@homecare-providers.com", "@homecareproviders.co.uk",
];

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Content-Type": "application/json",
};

// ---- Auth: decode the caller JWT, verify the email domain (as compliance-import)
function emailFromJwt(req: Request): string | null {
  const auth = req.headers.get("Authorization") ?? "";
  const token = auth.replace(/^Bearer\s+/i, "");
  const part = token.split(".")[1];
  if (!part) return null;
  try {
    const json = JSON.parse(atob(part.replace(/-/g, "+").replace(/_/g, "/")));
    return (json.email ?? "").toLowerCase() || null;
  } catch {
    return null;
  }
}
function authorized(req: Request): boolean {
  const email = emailFromJwt(req);
  return !!email && ALLOWED_DOMAINS.some((d) => email.endsWith(d));
}

// ---- Passport field object shape -------------------------------------------
type Field = {
  value: string | null;
  provenance: "verified" | "self_declared" | "derived" | "missing";
  as_at: string | null;
  source_ref: string | null;
};
type MapEntry = {
  token: string;
  field?: string | null;
  static?: string;
  required?: boolean;
  transform?: string | null;
};

// ---- Safe transform allow-list (NO arbitrary code) --------------------------
function toUK(v: string): string {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(v.trim());
  return m ? `${m[3]}/${m[2]}/${m[1]}` : v;
}
function titleCase(v: string): string {
  return v.toLowerCase().replace(/\b\w/g, (c) => c.toUpperCase());
}
function applyTransform(transform: string | null | undefined, f: Field): string {
  const raw = (f.value ?? "").toString();
  if (!raw) return "";
  switch (transform) {
    case "date_uk": return toUK(raw);
    case "upper":   return raw.toUpperCase();
    case "title":   return titleCase(raw);
    case "yes_no":
      return /^(yes|true|verified|y|1)$/i.test(raw.trim()) ? "Yes" : "No";
    case "with_provenance": {
      if (f.provenance === "verified") {
        const when = f.as_at ? ` ${toUK(f.as_at)}` : "";
        return `${raw} (verified${when})`;
      }
      return raw;
    }
    default: return raw; // null / unknown transform => the plain value
  }
}

// ---- Resolve the field_map against the passport -----------------------------
function resolveValues(fields: Record<string, Field>, fieldMap: MapEntry[]) {
  const data: Record<string, string> = {};        // token -> rendered string
  const resolved: Record<string, unknown> = {};    // token -> {value, provenance, ...} (review view)
  const labelByToken: Record<string, string> = {};
  const missing: { token: string; field: string | null; label: string; required: boolean }[] = [];
  let requiredMissing = false;

  for (const e of fieldMap) {
    const token = e.token;
    const required = !!e.required;
    const label = e.field ?? e.token;
    labelByToken[token] = label;

    // A static answer bypasses the passport entirely.
    if (e.static !== undefined && (e.field === null || e.field === undefined)) {
      data[token] = e.static ?? "";
      resolved[token] = { value: e.static ?? "", provenance: "static" };
      continue;
    }

    const f: Field = (e.field && fields[e.field]) || {
      value: null, provenance: "missing", as_at: null, source_ref: null,
    };
    const out = applyTransform(e.transform, f);
    resolved[token] = { field: e.field, ...f, rendered: out, required };

    if (!out) {
      // Never a silent blank: render a visible sentinel + record the gap.
      data[token] = `«NEEDS ATTENTION: ${label}»`;
      missing.push({ token, field: e.field ?? null, label, required });
      if (required) requiredMissing = true;
    } else {
      data[token] = out;
    }
  }
  return { data, resolved, labelByToken, missing, requiredMissing };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (!authorized(req)) {
    return new Response(JSON.stringify({ error: "unauthorized" }), { status: 401, headers: CORS });
  }

  try {
    const { candidate_id, template_id, dry_run } = await req.json();
    if (!candidate_id || !template_id) {
      return new Response(JSON.stringify({ error: "candidate_id and template_id are required" }),
        { status: 400, headers: CORS });
    }

    // 1. Resolve the Compliance Passport UNDER THE CALLER'S IDENTITY. The domain
    //    gate above is NOT sufficient: the passport surfaces officer-RLS-only
    //    special-category data (NI/DBS number/RTW share code), and calling it via
    //    the service role would satisfy is_service_role() regardless of who the
    //    caller is — letting a non-officer @daywebster user pull that data. So we
    //    call it with a caller-scoped client (anon key + the caller's JWT); a
    //    non-officer is rejected by compliance_passport()'s own
    //    is_compliance_officer() gate and lands in the 403 below.
    const callerSb = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { db: { schema: "candidate" }, global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } },
    );
    const { data: passport, error: pErr } = await callerSb.rpc("compliance_passport", { p_candidate_id: candidate_id });
    if (pErr) {
      // Fail-closed: the SQL officer-gate (or any resolver error) => forbidden;
      // nothing is written and no data escapes.
      return new Response(JSON.stringify({ error: "forbidden" }), { status: 403, headers: CORS });
    }
    const fields = (passport?.fields ?? {}) as Record<string, Field>;

    // 2. Load the template row.
    const { data: tpl, error: tErr } = await sb
      .from("checklist_templates")
      .select("id,bucket,template_path,field_map,static_answers,missing_policy,name,client_name,version")
      .eq("id", template_id)
      .single();
    if (tErr || !tpl) throw new Error(`template: ${tErr?.message ?? "not found"}`);

    // 3. Build the field map (static_answers fold in as static entries).
    const fieldMap: MapEntry[] = Array.isArray(tpl.field_map) ? tpl.field_map : [];
    for (const [token, value] of Object.entries(tpl.static_answers ?? {})) {
      if (!fieldMap.some((e) => e.token === token)) {
        fieldMap.push({ token, field: null, static: String(value), required: false });
      }
    }

    // 4. Resolve values + missing list.
    const { data, resolved, labelByToken, missing, requiredMissing } = resolveValues(fields, fieldMap);

    // 5. Status per the template's missing policy.
    const status = requiredMissing && tpl.missing_policy === "block" ? "needs_attention" : "generated";

    // 6. dry_run: return the review payload and write NOTHING.
    if (dry_run) {
      return new Response(JSON.stringify({ resolved, missing_fields: missing, status, dry_run: true }),
        { headers: CORS });
    }

    // 7. Download the tokenized .docx and render in place.
    const { data: blob, error: dErr } = await sb.storage.from(tpl.bucket).download(tpl.template_path);
    if (dErr || !blob) throw new Error(`download: ${dErr?.message ?? "no template file"}`);
    const zip = new PizZip(await blob.arrayBuffer());
    const doc = new Docxtemplater(zip, {
      paragraphLoop: true,
      linebreaks: true,
      // Any doc token absent from the field_map still renders a visible sentinel
      // and is collected — a compliance blank is never silently empty.
      nullGetter: (part: { value?: string }) => {
        const token = part?.value ?? "";
        const label = labelByToken[token] ?? token;
        if (token && !missing.some((m) => m.token === token)) {
          missing.push({ token, field: null, label, required: false });
        }
        return `«NEEDS ATTENTION: ${label}»`;
      },
    });
    doc.render(data);
    const out = doc.getZip().generate({ type: "uint8array" });

    // 8. Upload to the private outputs bucket.
    const fillUuid = crypto.randomUUID();
    const outPath = `${candidate_id}/${template_id}/${fillUuid}.docx`;
    const { error: uErr } = await sb.storage.from("checklist-outputs").upload(outPath, out, {
      contentType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
      upsert: false,
    });
    if (uErr) throw new Error(`upload: ${uErr.message}`);

    // 9. Record the immutable fill ONLY after a successful upload (fail-closed).
    const { data: fillId, error: rErr } = await sb.rpc("record_checklist_fill", {
      p_candidate_id: candidate_id,
      p_template_id: template_id,
      p_output_path: outPath,
      p_values_snapshot: resolved,
      p_missing_fields: missing,
      p_status: status,
    });
    if (rErr) throw new Error(`record: ${rErr.message}`);

    // 10. Short-TTL signed URL for the officer to download.
    const { data: signed } = await sb.storage.from("checklist-outputs").createSignedUrl(outPath, 300);

    return new Response(JSON.stringify({
      fill_id: fillId,
      signed_url: signed?.signedUrl ?? null,
      missing_fields: missing,
      status,
    }), { headers: CORS });
  } catch (e) {
    // Fail-closed: no partial "sent" ever escapes; nothing recorded on error.
    return new Response(JSON.stringify({ error: String(e) }), { status: 500, headers: CORS });
  }
});
