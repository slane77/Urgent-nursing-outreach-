// ============================================================================
//  Day Webster — Candidate Pipeline · checklist-onboard (Supabase Edge Function)
//
//  STATUS: DRAFT — NOT YET DEPLOYED. For review only. Deploying requires:
//    1. Migrations applied through candidate-pipeline/sql/44 (checklist_templates
//       + officer-insert RLS).
//    2. Secret: ANTHROPIC_API_KEY (reused from compliance-import / training-authoring).
//       Also uses the project-injected SUPABASE_URL / SUPABASE_ANON_KEY /
//       SUPABASE_SERVICE_ROLE_KEY.
//    3. Deploy with **verify_jwt=true** — staff only (a compliance officer).
//
//  AI-ASSISTED ONBOARDING of a NEW client checklist (design §4): turn a raw client
//  .docx into a reusable tokenized template + token->passport-field map with as
//  little manual work as possible. Three modes (like compliance-import's map/commit):
//
//    detect { template_path }
//       Download the RAW uploaded client .docx from the `checklist-templates`
//       bucket, unzip (pizzip), walk word/document.xml paragraphs + tables and
//       find answer-blanks by four signals in priority order:
//         (1) content controls / form fields  (<w:sdt>, <w:fldSimple>, FORMTEXT)
//         (2) an empty <w:tc> cell adjacent to a label cell
//         (3) underscore / dotted-leader runs  (____, ……)
//         (4) a colon-terminated label followed by a blank
//       Each blank gets a STABLE positional anchor (content-control ordinal, or
//       table/row/cell, or paragraph + run index) + a suggested token name, so
//       `save` can re-locate it deterministically on the SAME bytes.
//
//    map { blanks }
//       Reuse the compliance-import Anthropic stack (claude-opus-4-8 + a structured
//       json_schema). For each blank -> { target, transform?, static_value? } where
//       `target` is a passport field key from the CLOSED vocabulary, or "static",
//       or "unmapped". The vocabulary is passed as the closed allow-list in the
//       system prompt AND as a schema enum (same closed-target trick as
//       compliance-import's KNOWN_CODES) so the model CANNOT invent a field.
//
//    save { template_id?, client_name, name, original_path, mappings, missing_policy? }
//       Re-walk the ORIGINAL doc, insert a docxtemplater {token} at each confirmed
//       blank's anchor as a SINGLE contiguous <w:r> run (sidesteps docxtemplater's
//       split-run failure), leaving all surrounding XML (styles/borders/branding/
//       headers/footers) untouched. Upload the tokenized .docx as the template,
//       keep the original at original_path, and INSERT/UPDATE the
//       checklist_templates row (status='draft') with the field_map.
//
//  DATA ISOLATION (load-bearing): the AI sees ONLY the blank template's label /
//  context text. It is a BLANK client form — there is no candidate data in it, and
//  none is ever read or placed in the prompt. The passport vocabulary is the only
//  candidate-shaped input, and it is a static list of FIELD NAMES, never values.
//
//  RLS: the checklist_templates row is written with a CALLER-JWT data client (ANON
//  key + the caller's forwarded JWT) so the Phase-1 officer-insert/update RLS
//  applies under the caller's auth.uid() — a bug here can't forge a template as a
//  role the caller does not hold. Storage read/write of the (candidate-free) blank
//  template uses the service role, matching checklist-fill.
//
//  Fail-closed: auth fail => 401; any parse/AI/storage/RLS error => 4xx/5xx with a
//  generic message and NOTHING partial is left behind (the row is written last).
// ============================================================================

import Anthropic from "npm:@anthropic-ai/sdk";
import { createClient } from "npm:@supabase/supabase-js";
import PizZip from "npm:pizzip";

const MODEL = "claude-opus-4-8";
const anthropic = new Anthropic({ apiKey: Deno.env.get("ANTHROPIC_API_KEY")! });

// Service-role client: storage read/write of the BLANK (candidate-free) template.
const svc = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { db: { schema: "candidate" } },
);

const ALLOWED_DOMAINS = [
  "@daywebster.com", "@daywebstergroup.com",
  "@homecare-providers.com", "@homecareproviders.co.uk",
];

// The Compliance Passport token vocabulary (design §1 / sql/43b) — the CLOSED
// target set a blank may map to. Kept in sync with admin.html's PASSPORT_CATALOG.
const PASSPORT_CATALOG = [
  "identity.first_name", "identity.last_name", "identity.full_name", "identity.known_as", "identity.dob",
  "identity.email", "identity.phone", "identity.town", "identity.postcode", "identity.region", "identity.country",
  "identity.address", "identity.ni_number", "identity.nationality", "identity.gender", "identity.place_of_birth",
  "role.division", "role.discipline", "role.specialty", "role.job_title",
  "reg.body", "reg.number", "reg.expiry", "reg.verified", "reg.checked_at", "reg.source_ref",
  "dbs.number", "dbs.level", "dbs.issue_date", "dbs.update_service", "dbs.verified",
  "rtw.status", "rtw.share_code", "rtw.method", "rtw.expiry", "rtw.verified",
  "refs.covered", "refs.years", "refs.count", "oh.status", "oh.date", "immun.status", "immun.date",
  "training.status", "training.expiry", "qual.name", "qual.status", "qual.cert_date",
] as const;

// The safe transform allow-list mirrored from checklist-fill (design §2). "" = none.
const TRANSFORMS = ["", "date_uk", "yes_no", "upper", "title", "with_provenance"] as const;

const CATALOG = new Set<string>(PASSPORT_CATALOG);
const TARGETS = new Set<string>([...PASSPORT_CATALOG, "static", "unmapped"]);
const XFORMS = new Set<string>(TRANSFORMS);

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

// ============================================================================
//  DOCX ANALYSIS — a small, dependency-light walk of word/document.xml.
//  Returns everything BOTH detect (labels + coordinates) and save (byte offsets
//  to splice) need, computed the SAME way so a blank found at detect resolves to
//  the identical location at save (same bytes => same ordinals/indices).
// ============================================================================

type TRun = { tInnerStart: number; tInnerEnd: number; inner: string }; // a <w:t> text span
type Para = {
  index: number;
  spanStart: number;   // offset of <w:p ...>
  spanEnd: number;     // offset just past </w:p>
  closeStart: number;  // offset of </w:p>  (insertion point for an appended run)
  cellRef: { table: number; row: number; cell: number } | null;
  runs: TRun[];
  text: string;        // decoded, concatenated run text
};
type Cell = {
  table: number; row: number; cell: number;
  start: number; end: number;
  text: string;
  firstParaClose: number | null; // insertion point (before </w:p> of the cell's first paragraph)
};
type Ctrl = { ord: number; kind: "sdt" | "fldSimple" | "formtext"; spanStart: number; spanEnd: number; contentStart: number; contentEnd: number; label: string; paraIndex: number };

type Analysis = { xml: string; paras: Para[]; cells: Cell[]; ctrls: Ctrl[] };

function decodeXml(s: string): string {
  return s.replace(/<[^>]+>/g, "")
    .replace(/&lt;/g, "<").replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&amp;/g, "&")
    .replace(/\s+/g, " ").trim();
}
function attr(tag: string, name: string): string | null {
  const m = new RegExp(`${name}="([^"]*)"`).exec(tag);
  return m ? m[1] : null;
}

// Assign each paragraph the innermost <w:tc> that contains it, and build the cell
// list with stable coordinates (document-order table index; row/cell reset per
// parent). Handles nested tables via a stack.
function parseCells(xml: string, paras: Para[]): Cell[] {
  type Frame = { name: string; start: number; table: number; row: number; cell: number; rowSeq: number; cellSeq: number };
  const stack: Frame[] = [];
  const cells: Cell[] = [];
  let tableSeq = 0;
  const tagRe = /<(\/?)w:(tbl|tr|tc)\b[^>]*?(\/?)>/g;
  let m: RegExpExecArray | null;
  while ((m = tagRe.exec(xml))) {
    const closing = m[1] === "/";
    const name = m[2];
    const selfClose = m[3] === "/";
    if (selfClose) continue;
    if (!closing) {
      const parent = stack[stack.length - 1];
      if (name === "tbl") {
        stack.push({ name, start: m.index + m[0].length, table: tableSeq++, row: -1, cell: -1, rowSeq: 0, cellSeq: 0 });
      } else if (name === "tr") {
        const tbl = [...stack].reverse().find((f) => f.name === "tbl");
        const row = tbl ? tbl.rowSeq++ : 0;
        stack.push({ name, start: m.index + m[0].length, table: tbl?.table ?? 0, row, cell: -1, rowSeq: 0, cellSeq: 0 });
      } else { // tc
        const tr = [...stack].reverse().find((f) => f.name === "tr");
        const cell = tr ? tr.cellSeq++ : 0;
        stack.push({ name, start: m.index + m[0].length, table: tr?.table ?? (parent?.table ?? 0), row: tr?.row ?? 0, cell, rowSeq: 0, cellSeq: 0 });
      }
    } else {
      // pop to the matching frame
      for (let i = stack.length - 1; i >= 0; i--) {
        if (stack[i].name === name) {
          const f = stack.splice(i, 1)[0];
          if (name === "tc") {
            cells.push({ table: f.table, row: f.row, cell: f.cell, start: f.start, end: m.index, text: "", firstParaClose: null });
          }
          break;
        }
      }
    }
  }
  // Attach cellRef to paragraphs + cell text + insertion points (innermost cell wins).
  for (const p of paras) {
    let best: Cell | null = null;
    for (const c of cells) {
      if (p.spanStart >= c.start && p.spanStart < c.end && (!best || c.start > best.start)) best = c;
    }
    if (best) {
      p.cellRef = { table: best.table, row: best.row, cell: best.cell };
      best.text = best.text ? `${best.text} ${p.text}`.trim() : p.text;
      if (best.firstParaClose === null) best.firstParaClose = p.closeStart;
    }
  }
  return cells;
}

function analyze(xml: string): Analysis {
  // Body only — never touch headers/footers/styles (separate parts anyway).
  const bodyStart = xml.indexOf("<w:body");
  const scanFrom = bodyStart >= 0 ? bodyStart : 0;

  // Paragraphs (w:p do not nest; non-greedy close is safe).
  const paras: Para[] = [];
  const pRe = /<w:p\b[^>]*?>[\s\S]*?<\/w:p>/g;
  pRe.lastIndex = scanFrom;
  let pm: RegExpExecArray | null;
  while ((pm = pRe.exec(xml))) {
    const spanStart = pm.index;
    const block = pm[0];
    const spanEnd = spanStart + block.length;
    const closeStart = spanEnd - "</w:p>".length;
    const runs: TRun[] = [];
    const tRe = /<w:t\b[^>]*>([\s\S]*?)<\/w:t>/g;
    let tm: RegExpExecArray | null;
    while ((tm = tRe.exec(block))) {
      const openLen = tm[0].indexOf(">") + 1;
      const innerStart = spanStart + tm.index + openLen;
      runs.push({ tInnerStart: innerStart, tInnerEnd: innerStart + tm[1].length, inner: tm[1] });
    }
    const text = decodeXml(block);
    paras.push({ index: paras.length, spanStart, spanEnd, closeStart, cellRef: null, runs, text });
  }

  const cells = parseCells(xml, paras);

  // Content controls / form fields, in document order.
  const ctrls: Ctrl[] = [];
  const paraOf = (off: number): number => {
    let best = -1;
    for (const p of paras) if (off >= p.spanStart && off < p.spanEnd && (best < 0 || p.spanStart > paras[best].spanStart)) best = p.index;
    return best;
  };

  // (1a) Structured document tags — <w:sdt> ... </w:sdt> (non-greedy; nested sdt rare).
  const sdtRe = /<w:sdt>[\s\S]*?<\/w:sdt>/g;
  let sm: RegExpExecArray | null;
  while ((sm = sdtRe.exec(xml))) {
    const span = sm[0];
    const cm = /<w:sdtContent>([\s\S]*?)<\/w:sdtContent>/.exec(span);
    const contentStart = cm ? sm.index + cm.index + "<w:sdtContent>".length : sm.index + span.length;
    const contentEnd = cm ? contentStart + cm[1].length : contentStart;
    const alias = attr(span, "w:val") ?? "";
    const pIdx = paraOf(sm.index);
    ctrls.push({
      ord: 0, kind: "sdt", spanStart: sm.index, spanEnd: sm.index + span.length,
      contentStart, contentEnd,
      label: alias || (pIdx >= 0 ? paras[pIdx].text : ""), paraIndex: pIdx,
    });
  }
  // (1b) Simple fields — <w:fldSimple w:instr="..."> ... </w:fldSimple>.
  const fsRe = /<w:fldSimple\b[^>]*>[\s\S]*?<\/w:fldSimple>/g;
  let fm: RegExpExecArray | null;
  while ((fm = fsRe.exec(xml))) {
    const span = fm[0];
    const pIdx = paraOf(fm.index);
    ctrls.push({
      ord: 0, kind: "fldSimple", spanStart: fm.index, spanEnd: fm.index + span.length,
      contentStart: fm.index, contentEnd: fm.index + span.length,
      label: attr(span.slice(0, span.indexOf(">") + 1), "w:instr") ?? (pIdx >= 0 ? paras[pIdx].text : ""),
      paraIndex: pIdx,
    });
  }
  // (1c) Legacy FORMTEXT form fields — best-effort: anchor the paragraph that
  //      carries the FORMTEXT instruction; on save the token is appended to it.
  const ftRe = /<w:instrText[^>]*>\s*FORMTEXT\s*<\/w:instrText>/g;
  let ftm: RegExpExecArray | null;
  while ((ftm = ftRe.exec(xml))) {
    const pIdx = paraOf(ftm.index);
    if (pIdx < 0) continue;
    ctrls.push({
      ord: 0, kind: "formtext", spanStart: ftm.index, spanEnd: ftm.index + ftm[0].length,
      contentStart: paras[pIdx].closeStart, contentEnd: paras[pIdx].closeStart,
      label: paras[pIdx].text, paraIndex: pIdx,
    });
  }
  ctrls.sort((a, b) => a.spanStart - b.spanStart);
  ctrls.forEach((c, i) => (c.ord = i));

  return { xml, paras, cells, ctrls };
}

// ---- token slug helpers -----------------------------------------------------
function slugToken(label: string, fallback: string): string {
  const s = (label || "").toLowerCase().replace(/[^a-z0-9]+/g, "_").replace(/^_+|_+$/g, "").slice(0, 40);
  return s || fallback;
}

const UNDERSCORE_RE = /_{3,}|\.{4,}|…{2,}|·{3,}/;

// ============================================================================
//  DETECT — produce the ordered list of blanks with stable anchors.
// ============================================================================
type Anchor =
  | { type: "sdt" | "fldSimple" | "formtext"; ord: number }
  | { type: "cell"; table: number; row: number; cell: number }
  | { type: "underscore"; para: number; run: number }
  | { type: "colon"; para: number };

type Blank = { id: string; kind: string; label: string; context: string; suggested_token: string; anchor: Anchor };

function detectBlanks(a: Analysis): Blank[] {
  const blanks: Blank[] = [];
  const claimedParas = new Set<number>();
  const claimedCells = new Set<string>();
  const usedTokens = new Set<string>();
  const cellKey = (t: number, r: number, c: number) => `${t}:${r}:${c}`;
  const uniqueToken = (label: string): string => {
    let base = slugToken(label, `field_${blanks.length + 1}`);
    let tok = base, n = 2;
    while (usedTokens.has(tok)) tok = `${base}_${n++}`;
    usedTokens.add(tok);
    return tok;
  };
  const push = (kind: string, label: string, context: string, anchor: Anchor) => {
    const lbl = (label || "").slice(0, 120);
    blanks.push({ id: `b${blanks.length + 1}`, kind, label: lbl, context: context.slice(0, 240), suggested_token: uniqueToken(lbl), anchor });
  };

  // Signal 1 — content controls / form fields (highest confidence).
  for (const c of a.ctrls) {
    if (c.paraIndex >= 0) claimedParas.add(c.paraIndex);
    if (c.paraIndex >= 0 && a.paras[c.paraIndex].cellRef) {
      const r = a.paras[c.paraIndex].cellRef!;
      claimedCells.add(cellKey(r.table, r.row, r.cell));
    }
    const ctx = c.paraIndex >= 0 ? a.paras[c.paraIndex].text : c.label;
    push(c.kind, c.label, ctx, { type: c.kind, ord: c.ord });
  }

  // Signal 2 — an empty <w:tc> cell adjacent to a non-empty label cell.
  const byRow = new Map<string, Cell[]>();
  for (const c of a.cells) {
    const k = `${c.table}:${c.row}`;
    (byRow.get(k) ?? byRow.set(k, []).get(k)!).push(c);
  }
  for (const [, row] of byRow) {
    row.sort((x, y) => x.cell - y.cell);
    for (let i = 0; i < row.length; i++) {
      const cell = row[i];
      const key = cellKey(cell.table, cell.row, cell.cell);
      if (claimedCells.has(key)) continue;
      if (cell.text.trim() !== "") continue;             // not a blank
      if (cell.firstParaClose === null) continue;         // nowhere to insert
      const label = row[i - 1] && row[i - 1].text.trim() !== "" ? row[i - 1].text : "";
      if (!label) continue;                               // need an adjacent label
      claimedCells.add(key);
      push("cell", label, label, { type: "cell", table: cell.table, row: cell.row, cell: cell.cell });
    }
  }

  // Signal 3 — underscore / dotted-leader runs.
  for (const p of a.paras) {
    if (claimedParas.has(p.index)) continue;
    if (p.cellRef && claimedCells.has(cellKey(p.cellRef.table, p.cellRef.row, p.cellRef.cell))) continue;
    const runIdx = p.runs.findIndex((r) => UNDERSCORE_RE.test(r.inner));
    if (runIdx < 0) continue;
    claimedParas.add(p.index);
    if (p.cellRef) claimedCells.add(cellKey(p.cellRef.table, p.cellRef.row, p.cellRef.cell));
    const label = p.text.replace(UNDERSCORE_RE, "").replace(/:$/, "").trim()
      || (p.index > 0 ? a.paras[p.index - 1].text : "");
    push("underscore", label, p.text, { type: "underscore", para: p.index, run: runIdx });
  }

  // Signal 4 — a colon-terminated label followed by a blank.
  for (const p of a.paras) {
    if (claimedParas.has(p.index)) continue;
    if (p.cellRef && claimedCells.has(cellKey(p.cellRef.table, p.cellRef.row, p.cellRef.cell))) continue;
    if (UNDERSCORE_RE.test(p.text)) continue;
    if (!/:$/.test(p.text.trim())) continue;
    claimedParas.add(p.index);
    if (p.cellRef) claimedCells.add(cellKey(p.cellRef.table, p.cellRef.row, p.cellRef.cell));
    const label = p.text.trim().replace(/:$/, "").trim();
    push("colon", label, p.text, { type: "colon", para: p.index });
  }

  return blanks;
}

// ============================================================================
//  MAP — Claude maps each blank's label/context to the CLOSED passport vocab.
//  Prompt carries ONLY blank labels/context (a blank client form => no candidate
//  data). `target` is closed by a schema enum AND re-validated server-side.
// ============================================================================
async function doMap(blanks: Blank[]) {
  const lite = blanks.map((b) => ({ id: b.id, kind: b.kind, label: b.label, context: b.context, suggested_token: b.suggested_token }));
  const resp = await anthropic.messages.create({
    model: MODEL,
    max_tokens: 4096,
    output_config: {
      effort: "low",
      format: {
        type: "json_schema",
        schema: {
          type: "object",
          properties: {
            mappings: {
              type: "array",
              items: {
                type: "object",
                properties: {
                  id: { type: "string" },
                  target: { type: "string", enum: [...PASSPORT_CATALOG, "static", "unmapped"] },
                  transform: { type: "string", enum: [...TRANSFORMS] },
                  static_value: { type: "string" },
                },
                required: ["id", "target"],
                additionalProperties: false,
              },
            },
            notes: { type: "string" },
          },
          required: ["mappings", "notes"],
          additionalProperties: false,
        },
      },
    },
    system:
      "You map answer-blanks detected in a BLANK UK healthcare-agency client checklist (a Word form) to fields " +
      "of a candidate 'Compliance Passport'. You are given ONLY each blank's nearby label/context text — never any " +
      "candidate's data. For each blank return exactly one `target`:\n" +
      "  · a passport FIELD KEY, which MUST be one of this closed list (never invent one): " +
      PASSPORT_CATALOG.join(", ") + ";\n" +
      "  · 'static' if the blank wants a constant that is the SAME for every candidate (agency name, PAYE ref, a " +
      "fixed office address) — then also give `static_value`;\n" +
      "  · 'unmapped' if no passport field fits (a human will decide).\n" +
      "Optionally set `transform` (one of: date_uk, yes_no, upper, title, with_provenance) when the form clearly wants a " +
      "formatted value — e.g. a date cell -> date_uk, a yes/no tick -> yes_no. Guidance: 'NMC/GMC/HCPC PIN' -> reg.number; " +
      "'registration expiry' -> reg.expiry (date_uk); 'DBS certificate number' -> dbs.number; 'DBS on update service' -> " +
      "dbs.update_service; 'share code' -> rtw.share_code; 'National Insurance' -> identity.ni_number; a bare 'Name' -> " +
      "identity.full_name; 'Date of birth' -> identity.dob (date_uk). Prefer 'unmapped' over a wrong guess.",
    messages: [{ role: "user", content: `Detected blanks (label/context only):\n${JSON.stringify(lite, null, 2)}` }],
  });
  const text = resp.content.filter((b: { type: string }) => b.type === "text").map((b: { text?: string }) => b.text ?? "").join("");
  const parsed = JSON.parse(text) as { mappings: { id: string; target: string; transform?: string; static_value?: string }[]; notes?: string };
  // Re-validate against the closed set server-side (defence in depth): anything
  // off-list collapses to 'unmapped', an unknown transform is dropped.
  const clean = (parsed.mappings ?? []).map((m) => ({
    id: m.id,
    target: TARGETS.has(m.target) ? m.target : "unmapped",
    transform: m.transform && XFORMS.has(m.transform) ? m.transform : "",
    static_value: typeof m.static_value === "string" ? m.static_value : "",
  }));
  return { mappings: clean, notes: parsed.notes ?? "" };
}

// ============================================================================
//  SAVE — splice a single-run {token} at each confirmed blank + write the row.
// ============================================================================
type MappingIn = {
  token?: string;
  target?: string;          // passport field key | 'static' | 'unmapped'
  field?: string | null;    // alias for target when it's a field key
  static?: string;
  transform?: string | null;
  required?: boolean;
  leave_blank?: boolean;
  anchor?: Anchor;
};

function tokenRun(token: string): string {
  // A SINGLE contiguous run carrying the docxtemplater placeholder. Writing it
  // ourselves as one <w:r> sidesteps docxtemplater's "token split across runs"
  // failure entirely.
  return `<w:r><w:t xml:space="preserve">{${token}}</w:t></w:r>`;
}

// Resolve a confirmed mapping's anchor to a concrete { start, end, text } splice
// on the freshly-analysed original XML. Returns null if the anchor can't be found.
function editForAnchor(a: Analysis, anchor: Anchor, token: string): { start: number; end: number; text: string } | null {
  const run = tokenRun(token);
  if (anchor.type === "sdt" || anchor.type === "fldSimple" || anchor.type === "formtext") {
    const c = a.ctrls.find((x) => x.kind === anchor.type && x.ord === anchor.ord);
    if (!c) return null;
    if (anchor.type === "sdt") return { start: c.contentStart, end: c.contentEnd, text: run };      // replace sdt content
    if (anchor.type === "fldSimple") return { start: c.spanStart, end: c.spanEnd, text: run };        // replace whole field
    return { start: c.contentStart, end: c.contentStart, text: run };                                 // formtext: append run in paragraph
  }
  if (anchor.type === "cell") {
    const c = a.cells.find((x) => x.table === anchor.table && x.row === anchor.row && x.cell === anchor.cell);
    if (!c || c.firstParaClose === null) return null;
    return { start: c.firstParaClose, end: c.firstParaClose, text: run };                             // append run before </w:p>
  }
  if (anchor.type === "underscore") {
    const p = a.paras[anchor.para];
    const r = p?.runs[anchor.run];
    if (!r) return null;
    return { start: r.tInnerStart, end: r.tInnerEnd, text: `{${token}}` };                            // replace the underscores in-run
  }
  if (anchor.type === "colon") {
    const p = a.paras[anchor.para];
    if (!p) return null;
    return { start: p.closeStart, end: p.closeStart, text: run };                                     // append run before </w:p>
  }
  return null;
}

async function doSave(body: {
  template_id?: string; client_name?: string; name?: string; original_path?: string;
  mappings?: MappingIn[]; missing_policy?: string;
}, callerSb: ReturnType<typeof createClient>) {
  const original_path = (body.original_path ?? "").toString();
  const client_name = (body.client_name ?? "").toString().trim();
  const name = (body.name ?? "").toString().trim();
  const mappings = Array.isArray(body.mappings) ? body.mappings : [];
  const missing_policy = body.missing_policy === "annotate" ? "annotate" : "block";
  if (!original_path) throw new Error("original_path required");
  if (!body.template_id && (!client_name || !name)) throw new Error("client_name and name required");

  // 1. Download the ORIGINAL (raw) client .docx and analyse it (same walk as detect).
  const { data: blob, error: dErr } = await svc.storage.from("checklist-templates").download(original_path);
  if (dErr || !blob) throw new Error("original not found");
  const rawBytes = new Uint8Array(await blob.arrayBuffer());
  const zip = new PizZip(rawBytes);
  const docFile = zip.file("word/document.xml");
  if (!docFile) throw new Error("not a .docx");
  const xml = docFile.asText();
  const a = analyze(xml);

  // 2. Build the field_map + the ordered set of splice edits for confirmed blanks.
  const fieldMap: { token: string; field: string | null; static?: string; required: boolean; transform?: string | null }[] = [];
  const edits: { start: number; end: number; text: string }[] = [];
  const usedTokens = new Set<string>();
  for (const m of mappings) {
    const target = (m.target ?? m.field ?? "").toString();
    if (m.leave_blank || target === "" || target === "unmapped") continue; // client fills manually
    const isStatic = target === "static";
    if (!isStatic && !CATALOG.has(target)) continue;                       // fail-closed: off-vocab ignored
    let token = slugToken((m.token ?? "").toString(), `field_${fieldMap.length + 1}`);
    while (usedTokens.has(token)) token = `${token}_${fieldMap.length + 1}`;
    usedTokens.add(token);

    if (!m.anchor) continue;
    const edit = editForAnchor(a, m.anchor, token);
    if (!edit) continue;                                                   // couldn't locate — skip, don't corrupt
    edits.push(edit);

    if (isStatic) {
      fieldMap.push({ token, field: null, static: (m.static ?? "").toString(), required: !!m.required });
    } else {
      const transform = m.transform && XFORMS.has(m.transform) ? m.transform : null;
      fieldMap.push({ token, field: target, required: !!m.required, transform });
    }
  }
  if (edits.length === 0) throw new Error("no confirmed mappings to write");

  // 3. Apply edits LAST-to-FIRST so earlier offsets stay valid, then re-zip.
  edits.sort((x, y) => y.start - x.start);
  let out = xml;
  for (const e of edits) out = out.slice(0, e.start) + e.text + out.slice(e.end);
  zip.file("word/document.xml", out);
  const tokenized = zip.generate({ type: "uint8array" });

  // 4. Upload the tokenized template alongside the untouched original (service role;
  //    the blank template holds no candidate data — same trust boundary as checklist-fill).
  const slugClient = (client_name || "template").replace(/[^a-zA-Z0-9._-]/g, "_");
  const template_path = `${slugClient}/${Date.now()}-tokenized.docx`;
  const { error: uErr } = await svc.storage.from("checklist-templates").upload(template_path, tokenized, {
    contentType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    upsert: false,
  });
  if (uErr) throw new Error("upload failed");

  // 5. INSERT/UPDATE the checklist_templates row UNDER THE CALLER'S JWT so the
  //    Phase-1 officer create/edit RLS applies (never the service role for this write).
  if (body.template_id) {
    const patch: Record<string, unknown> = { template_path, original_path, field_map: fieldMap, missing_policy, status: "draft" };
    if (name) patch.name = name;
    if (client_name) patch.client_name = client_name;
    const { error } = await callerSb.from("checklist_templates").update(patch).eq("id", body.template_id);
    if (error) throw new Error("not authorized to write template");
    return { template_id: body.template_id, template_path, tokens: fieldMap.length, field_map: fieldMap };
  }
  const { data, error } = await callerSb.from("checklist_templates")
    .insert({ client_name, name, template_path, original_path, field_map: fieldMap, missing_policy, status: "draft" })
    .select("id").single();
  if (error || !data) throw new Error("not authorized to write template");
  return { template_id: (data as { id: string }).id, template_path, tokens: fieldMap.length, field_map: fieldMap };
}

// ============================================================================
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (!authorized(req)) {
    return new Response(JSON.stringify({ error: "unauthorized" }), { status: 401, headers: CORS });
  }
  try {
    const body = await req.json();
    const mode = body?.mode;

    if (mode === "detect") {
      const template_path = (body.template_path ?? "").toString();
      if (!template_path) return new Response(JSON.stringify({ error: "template_path required" }), { status: 400, headers: CORS });
      const { data: blob, error } = await svc.storage.from("checklist-templates").download(template_path);
      if (error || !blob) throw new Error("template not found");
      const zip = new PizZip(new Uint8Array(await blob.arrayBuffer()));
      const docFile = zip.file("word/document.xml");
      if (!docFile) throw new Error("not a .docx");
      const blanks = detectBlanks(analyze(docFile.asText()));
      return new Response(JSON.stringify({ blanks, count: blanks.length }), { headers: CORS });
    }

    if (mode === "map") {
      const blanks = Array.isArray(body.blanks) ? body.blanks : [];
      if (blanks.length === 0) return new Response(JSON.stringify({ mappings: [], notes: "" }), { headers: CORS });
      return new Response(JSON.stringify(await doMap(blanks)), { headers: CORS });
    }

    if (mode === "save") {
      // Caller-JWT data client: the checklist_templates write runs under the
      // officer's auth.uid() so Phase-1 create/edit RLS decides access (not this code).
      const callerSb = createClient(
        Deno.env.get("SUPABASE_URL")!,
        Deno.env.get("SUPABASE_ANON_KEY")!,
        { db: { schema: "candidate" }, global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } },
      );
      return new Response(JSON.stringify(await doSave(body, callerSb)), { headers: CORS });
    }

    return new Response(JSON.stringify({ error: "mode must be 'detect', 'map' or 'save'" }), { status: 400, headers: CORS });
  } catch (_e) {
    // Fail-closed: generic message, nothing partial persisted (row written last).
    return new Response(JSON.stringify({ error: "onboarding failed" }), { status: 500, headers: CORS });
  }
});
