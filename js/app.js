// ============================================================================
//  Urgent Nursing Day Webster Outreach — Main App
// ============================================================================
//  Talks to a Supabase backend. All data persists in Postgres. Auth uses
//  Supabase magic-link email — no passwords.
//
//  Architecture:
//    - One `contacts` table with status column (lead/live/unsubscribed)
//    - `templates` table for email templates
//    - `email_sends` table logs every send (for last-emailed date + audit trail)
//    - `contacts_with_last_email` view joins the latest send date onto contacts
//    - RLS policies restrict access to authorised email domains
//
//  All database queries go through window.sb (the Supabase client).
// ============================================================================

// ---------- SUPABASE CLIENT ----------
const sb = window.supabase.createClient(window.CONFIG.SUPABASE_URL, window.CONFIG.SUPABASE_ANON_KEY);
window.sb = sb;

// ---------- STATE ----------
const state = {
  user: null,
  authLoading: true,
  view: 'dashboard',
  subTab: 'lead',
  search: '',
  regionFilter: '',
  countryFilter: '',
  page: 1,
  pageSize: 50,
  sortKey: 'org',
  sortDir: 'asc',
  // Cached data
  counts: { lead: 0, live: 0, unsubscribed: 0 },
  currentRows: [],
  totalRows: 0,
  regions: [],
  countries: [],
  templates: [],
  // Compose
  composeTemplateId: null,
  composeSourceFilter: 'all',
  composeListFilter: 'lead',
  composeRegionFilter: '',
  composeCountryFilter: '',
  composeTownFilter: '',
  composeBatchSize: 250,
  composeQueue: null,
  composeBatchId: null,
  composeIndex: 0,
  composeMode: null,
  composePreviewCounts: null,
  composeSelectedIds: null,   // IDs pre-selected from database for direct Brevo send
  composeBrevoSending: false,
  composeBrevoResult: null,
  // Modal
  modal: null,
  // Loading flags
  loadingPage: false,
  // Import / scraper
  importSpecialty: 'physiotherapy',
  importRegion: '',
  importBand: '7',
  importLimit: 20,
  importRunning: false,
  importResult: null,
  importSweepRunning: false,
  importSweepMsg: '',
  careHomeRunning: false,
  careHomeResult: null,
  userProfile: null,
  senderEmail: '',
  senderName: '',
  senderSaving: false,
  senderSaved: false,
  teamUsers: [],
  teamLoading: false,
  inviteEmail: '',
  inviteName: '',
  inviteSources: [],
  inviteSenderEmail: '',
  inviteSenderName: '',
  inviteResult: null,
  responsesLoading: false,
  responsesData: null,
  m365Syncing: false,
  m365SyncResult: null,
  m365ShowClientIdInput: false,
  m365ClientId: '',
  m365DaysBack: 30,
  expandedReplyId: null,
  addFromReplyLoading: false,
  // Per-source CSV upload state
  csvText_children_homes: '', csvPreview_children_homes: null, csvUploading_children_homes: false, csvResult_children_homes: null,
  csvText_care_home: '', csvPreview_care_home: null, csvUploading_care_home: false, csvResult_care_home: null,
  csvText_private_theatre: '', csvPreview_private_theatre: null, csvUploading_private_theatre: false, csvResult_private_theatre: null,
  agencyCsvText: null,
  agencyCsvPreview: null,
  agencyCsvSource: 'gp_surgery',
  enrichRunning: false,
  enrichResult: null,
  agencyUploading: false,
  agencyResult: null,
  agencyProgress: null,
  theatreRunning: false,
  theatreResult: null,
  // Dashboard
  dashboardLoading: false,
  dashboardData: null,
  // Database stage filter
  dbStage: 'all',
  // Source filter
  sourceFilter: 'all',
  sourceCounts: {},
  sourceStatusCounts: { lead: null, live: null, unsubscribed: null },
  ahpSpecialtyFilter: 'all',
  // Multi-select
  selected: new Set()
};

const STATUS_LABEL = { lead: 'Leads', live: 'Live', unsubscribed: 'Unsubscribes' };

// ---------- SOURCE HELPERS (for Add/Edit Contact modal) ----------
// Source is encoded as a tag inside the notes field. GP surgery is the default
// (no tag) — it's identified by exclusion. All other sources have a known tag.
const MODAL_SOURCE_TAGS = {
  gp_surgery:      null,
  children_homes:  'Ofsted Register',
  agency:          'Source: Agency Outreach',
  ahp:             'Source: NHS Jobs AHP',
  nhs_scotland:    'Source: NHS Scotland',
  private_theatre: 'Source: Theatres',
  care_home:       'Source: Care Home',
  bms:             'Source: BMS Outreach',
  sterile:         'Source: Sterile Services',
  nhs_staffbank:   'Source: NHS Staff Bank',
  camhs:           'Source: CAMHS',
  anp:             'Source: ANP',
  enp:             'Source: ENP',
};
const MODAL_SOURCE_OPTIONS = [
  { k: 'gp_surgery',      l: 'GP Surgery' },
  { k: 'children_homes',  l: "Children's Home" },
  { k: 'agency',          l: 'Agency Outreach' },
  { k: 'ahp',             l: 'AHP (NHS Jobs)' },
  { k: 'nhs_scotland',    l: 'NHS Scotland (AHP)' },
  { k: 'private_theatre', l: 'Theatres' },
  { k: 'care_home',       l: 'Care Home' },
  { k: 'bms',             l: 'BMS' },
  { k: 'sterile',         l: 'Sterile Services' },
  { k: 'nhs_staffbank',   l: 'NHS Staff Bank' },
  { k: 'camhs',           l: 'CAMHS' },
  { k: 'anp',             l: 'ANP' },
  { k: 'enp',             l: 'ENP' },
];

// Read the source key out of the notes field by scanning for any known tag.
function extractSource(notes) {
  if (!notes) return 'gp_surgery';
  for (const [key, tag] of Object.entries(MODAL_SOURCE_TAGS)) {
    if (tag && notes.includes(tag)) return key;
  }
  return 'gp_surgery';
}

// Return the user-facing notes (with any source tag removed). Splits on `|`
// so other metadata segments like "Specialty: physiotherapy | Band: 7" are
// preserved unchanged.
function stripSourceTag(notes) {
  if (!notes) return '';
  const tags = new Set(Object.values(MODAL_SOURCE_TAGS).filter(Boolean));
  return notes.split('|')
    .map(s => s.trim())
    .filter(s => s && !tags.has(s))
    .join(' | ');
}

// Build the notes field from a chosen source + the user-typed notes.
function combineSourceAndNotes(sourceKey, userNotes) {
  const tag = MODAL_SOURCE_TAGS[sourceKey];
  const cleanNotes = (userNotes || '').trim();
  if (!tag) return cleanNotes || null;  // GP surgery has no tag
  if (!cleanNotes) return tag;
  return tag + ' | ' + cleanNotes;
}

// ---------- UTILITIES ----------
function $(sel) { return document.querySelector(sel); }
function esc(s) { return String(s == null ? '' : s).replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c])); }
function todayStr() { return new Date().toISOString().slice(0, 10); }
function uid() { return 'b_' + Date.now() + '_' + Math.floor(Math.random() * 10000); }

function toast(msg, type) {
  const t = document.createElement('div');
  t.className = 'toast';
  t.textContent = msg;
  if (type === 'error') t.style.background = '#DC2626';
  document.body.appendChild(t);
  setTimeout(() => t.remove(), 3500);
}

function personalize(text, contact) {
  if (!text) return '';
  return text
    .replace(/\{\{FirstName\}\}/g, contact.first_name || '')
    .replace(/\{\{LastName\}\}/g, contact.last_name || '')
    .replace(/\{\{Title\}\}/g, contact.title || '')
    .replace(/\{\{Org\}\}/g, contact.org || 'your surgery')
    .replace(/\{\{Surgery\}\}/g, contact.org || 'your surgery')
    .replace(/\{\{Town\}\}/g, contact.town || 'your area')
    .replace(/\{\{Region\}\}/g, contact.region || '')
    .replace(/\{\{JobTitle\}\}/g, contact.job_title || '');
}

function convertTokensToMergeFields(text) {
  if (!text) return '';
  return text
    .replace(/\{\{FirstName\}\}/g, '«FirstName»')
    .replace(/\{\{LastName\}\}/g, '«LastName»')
    .replace(/\{\{Title\}\}/g, '«Title»')
    .replace(/\{\{Org\}\}/g, '«Org»')
    .replace(/\{\{Surgery\}\}/g, '«Org»')
    .replace(/\{\{Town\}\}/g, '«Town»')
    .replace(/\{\{Region\}\}/g, '«Region»')
    .replace(/\{\{JobTitle\}\}/g, '«JobTitle»');
}

function copyToClipboard(text, msg) {
  navigator.clipboard.writeText(text).then(() => {
    toast(msg || 'Copied to clipboard');
  }).catch(() => toast('Copy failed', 'error'));
}

function downloadFile(content, filename, type) {
  const blob = new Blob([content], { type: type || 'text/plain' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  setTimeout(() => { document.body.removeChild(a); URL.revokeObjectURL(url); }, 100);
}

function csvEscape(v) {
  const s = String(v == null ? '' : v);
  if (s.includes(',') || s.includes('"') || s.includes('\n')) {
    return '"' + s.replace(/"/g, '""') + '"';
  }
  return s;
}

// ============================================================================
//  AUTH
// ============================================================================

async function initAuth() {
  // Check existing session
  const { data: { session } } = await sb.auth.getSession();
  state.user = session ? session.user : null;
  state.authLoading = false;

  // Listen for changes
  sb.auth.onAuthStateChange((_event, session) => {
    state.user = session ? session.user : null;
    if (state.user) {
      bootApp();
    } else {
      render();
    }
  });
}

async function signIn(email, password) {
  const { error } = await sb.auth.signInWithPassword({ email, password });
  return error;
}

async function signOut() {
  await sb.auth.signOut();
  state.user = null;
  state.templates = [];
  state.currentRows = [];
  state.counts = { lead: 0, live: 0, unsubscribed: 0 };
  render();
}

function renderAuthScreen(errorMsg, infoMsg, savedEmail) {
  return `
    <div class="auth-container">
      <div class="auth-card">
        <img src="/dw-logo.svg" alt="Day Webster Group" />
        <h1>Day Webster Group Outreach</h1>
        <div class="subtitle">Sign in to continue</div>
        <div class="field">
          <input type="email" id="auth-email" placeholder="firstname.surname@daywebster.com" value="${esc(savedEmail || '')}" autofocus />
        </div>
        <div class="field">
          <input type="password" id="auth-password" placeholder="Password" />
        </div>
        <button id="auth-submit">Sign in</button>
        ${errorMsg ? `<div class="error">${esc(errorMsg)}</div>` : ''}
        ${infoMsg ? `<div class="info">${esc(infoMsg)}</div>` : `
          <div class="info">
            Only authorised Day Webster Group users can access this system.
            Contact Scott Lane if you need an account.
          </div>
        `}
      </div>
    </div>
  `;
}

function bindAuthEvents() {
  const btn = $('#auth-submit');
  const emailInput = $('#auth-email');
  const passwordInput = $('#auth-password');
  if (!btn || !emailInput || !passwordInput) return;

  const submit = async () => {
    const email = emailInput.value.trim();
    const password = passwordInput.value;
    if (!email || !email.includes('@')) {
      $('#app').innerHTML = renderAuthScreen('Please enter a valid email address.', null, email);
      bindAuthEvents();
      return;
    }
    if (!password) {
      $('#app').innerHTML = renderAuthScreen('Please enter your password.', null, email);
      bindAuthEvents();
      return;
    }
    btn.disabled = true;
    btn.textContent = 'Signing in...';
    const error = await signIn(email, password);
    if (error) {
      // Friendlier message for the most common failure
      const msg = (error.message || '').toLowerCase().includes('invalid')
        ? 'Wrong email or password. Try again, or contact Scott Lane if you need a reset.'
        : 'Sign-in failed: ' + error.message;
      $('#app').innerHTML = renderAuthScreen(msg, null, email);
      bindAuthEvents();
    }
    // On success, the onAuthStateChange listener triggers bootApp()
  };

  btn.addEventListener('click', submit);
  emailInput.addEventListener('keydown', e => { if (e.key === 'Enter') passwordInput.focus(); });
  passwordInput.addEventListener('keydown', e => { if (e.key === 'Enter') submit(); });
}

// ============================================================================
//  DATABASE QUERIES
// ============================================================================

async function loadStatusCounts() {
  const statuses = ['lead', 'live', 'unsubscribed'];
  const results = await Promise.all(statuses.map(s =>
    sb.from('contacts').select('*', { count: 'exact', head: true }).eq('status', s)
  ));
  statuses.forEach((s, i) => {
    state.counts[s] = results[i].count || 0;
  });
}


async function loadSourceStatusCounts() {
  // Load lead/live/unsub counts filtered by current source
  const sf = state.sourceFilter;
  if (sf === 'all') {
    // Reset to null so subtabs show global counts
    state.sourceStatusCounts = { lead: null, live: null, unsubscribed: null };
    return;
  }

  const SOURCE_TAGS = {
    gp_surgery:      null,
    children_homes:  'Ofsted Register',
    agency:          'Source: Agency Outreach',
    ahp:             'Source: NHS Jobs AHP',
    nhs_scotland:    'Source: NHS Scotland',
    private_theatre: 'Source: Theatres',
    care_home:       'Source: Care Home',
    bms:             'Source: BMS Outreach',
    sterile:         'Source: Sterile Services',
    nhs_staffbank:   'Source: NHS Staff Bank',
    camhs:           'Source: CAMHS',
    anp:             'Source: ANP',
    enp:             'Source: ENP',
  };

  function applyFilter(q) {
    if (sf === 'gp_surgery') {
      return q
        .not('notes', 'ilike', '%Ofsted Register%')
        .not('notes', 'ilike', '%Source: Agency%')
        .not('notes', 'ilike', '%Source: Pharmacy%')
        .not('notes', 'ilike', '%Source: BMS%')
        .not('notes', 'ilike', '%Source: Sterile%')
        .not('notes', 'ilike', '%Source: Theatres%')
        .not('notes', 'ilike', '%Source: NHS Staff Bank%')
        .not('notes', 'ilike', '%Source: NHS Jobs AHP%')
        .not('notes', 'ilike', '%Source: Care Home%')
        .not('notes', 'ilike', '%Source: CAMHS%');
    }
    const tag = SOURCE_TAGS[sf];
    if (tag) return q.ilike('notes', `%${tag}%`);
    return q;
  }

  const [leadRes, liveRes, unsubRes] = await Promise.all([
    applyFilter(sb.from('contacts').select('id', { count: 'exact', head: true })).eq('status', 'lead'),
    applyFilter(sb.from('contacts').select('id', { count: 'exact', head: true })).eq('status', 'live'),
    applyFilter(sb.from('contacts').select('id', { count: 'exact', head: true })).eq('status', 'unsubscribed'),
  ]);

  state.sourceStatusCounts = {
    lead:         leadRes.count  || 0,
    live:         liveRes.count  || 0,
    unsubscribed: unsubRes.count || 0,
  };
}

async function loadFilterOptions() {
  // Get distinct regions and countries (small, cacheable)
  const { data: rData } = await sb.from('contacts').select('region').not('region', 'is', null).neq('region', '');
  const { data: cData } = await sb.from('contacts').select('country').not('country', 'is', null).neq('country', '');
  state.regions = Array.from(new Set((rData || []).map(r => r.region))).filter(r => r && !/^\d+$/.test(String(r).trim())).sort();
  state.countries = Array.from(new Set((cData || []).map(r => r.country))).sort();
}


async function loadSourceCounts() {
  const [allRes, chRes, ahpRes, agencyRes, theatreRes, careRes, gpRes, anpRes, enpRes, scotRes] = await Promise.all([
    sb.from('contacts').select('id', { count: 'exact', head: true }),
    sb.from('contacts').select('id', { count: 'exact', head: true })
      .ilike('notes', '%Ofsted Register%'),
    sb.from('contacts').select('id', { count: 'exact', head: true })
      .ilike('notes', '%Source: NHS Jobs AHP%'),
    sb.from('contacts').select('id', { count: 'exact', head: true })
      .ilike('notes', '%Source: Agency Outreach%'),
    sb.from('contacts').select('id', { count: 'exact', head: true })
      .ilike('notes', '%Source: Theatres%'),
    sb.from('contacts').select('id', { count: 'exact', head: true })
      .ilike('notes', '%Source: Care Home%'),
    sb.from('contacts').select('id', { count: 'exact', head: true })
      .not('notes', 'ilike', '%Ofsted Register%')
      .not('notes', 'ilike', '%Source: Agency%')
      .not('notes', 'ilike', '%Source: Pharmacy%')
      .not('notes', 'ilike', '%Source: BMS%')
      .not('notes', 'ilike', '%Source: Sterile%')
      .not('notes', 'ilike', '%Source: Theatres%')
      .not('notes', 'ilike', '%Source: NHS Staff Bank%')
      .not('notes', 'ilike', '%Source: NHS Jobs AHP%')
      .not('notes', 'ilike', '%Source: Care Home%')
      .not('notes', 'ilike', '%Source: CAMHS%')
      .not('notes', 'ilike', '%Source: ANP%')
      .not('notes', 'ilike', '%Source: ENP%')
      .not('notes', 'ilike', '%Source: NHS Scotland%'),
    sb.from('contacts').select('id', { count: 'exact', head: true })
      .ilike('notes', '%Source: ANP%'),
    sb.from('contacts').select('id', { count: 'exact', head: true })
      .ilike('notes', '%Source: ENP%'),
    sb.from('contacts').select('id', { count: 'exact', head: true })
      .ilike('notes', '%Source: NHS Scotland%'),
  ]);
  state.sourceCounts = {
    all:             allRes.count     || 0,
    gp_surgery:      gpRes.count      || 0,
    children_homes:  chRes.count      || 0,
    ahp:             ahpRes.count     || 0,
    agency:          agencyRes.count  || 0,
    private_theatre: theatreRes.count || 0,
    care_home:       careRes.count    || 0,
    anp:             anpRes.count     || 0,
    enp:             enpRes.count     || 0,
    nhs_scotland:    scotRes.count    || 0,
  };
  try {
    var dayStart = new Date(); dayStart.setHours(0,0,0,0);
    var tRes = await sb.from('contacts').select('notes').gte('created_at', dayStart.toISOString()).limit(3000);
    var todayRows = tRes.data || [];
    var tc = { all: todayRows.length, gp_surgery: 0, children_homes: 0, ahp: 0, agency: 0, private_theatre: 0, care_home: 0, anp: 0, enp: 0, nhs_scotland: 0 };
    todayRows.forEach(function(r){
      var n = (r.notes || '').toLowerCase();
      if (n.indexOf('ofsted register') >= 0) { tc.children_homes++; }
      else if (n.indexOf('source: nhs jobs ahp') >= 0) { tc.ahp++; }
      else if (n.indexOf('source: nhs scotland') >= 0) { tc.nhs_scotland++; }
      else if (n.indexOf('source: agency outreach') >= 0) { tc.agency++; }
      else if (n.indexOf('source: theatres') >= 0) { tc.private_theatre++; }
      else if (n.indexOf('source: care home') >= 0) { tc.care_home++; }
      else if (n.indexOf('source: anp') >= 0) { tc.anp++; }
      else if (n.indexOf('source: enp') >= 0) { tc.enp++; }
      else if (n.indexOf('source: pharmacy') >= 0 || n.indexOf('source: bms') >= 0 || n.indexOf('source: sterile') >= 0 || n.indexOf('source: nhs staff bank') >= 0 || n.indexOf('source: camhs') >= 0) { }
      else { tc.gp_surgery++; }
    });
    state.newTodayCounts = tc;
  } catch (e) { state.newTodayCounts = null; }
}

async function loadContactsPage() {
  state.loadingPage = true;
  state.selected = new Set();
  const start = (state.page - 1) * state.pageSize;
  const end = start + state.pageSize - 1;

  let query = sb.from('contacts_with_last_email').select('*', { count: 'exact' })
    .eq('status', state.subTab);

  // Stage filter — only applies to leads (unsubscribed have stage='opted_out', live have stage='live')
  if (state.subTab === 'lead') {
    const today2 = new Date().toISOString().split('T')[0];
    if (state.dbStage === 'followup') {
      query = query.lte('follow_up_date', today2).not('follow_up_date', 'is', null);
    } else if (state.dbStage && state.dbStage !== 'all') {
      query = query.eq('stage', state.dbStage);
    }
  }

  // ── Source filter ──────────────────────────────────────────────────────────
  const sf = state.sourceFilter;
  if (sf === 'children_homes') {
    query = query.ilike('notes', '%Ofsted Register%');
  } else if (sf === 'gp_surgery') {
    query = query
      .not('notes', 'ilike', '%Ofsted Register%')
      .not('notes', 'ilike', '%Source: Agency%')
      .not('notes', 'ilike', '%Source: Pharmacy%')
      .not('notes', 'ilike', '%Source: BMS%')
      .not('notes', 'ilike', '%Source: Sterile%')
      .not('notes', 'ilike', '%Source: Theatres%')
      .not('notes', 'ilike', '%Source: NHS Staff Bank%')
      .not('notes', 'ilike', '%Source: NHS Jobs AHP%')
      .not('notes', 'ilike', '%Source: Care Home%')
      .not('notes', 'ilike', '%Source: CAMHS%')
      .not('notes', 'ilike', '%Source: ANP%')
      .not('notes', 'ilike', '%Source: ENP%')
      .not('notes', 'ilike', '%Source: NHS Scotland%');
  } else if (sf === 'ahp') {
    query = query.ilike('notes', '%Source: NHS Jobs AHP%');
    if (state.ahpSpecialtyFilter && state.ahpSpecialtyFilter !== 'all') {
      query = query.ilike('notes', `%Specialty: ${state.ahpSpecialtyFilter}%`);
    }
  } else if (sf === 'nhs_scotland') {
    query = query.ilike('notes', '%Source: NHS Scotland%');
    if (state.ahpSpecialtyFilter && state.ahpSpecialtyFilter !== 'all') {
      query = query.ilike('notes', `%Specialty: ${state.ahpSpecialtyFilter}%`);
    }
  } else if (sf === 'agency') {
    query = query.ilike('notes', '%Source: Agency Outreach%');
  } else if (sf === 'private_theatre') {
    query = query.ilike('notes', '%Source: Theatres%');
  } else if (sf === 'bms') {
    query = query.ilike('notes', '%Source: BMS Outreach%');
  } else if (sf === 'sterile') {
    query = query.ilike('notes', '%Source: Sterile Services%');
  } else if (sf === 'nhs_staffbank') {
    query = query.ilike('notes', '%Source: NHS Staff Bank%');
  } else if (sf === 'camhs') {
    query = query.ilike('notes', '%Source: CAMHS%');
  } else if (sf === 'care_home') {
    query = query.ilike('notes', '%Source: Care Home%');
  } else if (sf === 'anp') {
    query = query.ilike('notes', '%Source: ANP%');
  } else if (sf === 'enp') {
    query = query.ilike('notes', '%Source: ENP%');
  }
  // sf === 'all' — no filter applied
  // ──────────────────────────────────────────────────────────────────────────

  if (state.regionFilter) query = query.eq('region', state.regionFilter);
  if (state.countryFilter) query = query.eq('country', state.countryFilter);

  if (state.search) {
    const q = state.search.replace(/[%_]/g, '\\$&'); // basic SQL wildcard escaping
    query = query.or(
      `first_name.ilike.%${q}%,last_name.ilike.%${q}%,org.ilike.%${q}%,` +
      `email.ilike.%${q}%,town.ilike.%${q}%,postcode.ilike.%${q}%`
    );
  }

  query = query.order(state.sortKey, { ascending: state.sortDir === 'asc' }).range(start, end);

  const { data, error, count } = await query;
  state.loadingPage = false;

  if (error) {
    toast('Failed to load contacts: ' + error.message, 'error');
    state.currentRows = [];
    state.totalRows = 0;
    return;
  }
  state.currentRows = data || [];
  state.totalRows = count || 0;
}

async function loadTemplates() {
  const { data, error } = await sb.from('templates').select('*').order('name');
  if (error) {
    toast('Failed to load templates: ' + error.message, 'error');
    return;
  }
  state.templates = data || [];
}

async function addContact(c) {
  const { data, error } = await sb.from('contacts').insert([c]).select().single();
  return { data, error };
}

async function updateContactById(id, updates) {
  const { data, error } = await sb.from('contacts').update(updates).eq('id', id).select().single();
  return { data, error };
}

async function deleteContactById(id) {
  const { error } = await sb.from('contacts').delete().eq('id', id);
  return error;
}

async function setContactStatus(id, status) {
  return updateContactById(id, { status });
}

async function addTemplate(t) {
  const { data, error } = await sb.from('templates').insert([t]).select().single();
  return { data, error };
}

async function updateTemplateById(id, updates) {
  const { data, error } = await sb.from('templates').update(updates).eq('id', id).select().single();
  return { data, error };
}

async function deleteTemplateById(id) {
  const { error } = await sb.from('templates').delete().eq('id', id);
  return error;
}

async function logEmailSend(contactId, templateId, batchId, status, notes) {
  const { error } = await sb.from('email_sends').insert([{
    contact_id: contactId,
    template_id: templateId,
    batch_id: batchId,
    status: status || 'sent',
    notes: notes || null
  }]);
  if (error) console.error('Send log failed:', error);
  return error;
}

async function logBatchSends(contactIds, templateId, batchId) {
  const rows = contactIds.map(id => ({
    contact_id: id,
    template_id: templateId,
    batch_id: batchId,
    status: 'sent'
  }));
  // Insert in chunks of 500 to stay well under request size limits
  const CHUNK = 500;
  for (let i = 0; i < rows.length; i += CHUNK) {
    const chunk = rows.slice(i, i + CHUNK);
    const { error } = await sb.from('email_sends').insert(chunk);
    if (error) {
      toast('Batch logging failed at row ' + i + ': ' + error.message, 'error');
      return error;
    }
  }
}

// Apply source filter to a Supabase query (same logic as database view)
function applyComposeSourceFilter(q, source) {
  if (source === 'gp_surgery') {
    return q
      .not('notes', 'ilike', '%Ofsted Register%')
      .not('notes', 'ilike', '%Source: Agency%')
      .not('notes', 'ilike', '%Source: Pharmacy%')
      .not('notes', 'ilike', '%Source: BMS%')
      .not('notes', 'ilike', '%Source: Sterile%')
      .not('notes', 'ilike', '%Source: Theatres%')
      .not('notes', 'ilike', '%Source: NHS Staff Bank%')
      .not('notes', 'ilike', '%Source: NHS Theatre%')
      .not('notes', 'ilike', '%Source: CAMHS%')
      .not('notes', 'ilike', '%Source: NHS Jobs AHP%')
      .not('notes', 'ilike', '%Source: Care Home%')
      .not('notes', 'ilike', '%Source: ANP%')
      .not('notes', 'ilike', '%Source: ENP%')
      .not('notes', 'ilike', '%Source: NHS Scotland%');
  }
  const SOURCE_TAGS = {
    children_homes:  'Ofsted Register',
    agency:          'Source: Agency Outreach',
    ahp:             'Source: NHS Jobs AHP',
    nhs_scotland:    'Source: NHS Scotland',
    private_theatre: 'Source: Theatres',
    bms:             'Source: BMS Outreach',
    sterile:         'Source: Sterile Services',
    nhs_staffbank:   'Source: NHS Staff Bank',
    ahp:             'Source: NHS Jobs AHP',
    camhs:           'Source: CAMHS',
    anp:             'Source: ANP',
    enp:             'Source: ENP',
  };
  const tag = SOURCE_TAGS[source];
  if (tag) return q.ilike('notes', `%${tag}%`);
  return q; // 'all' — no filter
}

async function buildComposeQueueFromDb() {
  let query = sb.from(state.composeUncontactedOnly ? 'contacts_with_last_email' : 'contacts').select('*').eq('status', state.composeListFilter);
  query = applyComposeSourceFilter(query, state.composeSourceFilter);
  if ((state.composeSourceFilter === 'ahp' || state.composeSourceFilter === 'nhs_scotland') && state.composeSpecialtyFilter && state.composeSpecialtyFilter !== 'all') query = query.eq('department', state.composeSpecialtyFilter);
  if (state.composeRegionFilter) query = query.eq('region', state.composeRegionFilter);
  if (state.composeCountryFilter) query = query.eq('country', state.composeCountryFilter);
  if (state.composeTownFilter) query = query.ilike('town', `%${state.composeTownFilter}%`);
    if (state.composeUncontactedOnly) query = query.is('last_emailed_at', null);

  // Sort and limit to batch size + small buffer for invalid emails
  query = query.order('updated_at', { ascending: true }).limit(state.composeBatchSize * 2);

  const { data, error } = await query;
  if (error) {
    toast('Failed to load contacts for compose: ' + error.message, 'error');
    return [];
  }
  // Filter to those with a valid email and take batch size
  return (data || []).filter(c => c.email && c.email.includes('@')).slice(0, state.composeBatchSize);
}

async function previewComposeCounts() {
  // Count matching the current filters
  let q = sb.from(state.composeUncontactedOnly ? 'contacts_with_last_email' : 'contacts').select('*', { count: 'exact', head: true })
    .eq('status', state.composeListFilter);
  q = applyComposeSourceFilter(q, state.composeSourceFilter);
  if ((state.composeSourceFilter === 'ahp' || state.composeSourceFilter === 'nhs_scotland') && state.composeSpecialtyFilter && state.composeSpecialtyFilter !== 'all') q = q.eq('department', state.composeSpecialtyFilter);
  if (state.composeRegionFilter) q = q.eq('region', state.composeRegionFilter);
  if (state.composeCountryFilter) q = q.eq('country', state.composeCountryFilter);
  if (state.composeTownFilter) q = q.ilike('town', `%${state.composeTownFilter}%`);
  if (state.composeUncontactedOnly) q = q.is('last_emailed_at', null);
  const { count } = await q;
  return { matching: count || 0 };
}

// ============================================================================
//  RENDER — top-level dispatch
// ============================================================================

async function bootApp() {
  $('#app').innerHTML = '<div style="padding:40px;text-align:center;color:#6B7280;">Loading data...</div>';
  await Promise.all([loadStatusCounts(), loadSourceCounts(), loadSourceStatusCounts(), loadTemplates(), loadFilterOptions()]);
  await loadContactsPage();
  render();
  loadDashboard();
  loadUserProfile().then(function() { render(); });
}

function render() {
  if (state.authLoading) {
    $('#app').innerHTML = '<div style="padding:40px;text-align:center;color:#6B7280;">Loading...</div>';
    return;
  }
  if (!state.user) {
    $('#app').innerHTML = renderAuthScreen();
    bindAuthEvents();
    return;
  }
  $('#app').innerHTML = renderAppShell();
  bindEvents();
  if (state.modal) renderModal();
}

function renderAppShell() {
  const totalCount = state.counts.lead + state.counts.live + state.counts.unsubscribed;
  return `
    <div class="header">
      <img src="/dw-logo.svg" alt="Day Webster Group" />
      <h1>Day Webster Group Outreach</h1>
      <span class="badge">${state.counts.lead} Leads · ${state.counts.live} Live · ${state.counts.unsubscribed} Unsubs</span>
      <span class="user-pill">${esc(state.user.email)} <button id="sign-out-btn" title="Sign out">Sign out</button></span>
    </div>
    <div class="tabs">
      <div class="tab ${state.view === 'dashboard' ? 'active' : ''}" data-view="dashboard">Dashboard</div>
      <div class="tab ${state.view === 'database' ? 'active' : ''}" data-view="database">Database</div>
      <div class="tab ${state.view === 'templates' ? 'active' : ''}" data-view="templates">Templates</div>
      <div class="tab ${state.view === 'compose' ? 'active' : ''}" data-view="compose">Compose</div>
      <div class="tab ${state.view === 'settings' ? 'active' : ''}" data-view="settings">Settings</div>
      <div class="tab ${state.view === 'import' ? 'active' : ''}" data-view="import">⬇ Import</div>
      <div class="tab ${state.view === 'responses' ? 'active' : ''}" data-view="responses">&#x1F4EC; Responses</div>
    </div>
    <div class="main" id="main">
      ${state.view === 'dashboard' ? renderDashboard() :
        state.view === 'database' ? renderDatabase() :
        state.view === 'templates' ? renderTemplates() :
        state.view === 'compose' ? renderCompose() :
        state.view === 'import' ? renderImport() :
        state.view === 'responses' ? renderResponses() :
        renderSettings()}
    </div>
  `;
}

function extractSpecialty(notes) {
  if (!notes) return '—';
  const m = notes.match(/Specialty: ([^|]+)/);
  return m ? m[1].trim().replace(/_/g,' ') : '—';
}

function renderFollowUpDate(d) {
  if (!d) return '<span class="muted">—</span>';
  const due = d <= new Date().toISOString().split('T')[0];
  return '<span class="followup-date' + (due ? ' followup-due' : '') + '">' + esc(d) + '</span>';
}

function renderDatabase() {
  const SOURCES = [
    { key: 'all',             label: 'All Sources'       },
    { key: 'gp_surgery',      label: 'GP Surgeries'      },
    { key: 'children_homes',  label: "Children's Homes"  },
    { key: 'agency',          label: 'Agency Outreach'   },
    { key: 'ahp',             label: 'NHS Jobs AHP'      },
    { key: 'nhs_scotland',    label: 'NHS Scotland'     },
    { key: 'anp',             label: 'ANP'               },
    { key: 'enp',             label: 'ENP'               },
    { key: 'care_home',       label: 'Care Homes'        },
    { key: 'private_theatre', label: 'Theatres'  },
  ];

  const total = state.totalRows;
  const start = (state.page - 1) * state.pageSize;
  const totalPages = Math.max(1, Math.ceil(total / state.pageSize));
  const selN = state.selected.size;
  const allPageSel = selN > 0 && selN === state.currentRows.length;
  const somePageSel = selN > 0 && !allPageSel;

  return `
    <div class="source-tabs">
      ${SOURCES.map(s => {
        const cnt = state.sourceCounts[s.key];
        const isEmpty = cnt === 0;
        const isActive = state.sourceFilter === s.key;
        return `<button class="source-tab${isActive ? ' active' : ''}${isEmpty ? ' source-empty' : ''}" data-source="${s.key}">
          ${esc(s.label)}
          ${cnt != null ? `<span class="source-count${isEmpty ? ' zero' : ''}">${Number(cnt).toLocaleString()}</span>` : ''}
          ${state.newTodayCounts && state.newTodayCounts[s.key] > 0 ? `<span class="source-new" style="background:#16A34A;color:#fff;border-radius:10px;padding:1px 7px;font-size:11px;font-weight:600;margin-left:4px;">+${state.newTodayCounts[s.key]} today</span>` : ''}
          ${s.key === 'children_homes' && cnt > 0 ? '<span class="source-warn" title="Most have placeholder emails — run enrichment from Import tab">⚠</span>' : ''}
        </button>`;
      }).join('')}
    </div>

    ${selN > 0 ? `
    <div class="batch-bar">
      <span class="batch-count">${selN} selected</span>

      ${state.subTab === 'lead' ? `
        <button class="btn small batch-btn live-btn" data-bulk="move-to-live">→ Mark as Live</button>
        <button class="btn small batch-btn" data-bulk="unsubscribe">⊘ Unsubscribe</button>
        <div class="batch-sep"></div>
        <button class="btn small batch-btn stage-btn" data-bulk="stage-responded">✓ Responded</button>
        <button class="btn small batch-btn stage-btn" data-bulk="stage-meeting">📅 Meeting</button>
        <button class="btn small batch-btn compose-btn" data-bulk="send-compose">✉ Send via Brevo (${selN})</button>
      ` : state.subTab === 'live' ? `
        <button class="btn small batch-btn" data-bulk="restore">→ Move to Leads</button>
        <button class="btn small batch-btn" data-bulk="unsubscribe">⊘ Unsubscribe</button>
        <button class="btn small batch-btn compose-btn" data-bulk="send-compose">✉ Send via Brevo (${selN})</button>
      ` : `
        <button class="btn small batch-btn" data-bulk="restore">↺ Restore to Leads</button>
        <button class="btn small batch-btn live-btn" data-bulk="move-to-live">→ Mark as Live</button>
      `}

      <button class="btn small batch-btn danger" data-bulk="delete">✕ Delete</button>
      <button class="btn small batch-btn secondary" data-bulk="clear">Clear</button>
    </div>` : ''}

    ${state.sourceFilter === 'ahp' ? `
    <div class="specialty-tabs">
      ${[
        {k:'all',              l:'All Specialties'},
        {k:'physiotherapy',    l:'Physiotherapy'},
        {k:'occupational_therapy', l:'OT'},
        {k:'radiography',      l:'Radiography'},
        {k:'speech_language',  l:'Speech & Language'},
        {k:'dietetics',        l:'Dietetics'},
        {k:'podiatry',         l:'Podiatry'},
        {k:'orthoptics',       l:'Orthoptics'},
        {k:'art_therapy',      l:'Arts Therapies'},
        {k:'paramedic',        l:'Paramedic'},
        {k:'prosthetics',      l:'Prosthetics'},
        {k:'pharmacy',         l:'Pharmacy (NHS)'},
        {k:'biomedical_science', l:'BMS'},
        {k:'sterile_services', l:'Sterile Services'},
        {k:'mental_health', l:'Mental Health'},
        {k:'operating_theatres', l:'Theatres'},
        {k:'audiology', l:'Audiology'},
        {k:'gp_surgery',      l:'GP Surgeries'},
      ].map(s => `<button class="stage-tab${state.ahpSpecialtyFilter===s.k?' active':''}" data-specialty="${s.k}">${s.l}</button>`).join('')}
    </div>` : ''}

    ${state.subTab === 'lead' ? `
    <div class="stage-tabs">
      ${[
        {k:'all',       l:'All'},
        {k:'new',       l:'New'},
        {k:'contacted', l:'Contacted'},
        {k:'responded', l:'Responded'},
        {k:'meeting',   l:'Meeting'},
        {k:'followup',  l:'Follow-up Due'},
      ].map(s => `<button class="stage-tab${state.dbStage===s.k?' active':''}" data-dstage="${s.k}">${s.l}</button>`).join('')}
    </div>` : ''}
    <div class="subtabs">
      <div class="subtab ${state.subTab === 'lead' ? 'active' : ''}" data-subtab="lead">
        Leads
        <span class="count">${state.sourceStatusCounts.lead !== null ? state.sourceStatusCounts.lead.toLocaleString() : state.counts.lead.toLocaleString()}</span>
      </div>
      <div class="subtab ${state.subTab === 'live' ? 'active' : ''}" data-subtab="live">
        Live
        <span class="count">${state.sourceStatusCounts.live !== null ? state.sourceStatusCounts.live.toLocaleString() : state.counts.live.toLocaleString()}</span>
      </div>
      <div class="subtab ${state.subTab === 'unsubscribed' ? 'active' : ''}" data-subtab="unsubscribed">
        Unsubscribes
        <span class="count">${state.sourceStatusCounts.unsubscribed !== null ? state.sourceStatusCounts.unsubscribed.toLocaleString() : state.counts.unsubscribed.toLocaleString()}</span>
      </div>
    </div>
    <div class="toolbar">
      <input class="search" id="search-input" placeholder="Search by name, surgery, email, town, postcode..." value="${esc(state.search)}" />
      <select class="select" id="region-filter">
        <option value="">All regions</option>
        ${state.regions.map(r => `<option value="${esc(r)}" ${state.regionFilter===r?'selected':''}>${esc(r)}</option>`).join('')}
      </select>
      <select class="select" id="country-filter">
        <option value="">All countries</option>
        ${state.countries.map(c => `<option value="${esc(c)}" ${state.countryFilter===c?'selected':''}>${esc(c)}</option>`).join('')}
      </select>
      <button class="btn primary" id="add-contact-btn">+ Add Contact</button>
    </div>
    <div class="muted" style="margin-bottom:8px;">
      ${state.loadingPage ? 'Loading...' : `Showing ${total === 0 ? 0 : start + 1}–${Math.min(start + state.pageSize, total)} of ${total}`}
    </div>
    <div class="table-wrap">
      ${total === 0 && !state.loadingPage ? '<div class="empty">No contacts match your filters.</div>' : `
      <table class="table">
        <thead>
          <tr>
            <th style="width:36px;text-align:center">
              <input type="checkbox" id="select-all-cb" ${allPageSel ? 'checked' : ''} />
            </th>
            ${!['ahp','anp','enp','nhs_scotland'].includes(state.sourceFilter) ? `<th data-sort="org">Surgery / Org</th><th data-sort="first_name">Contact</th><th data-sort="job_title">Role</th><th data-sort="email">Email</th><th data-sort="town">Town</th><th data-sort="region">Region</th>` : ''}
            ${['ahp','anp','enp','nhs_scotland'].includes(state.sourceFilter) ? `
              <th>Contact Name</th>
              <th>Job Title</th><th>Vacancy</th>
              <th>Email</th>
              <th>Phone</th>
              <th>NHS Trust</th>
              <th>Specialty</th>
              <th>Last Emailed</th>
              <th>Band</th>
              <th>Date Added</th>
              <th>NHS Jobs</th>` : `
              <th data-sort="last_emailed_at">Last Emailed</th>
              <th data-sort="follow_up_date">Follow-up</th>`}
            <th>Actions</th>
          </tr>
        </thead>
        <tbody>
          ${state.currentRows.map(c => `
            <tr class="${state.selected.has(c.id) ? 'row-selected' : ''}">
              <td style="width:36px;text-align:center">
                <input type="checkbox" class="row-cb" data-id="${c.id}" ${state.selected.has(c.id) ? 'checked' : ''} />
              </td>
              ${!['ahp','anp','enp','nhs_scotland'].includes(state.sourceFilter) ? `
              <td class="ellipsis" title="${esc(c.org)}">${esc(c.org)}</td>
              <td>${esc([c.title, c.first_name, c.last_name].filter(Boolean).join(' '))}</td>
              <td>${esc(c.job_title)}</td>
              <td class="ellipsis" title="${esc(c.email)}">${esc(c.email)}</td>
              <td>${esc(c.town)}</td>
              <td>${esc(c.region)}</td>` : ''}
              ${['ahp','anp','enp','nhs_scotland'].includes(state.sourceFilter)
                ? `<td>${esc(([c.first_name,c.last_name].filter(Boolean).join(' ')) || '—')}</td>
                   <td>${esc(c.job_title || '—')}</td><td>${esc(c.vacancy_title || '—')}</td>
                   <td class="ellipsis" title="${esc(c.email)}">${esc(c.email || '—')}</td>
                   <td>${esc(c.phone || '—')}</td>
                   <td class="ellipsis" title="${esc(c.org)}">${esc(c.org || '—')}</td>
                   <td>${esc(extractSpecialty(c.notes))}</td>
                   <td>${c.last_emailed_at ? esc(c.last_emailed_at.slice(0, 10)) : '<span class="muted">—</span>'}</td>
                   <td>${esc(c.band_requested || '—')}</td>
                   <td>${c.created_at ? esc(c.created_at.slice(0,10)) : '—'}</td>
                   <td>${c.source_url ? `<a href="${esc(c.source_url)}" target="_blank" rel="noopener" class="nhs-jobs-link" title="View on NHS Jobs">🔗 NHS Jobs</a>` : '<span class="muted">—</span>'}</td>`
                : `<td>${c.last_emailed_at ? esc(c.last_emailed_at.slice(0, 10)) : '<span class="muted">—</span>'}</td>
                <td>${renderFollowUpDate(c.follow_up_date)}</td>`}
              <td class="actions">
                <button class="btn small" data-action="edit" data-id="${c.id}">Edit</button>
                ${c.status !== 'lead' ? `<button class="btn small" data-action="move-lead" data-id="${c.id}">→ Leads</button>` : ''}
                ${c.status !== 'live' ? `<button class="btn small" data-action="move-live" data-id="${c.id}">→ Live</button>` : ''}
                ${c.status !== 'unsubscribed' ? `<button class="btn small" data-action="move-unsub" data-id="${c.id}">→ Unsubs</button>` : ''}
                <button class="btn small danger" data-action="delete" data-id="${c.id}">Delete</button>
              </td>
            </tr>
          `).join('')}
        </tbody>
      </table>
      <div class="pagination">
        <div>Page ${state.page} of ${totalPages}</div>
        <div class="pages">
          <button class="page-btn" data-page="1" ${state.page === 1 ? 'disabled' : ''}>‹‹</button>
          <button class="page-btn" data-page="${state.page - 1}" ${state.page === 1 ? 'disabled' : ''}>‹ Prev</button>
          <button class="page-btn" data-page="${state.page + 1}" ${state.page === totalPages ? 'disabled' : ''}>Next ›</button>
          <button class="page-btn" data-page="${totalPages}" ${state.page === totalPages ? 'disabled' : ''}>››</button>
        </div>
      </div>
      `}
    </div>
  `;
}

function renderTemplates() {
  return `
    <div class="toolbar">
      <h2 class="section-title" style="margin:0;flex:1;">Email Templates</h2>
      <button class="btn primary" id="add-template-btn">+ New Template</button>
    </div>
    <div class="token-helper">
      <strong>Available personalisation tokens</strong> — paste these into any template:
      <code>{{FirstName}}</code> <code>{{LastName}}</code> <code>{{Name}}</code>
      <code>{{VacancyTitle}}</code> <code>{{Org}}</code> <code>{{Band}}</code> <code>{{Specialty}}</code>
      <code>{{Town}}</code> <code>{{Region}}</code> <code>{{Title}}</code> <code>{{SenderName}}</code>
      <div class="muted" style="margin-top:8px;font-size:12px;line-height:1.55;">
        <strong>{{VacancyTitle}}</strong> = the exact role from their advert (e.g. &ldquo;Band 6 Physiotherapist&rdquo;) &mdash; the key token for NHS Jobs &amp; GP leads. <code>{{Vacancy}}</code> and <code>{{Role}}</code> are the same thing. <code>{{Band}}</code> and <code>{{Specialty}}</code> also come from the advert. Everything degrades gracefully if a field is blank (e.g. {{FirstName}} &rarr; &ldquo;there&rdquo;, {{Org}} &rarr; &ldquo;your organisation&rdquo;). Heads-up: {{Town}} and {{Region}} are usually empty on NHS Jobs leads, so don&rsquo;t build the message around them there.
      </div>
    </div>
    <div class="template-list">
      ${state.templates.length === 0 ? '<div class="empty">No templates yet.</div>' :
        state.templates.map(t => `
          <div class="template-card">
            <div class="name">${esc(t.name)}</div>
            <div class="subject"><strong>Subject:</strong> ${esc(t.subject)}</div>
            <div class="body-preview">${esc(t.body.length > 300 ? t.body.slice(0, 300) + '…' : t.body)}</div>
            <div class="actions">
              <button class="btn small" data-action="edit-template" data-id="${t.id}">Edit</button>
              <button class="btn small" data-action="duplicate-template" data-id="${t.id}">Duplicate</button>
              <button class="btn small danger" data-action="delete-template" data-id="${t.id}">Delete</button>
            </div>
          </div>
        `).join('')}
    </div>
  `;
}



async function sendFilteredViaBrevo() {
  const template = state.templates.find(t => t.id === state.composeTemplateId);
  if (!template) return toast('Select a template first');

  // Pull EVERY contact matching the current filters (not just one batch).
  const all = await buildAllComposeContactsFromDb();
  if (!all.length) {
    state.composeBrevoResult = { error: 'No contacts match your current filters' };
    state.composeBrevoSending = false;
    state.composeBrevoProgress = null;
    render();
    return;
  }

  const CHUNK_SIZE = 250;
  const ids = all.map(c => c.id);
  const totalToSend = ids.length;
  const numBatches = Math.ceil(totalToSend / CHUNK_SIZE);

  if (totalToSend > CHUNK_SIZE) {
    const estMins = (numBatches - 1) * 5;
    const ok = confirm('This will email ' + totalToSend + ' contacts in ' + numBatches +
      ' batches of up to ' + CHUNK_SIZE + ', with a 5-minute gap between each batch to protect deliverability.\n\nTotal time: about ' + estMins + ' minutes. Please keep this tab open until it finishes. Continue?');
    if (!ok) return;
  }

  state.composeBrevoSending = true;
  state.composeBrevoResult = null;
  state.composeBrevoProgress = { done: 0, total: totalToSend, batch: 0, batches: numBatches };
  render();

  let sent = 0, failed = 0, total = 0;
  try {
    const { data: { session } } = await sb.auth.getSession();
    const token = session?.access_token;
    if (!token) throw new Error('Not authenticated');

    const stamp = 'batch_' + Date.now();
    for (let i = 0; i < ids.length; i += CHUNK_SIZE) {
      const chunk = ids.slice(i, i + CHUNK_SIZE);
      const batchNo = Math.floor(i / CHUNK_SIZE) + 1;
      state.composeBrevoProgress.batch = batchNo;
      state.composeBrevoProgress.waitSeconds = 0;
      render();

      const sess = await sb.auth.getSession();
      const token = sess.data.session?.access_token;

      let d = {};
      try {
        const res = await fetch('https://udttpnaenmyxviuiwxqw.supabase.co/functions/v1/send-mailshot', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + token },
          body: JSON.stringify({ templateId: template.id, contactIds: chunk, batchId: stamp + '_' + batchNo }),
        });
        d = await res.json();
      } catch (err) {
        d = { error: err.message };
      }

      if (d && typeof d.sent === 'number') {
        sent += d.sent; failed += (d.failed || 0); total += (d.total || chunk.length);
      } else {
        failed += chunk.length; total += chunk.length;
      }

      state.composeBrevoProgress.done = Math.min(i + CHUNK_SIZE, totalToSend);
      render();

      if (i + CHUNK_SIZE < ids.length) {
        for (let secs = 300; secs > 0; secs--) {
          state.composeBrevoProgress.waitSeconds = secs;
          render();
          await new Promise(r => setTimeout(r, 1000));
        }
        state.composeBrevoProgress.waitSeconds = 0;
        render();
      }
    }

    state.composeBrevoResult = { sent, failed, total };
    await Promise.all([loadStatusCounts(), loadSourceCounts(), loadContactsPage()]);
    toast(sent + ' emails sent via Brevo \u2713');
  } catch (e) {
    state.composeBrevoResult = { error: e.message, sent, failed, total };
  }

  state.composeBrevoSending = false;
  state.composeBrevoProgress = null;
  render();
}

async function buildAllComposeContactsFromDb() {
  const PAGE = 1000;
  const out = [];
  for (let from = 0; ; from += PAGE) {
    let query = sb.from(state.composeUncontactedOnly ? 'contacts_with_last_email' : 'contacts').select('*').eq('status', state.composeListFilter);
    query = applyComposeSourceFilter(query, state.composeSourceFilter);
    if ((state.composeSourceFilter === 'ahp' || state.composeSourceFilter === 'nhs_scotland') && state.composeSpecialtyFilter && state.composeSpecialtyFilter !== 'all') query = query.eq('department', state.composeSpecialtyFilter);
    if (state.composeRegionFilter) query = query.eq('region', state.composeRegionFilter);
    if (state.composeCountryFilter) query = query.eq('country', state.composeCountryFilter);
    if (state.composeTownFilter) query = query.ilike('town', `%${state.composeTownFilter}%`);
    if (state.composeUncontactedOnly) query = query.is('last_emailed_at', null);
    query = query.order('updated_at', { ascending: true }).range(from, from + PAGE - 1);
    const { data, error } = await query;
    if (error) { toast('Failed to load contacts for compose: ' + error.message, 'error'); break; }
    if (!data || !data.length) break;
    out.push(...data);
    if (data.length < PAGE) break;
  }
  return out.filter(c => c.email && c.email.includes('@'));
}

async function sendSelectedViaBrevo() {
  const ids = state.composeSelectedIds;
  if (!ids?.length) return;
  const template = state.templates.find(t => t.id === state.composeTemplateId);
  if (!template) return toast('Select a template first');

  state.composeBrevoSending = true;
  state.composeBrevoResult = null;
  render();

  try {
    const { data: { session } } = await sb.auth.getSession();
    const token = session?.access_token;
    if (!token) throw new Error('Not authenticated — please sign in again');

    const batchId = 'batch_' + Date.now();
    const res = await fetch('https://udttpnaenmyxviuiwxqw.supabase.co/functions/v1/send-mailshot', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ' + token,
      },
      body: JSON.stringify({
        templateId: template.id,
        contactIds:  ids,
        batchId,
        senderEmail: 'scott.lane@daywebster.com',
        senderName:  'Day Webster Group',
      }),
    });

    state.composeBrevoResult = await res.json();
    if (state.composeBrevoResult.sent > 0) {
      await Promise.all([loadStatusCounts(), loadSourceCounts(), loadContactsPage()]);
      toast(state.composeBrevoResult.sent + ' emails sent via Brevo ✓');
    }
  } catch(e) {
    state.composeBrevoResult = { error: e.message };
  }

  state.composeBrevoSending = false;
  render();
}

function renderCompose() {
  if (state.composeMode === 'one-by-one' && state.composeQueue) return renderOneByOne();
  if (state.composeMode === 'csv' && state.composeQueue) return renderCsvExport();
  if (state.composeSelectedIds) return renderBrevoSend();

  const template = state.templates.find(t => t.id === state.composeTemplateId);
  const sourceCount = state.counts[state.composeListFilter] || 0;
  const previewMatch = state.composePreviewCounts ? state.composePreviewCounts.matching : null;

  return `
    <h2 class="section-title">Compose Mailshot</h2>

    <div class="compose-step">
      <h3>1. Pick a template</h3>
      <select class="select" id="compose-template" style="width:100%;">
        <option value="">— Select a template —</option>
        ${state.templates.map(t => `<option value="${t.id}" ${state.composeTemplateId === t.id ? 'selected' : ''}>${esc(t.name)}</option>`).join('')}
      </select>
      ${template ? `
        <div style="margin-top:12px;background:var(--grey-50);padding:12px;border-radius:6px;font-size:12px;">
          <div><strong>Subject:</strong> ${esc(template.subject)}</div>
        </div>
      ` : ''}
    </div>

    <div class="compose-step">
      <h3>2. Pick your audience</h3>
      <div class="field-row">
        <div class="field">
          <label>Source</label>
          <select class="select" id="compose-source">
            ${[
              {k:'all',            l:'All Sources'},
              {k:'gp_surgery',     l:'GP Surgeries'},
              {k:'children_homes', l:"Children's Homes"},
              {k:'agency',         l:'Agency Outreach'},
              {k:'private_theatre',l:'Theatres'},
              {k:'ahp',            l:'AHP (NHS Jobs)'},
              {k:'nhs_scotland',   l:'NHS Scotland (AHP)'},
              {k:'care_home',     l:'Care Homes'},
              {k:'bms',            l:'BMS'},
              {k:'sterile',        l:'Sterile Services'},
              {k:'nhs_staffbank',  l:'NHS Staff Banks'},
              {k:'camhs',          l:'CAMHS'},
              {k:'anp',            l:'ANP'},
              {k:'enp',            l:'ENP'},
            ].map(s => `<option value="${s.k}" ${state.composeSourceFilter===s.k?'selected':''}>${s.l}</option>`).join('')}
          </select>
        </div>
        ${(state.composeSourceFilter === 'ahp' || state.composeSourceFilter === 'nhs_scotland') ? `
        <div class="field">
          <label>Specialty</label>
          <select class="select" id="compose-specialty">
            <option value="all" ${(!state.composeSpecialtyFilter||state.composeSpecialtyFilter==='all')?'selected':''}>All AHP specialties</option>
            ${[['physiotherapy','Physiotherapy'],['occupational_therapy','Occupational Therapy'],['radiography','Radiography'],['speech_language','Speech &amp; Language'],['dietetics','Dietetics'],['podiatry','Podiatry'],['orthoptics','Orthoptics'],['art_therapy','Art Therapy'],['paramedic','Paramedic'],['prosthetics','Prosthetics'],['pharmacy','Pharmacy'],['audiology','Audiology'],['biomedical_science','Biomedical Science (BMS)'],['sterile_services','Sterile Services'],['mental_health','Mental Health'],['operating_theatres','Operating Theatres']].map(o => `<option value="${o[0]}" ${state.composeSpecialtyFilter===o[0]?'selected':''}>${o[1]}</option>`).join('')}
          </select>
        </div>
        ` : ''}
        <div class="field">
          <label>Status</label>
          <select class="select" id="compose-list">
            <option value="lead" ${state.composeListFilter==='lead'?'selected':''}>Leads (${state.counts.lead})</option>
            <option value="live" ${state.composeListFilter==='live'?'selected':''}>Live (${state.counts.live})</option>
          </select>
        </div>
        <div class="field">
          <label>Not contacted</label>
          <label style="display:flex;align-items:center;gap:6px;font-weight:400;font-size:13px;cursor:pointer;white-space:nowrap;height:38px;">
            <input type="checkbox" id="compose-uncontacted" ${state.composeUncontactedOnly ? 'checked' : ''} />
            Only not emailed before
          </label>
        </div>
        <div class="field">
          <label>Region (optional)</label>
          <select class="select" id="compose-region">
            <option value="">All regions</option>
            ${state.regions.map(r => `<option value="${esc(r)}" ${state.composeRegionFilter===r?'selected':''}>${esc(r)}</option>`).join('')}
          </select>
        </div>
      </div>
      <div class="field-row">
        <div class="field">
          <label>Country (optional)</label>
          <select class="select" id="compose-country">
            <option value="">All countries</option>
            ${state.countries.map(c => `<option value="${esc(c)}" ${state.composeCountryFilter===c?'selected':''}>${esc(c)}</option>`).join('')}
          </select>
        </div>
        <div class="field">
          <label>Town contains (optional)</label>
          <input class="select" id="compose-town" value="${esc(state.composeTownFilter)}" placeholder="e.g. London, Birmingham" />
        </div>
      </div>
      <div class="field">
        <label>Batch size (recommended max 250)</label>
        <input class="select" type="number" id="compose-batch" value="${state.composeBatchSize}" min="1" max="2000" />
      </div>
    </div>

    <div class="compose-step">
      <h3>3. Preview audience</h3>
      <div class="stat-row">
        <div class="stat"><div class="label">Total in list</div><div class="value">${sourceCount}</div></div>
        <div class="stat"><div class="label">Match filter</div><div class="value" style="color:var(--orange-dark);">${previewMatch === null ? '?' : previewMatch}</div></div>
        <div class="stat"><div class="label">This batch</div><div class="value" style="color:var(--green);">${previewMatch === null ? '?' : Math.min(state.composeBatchSize, previewMatch)}</div></div>
      </div>
      <button class="btn" id="refresh-preview">Refresh preview</button>
      <div class="muted" style="margin-top:8px;">Unsubscribed contacts are automatically excluded — their status puts them in a separate bucket from Leads/Live.</div>
    </div>

    <div class="compose-step brevo-panel">
      <h3 style="margin:0 0 8px;">4. Send via Brevo</h3>
      <p class="muted" style="margin:0 0 14px;font-size:12px;">Sends personalised emails to each contact using your template. Each contact auto-advances to <strong>Contacted</strong> stage with a 14-day follow-up date.</p>

      <div style="display:flex;align-items:center;gap:12px;flex-wrap:wrap;">
        <button class="btn primary" id="brevo-filter-send-btn" ${!template || !previewMatch ? 'disabled' : ''}>
          ${state.composeBrevoSending ? '<span class="spinner-inline"></span> Sending&hellip;' : icon('mail') + '&nbsp;Send all ' + previewMatch + ' Emails via Brevo' + (previewMatch > 250 ? ' (' + Math.ceil(previewMatch/250) + ' batches)' : '')}
        </button>
        ${!template ? '<span class="muted" style="font-size:12px;">Select a template first</span>' : ''}
        ${!previewMatch ? '<span class="muted" style="font-size:12px;">No contacts match — adjust filters</span>' : ''}
      </div>

      ${state.composeBrevoSending ? `
        <div class="import-progress" style="margin-top:12px;">
          <div class="progress-bar"><div class="fill import-pulse"></div></div>
          <p class="muted" style="margin-top:6px;font-size:12px;">${state.composeBrevoProgress ? ((state.composeBrevoProgress.waitSeconds ? 'Batch ' + state.composeBrevoProgress.batch + ' of ' + state.composeBrevoProgress.batches + ' sent &mdash; next batch in ' + Math.floor(state.composeBrevoProgress.waitSeconds/60) + ':' + String(state.composeBrevoProgress.waitSeconds%60).padStart(2,'0') + ' (spacing sends to protect deliverability)' : 'Batch ' + state.composeBrevoProgress.batch + ' of ' + state.composeBrevoProgress.batches + ' &mdash; ' + state.composeBrevoProgress.done + ' of ' + state.composeBrevoProgress.total + ' processed')) : 'Sending personalised emails via Brevo&hellip;'}</p>
        </div>` : ''}

      ${state.composeBrevoResult && !state.composeBrevoSending && !state.composeSelectedIds ? `
      <div class="import-result ${state.composeBrevoResult.error ? 'err' : 'ok'}" style="margin-top:12px;">
        ${state.composeBrevoResult.error
          ? `<p style="color:#DC2626;font-size:13px;">&#10005; ${esc(state.composeBrevoResult.error)}</p>`
          : `<div class="import-result-stats">
              <div class="import-stat"><div class="import-stat-val">${state.composeBrevoResult.sent || 0}</div><div class="import-stat-lbl">Sent</div></div>
              <div class="import-stat"><div class="import-stat-val">${state.composeBrevoResult.failed || 0}</div><div class="import-stat-lbl">Failed</div></div>
              <div class="import-stat"><div class="import-stat-val">${state.composeBrevoResult.total || 0}</div><div class="import-stat-lbl">Total</div></div>
            </div>
            <p class="muted" style="margin-top:8px;font-size:12px;">&#10003; Done — contacts advanced to <strong>Contacted</strong> with 14-day follow-up set.</p>`}
      </div>` : ''}

      <details style="margin-top:14px;">
        <summary style="font-size:11px;color:var(--grey-500);cursor:pointer;">Advanced: one-by-one copy mode or CSV export</summary>
        <div class="stat-row" style="margin-top:10px;gap:8px;">
          <button class="btn small" id="start-one-by-one" ${!template || !previewMatch ? 'disabled' : ''}>📧 One-by-one Copy</button>
          <button class="btn small" id="start-csv" ${!template || !previewMatch ? 'disabled' : ''}>📊 CSV Export</button>
        </div>
      </details>
    </div>
  `;
}

function renderBrevoSend() {
  const template = state.templates.find(t => t.id === state.composeTemplateId);
  const ids = state.composeSelectedIds || [];

  return `
    <div class="compose-step brevo-panel">
      <div class="brevo-panel-header">
        <div>
          <h3 style="margin:0 0 4px;">✉ Direct Send — ${ids.length} contacts selected</h3>
          <p class="muted" style="margin:0;font-size:12px;">Contacts pre-selected from Database. Pick a template and send personalised emails via Brevo.</p>
        </div>
        <button class="btn small" id="clear-selected-send">✕ Clear selection</button>
      </div>

      <div style="margin-top:14px;">
        <label style="font-size:12px;font-weight:600;color:var(--grey-600);display:block;margin-bottom:6px;">Template</label>
        <select class="select" id="brevo-template-picker" style="max-width:380px;">
          <option value="">— Select a template —</option>
          ${state.templates.map(t => `<option value="${esc(t.id)}" ${state.composeTemplateId === t.id ? 'selected' : ''}>${esc(t.name)}</option>`).join('')}
        </select>
      </div>

      <div style="margin-top:14px;display:flex;align-items:center;gap:12px;flex-wrap:wrap;">
        <button class="btn primary" id="brevo-send-btn" ${!template || state.composeBrevoSending ? 'disabled' : ''}>
          ${state.composeBrevoSending
            ? '<span class="spinner-inline"></span> Sending via Brevo&hellip;'
            : icon('mail') + '&nbsp;Send ' + ids.length + ' Emails via Brevo'}
        </button>
        ${!template ? '<span class="muted" style="font-size:12px;">Select a template above first</span>' : ''}
      </div>

      ${state.composeBrevoSending ? `
        <div class="import-progress" style="margin-top:12px;">
          <div class="progress-bar"><div class="fill import-pulse"></div></div>
          <p class="muted" style="margin-top:6px;font-size:12px;">Sending personalised emails via Brevo&hellip; each contact gets a personalised message.</p>
        </div>` : ''}

      ${state.composeBrevoResult && !state.composeBrevoSending ? `
      <div class="import-result ${state.composeBrevoResult.error ? 'err' : 'ok'}" style="margin-top:12px;">
        ${state.composeBrevoResult.error
          ? `<p style="color:#DC2626;font-size:13px;">&#10005; ${esc(state.composeBrevoResult.error)}</p>`
          : `<div class="import-result-stats">
              <div class="import-stat"><div class="import-stat-val">${state.composeBrevoResult.sent || 0}</div><div class="import-stat-lbl">Sent</div></div>
              <div class="import-stat"><div class="import-stat-val">${state.composeBrevoResult.failed || 0}</div><div class="import-stat-lbl">Failed</div></div>
              <div class="import-stat"><div class="import-stat-val">${state.composeBrevoResult.total || 0}</div><div class="import-stat-lbl">Total</div></div>
            </div>
            <p class="muted" style="margin-top:8px;font-size:12px;">&#10003; Done — each contact auto-advanced to <strong>Contacted</strong> stage with a 14-day follow-up set.</p>`}
      </div>` : ''}
    </div>

    <div class="compose-step" style="opacity:.45;pointer-events:none;margin-top:12px;">
      <p class="muted" style="font-size:12px;"><em>Normal filter-based compose is hidden. Clear the selection above to use it.</em></p>
    </div>
  `;
}

function renderOneByOne() {
  const template = state.templates.find(t => t.id === state.composeTemplateId);
  const queue = state.composeQueue;
  const idx = state.composeIndex;

  if (idx >= queue.length) {
    return `
      <h2 class="section-title">✅ Mailshot Complete</h2>
      <div class="compose-step">
        <p style="font-size:14px;margin-bottom:16px;">You've worked through all ${queue.length} contacts in this batch.</p>
        <div class="stat-row">
          <button class="btn primary" id="compose-finish">Back to Compose</button>
        </div>
      </div>
    `;
  }

  const contact = queue[idx];
  const subject = personalize(template.subject, contact);
  const body = personalize(template.body, contact);
  const progress = ((idx) / queue.length * 100).toFixed(1);

  return `
    <div class="toolbar">
      <h2 class="section-title" style="margin:0;flex:1;">Sending: ${idx + 1} of ${queue.length}</h2>
      <button class="btn" id="exit-one-by-one">← Back to Compose</button>
    </div>
    <div class="progress-bar"><div class="fill" style="width:${progress}%;"></div></div>
    <div class="send-card">
      <div class="contact-info">
        <strong>To:</strong> ${esc([contact.title, contact.first_name, contact.last_name].filter(Boolean).join(' '))}
        &lt;${esc(contact.email)}&gt;<br>
        <strong>Surgery:</strong> ${esc(contact.org)} · ${esc(contact.town)} ${contact.region ? '(' + esc(contact.region) + ')' : ''}
        ${contact.notes ? '<br><strong>Notes:</strong> ' + esc(contact.notes) : ''}
      </div>
      <div class="subject-line">
        <span class="lbl">SUBJECT</span>
        <span style="flex:1;">${esc(subject)}</span>
        <button class="btn small" data-action="copy-subject">Copy</button>
      </div>
      <div class="subject-line">
        <span class="lbl">TO (BCC)</span>
        <span style="flex:1;">${esc(contact.email)}</span>
        <button class="btn small" data-action="copy-email">Copy</button>
      </div>
      <div class="email-preview">${esc(body)}</div>
      <div class="actions-row">
        <button class="btn primary" data-action="copy-body">📋 Copy Email Body</button>
        <button class="btn accent" data-action="mark-sent-next">✓ Sent & Next →</button>
        <button class="btn" data-action="skip-next">Skip →</button>
        <button class="btn danger" data-action="mark-bounced">Mark Bounced</button>
        <button class="btn danger" data-action="mark-unsub">Unsubscribe</button>
      </div>
    </div>
  `;
}

function renderCsvExport() {
  const template = state.templates.find(t => t.id === state.composeTemplateId);
  const queue = state.composeQueue;
  return `
    <div class="toolbar">
      <h2 class="section-title" style="margin:0;flex:1;">CSV Export Ready</h2>
      <button class="btn" id="exit-csv">← Back to Compose</button>
    </div>
    <div class="compose-step">
      <h3>Step 1: Download the CSV</h3>
      <p class="muted" style="margin-bottom:12px;">${queue.length} contacts in this batch.</p>
      <button class="btn primary" id="download-csv">⬇ Download CSV (${queue.length} contacts)</button>
    </div>
    <div class="compose-step">
      <h3>Step 2: Copy email body for Word</h3>
      <p class="muted" style="margin-bottom:12px;">Paste into a new Word document, then use <strong>Mailings → Start Mail Merge → Emails</strong> with this CSV as the data source.</p>
      <div class="subject-line">
        <span class="lbl">SUBJECT</span>
        <span style="flex:1;">${esc(convertTokensToMergeFields(template.subject))}</span>
        <button class="btn small" data-action="copy-merge-subject">Copy</button>
      </div>
      <div class="email-preview">${esc(convertTokensToMergeFields(template.body))}</div>
      <button class="btn primary" id="copy-merge-body" style="margin-top:12px;">📋 Copy Email Body (with «merge fields»)</button>
    </div>
    <div class="compose-step">
      <h3>Step 3: Mark batch as sent</h3>
      <p class="muted" style="margin-bottom:12px;">Once you've run the mail merge from Word, click below to log all ${queue.length} sends in the database. This updates "Last Emailed" dates and gives you proper audit history.</p>
      <button class="btn accent" id="mark-batch-sent">✓ Mark all ${queue.length} as sent today</button>
    </div>
  `;
}





async function runEnrichment() {
  const limit = parseInt(document.getElementById('enrich-limit')?.value || '50');
  state.enrichRunning = true; state.enrichResult = null; render();
  try {
    const res = await fetch('https://udttpnaenmyxviuiwxqw.supabase.co/functions/v1/ofsted-scraper', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVkdHRwbmFlbm15eHZpdWl3eHF3Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzkxNzAwODIsImV4cCI6MjA5NDc0NjA4Mn0.b7zeFYbNPSo7WjFu6-VFhMVelD2g1ja9m3af0Jb5geU' },
      body: JSON.stringify({ mode: 'enrich', limit }),
    });
    state.enrichResult = await res.json();
    if (state.enrichResult.emails_found > 0) {
      await loadSourceCounts();
    }
  } catch(e) { state.enrichResult = { success: false, error: e.message }; }
  state.enrichRunning = false; render();
}

// Split a CSV into header + data rows, respecting quoted fields that may
// themselves contain commas or newlines.
function splitCsvIntoRows(csvText) {
  const rows = [];
  let current = '';
  let inQuote = false;
  for (let i = 0; i < csvText.length; i++) {
    const ch = csvText[i];
    if (ch === '"') {
      inQuote = !inQuote;
      current += ch;
    } else if ((ch === '\n' || ch === '\r') && !inQuote) {
      if (ch === '\r' && csvText[i + 1] === '\n') i++;
      if (current.length > 0) rows.push(current);
      current = '';
    } else {
      current += ch;
    }
  }
  if (current.length > 0) rows.push(current);
  return rows;
}

// Upload a CSV in chunks to stay under Edge Function CPU/timeout limits.
// Returns the same shape the existing csv-upload Edge Function returns,
// with the per-chunk results aggregated.
async function runAgencyCSVUpload() {
  if (!state.agencyCsvText) return;
  state.agencyUploading = true;
  state.agencyResult = null;
  state.agencyProgress = null;
  render();

  const CHUNK_SIZE = 500;
  const AUTH = 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVkdHRwbmFlbm15eHZpdWl3eHF3Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzkxNzAwODIsImV4cCI6MjA5NDc0NjA4Mn0.b7zeFYbNPSo7WjFu6-VFhMVelD2g1ja9m3af0Jb5geU';

  try {
    const allRows = splitCsvIntoRows(state.agencyCsvText);
    if (allRows.length < 2) {
      state.agencyResult = { success: false, error: 'CSV has no data rows' };
      state.agencyUploading = false; render(); return;
    }
    const header = allRows[0];
    const dataRows = allRows.slice(1);
    const totalChunks = Math.ceil(dataRows.length / CHUNK_SIZE);

    let inserted = 0, totalRows = 0, skippedNoEmail = 0, skippedDup = 0;

    for (let i = 0; i < totalChunks; i++) {
      state.agencyProgress = {
        currentChunk: i + 1,
        totalChunks: totalChunks,
        rowsDone: Math.min((i + 1) * CHUNK_SIZE, dataRows.length),
        totalRowsInFile: dataRows.length,
      };
      render();

      const chunkRows = dataRows.slice(i * CHUNK_SIZE, (i + 1) * CHUNK_SIZE);
      const chunkCsv = [header, ...chunkRows].join('\n');

      let res, result;
      try {
        res = await fetch('https://udttpnaenmyxviuiwxqw.supabase.co/functions/v1/csv-upload', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', 'Authorization': AUTH },
          body: JSON.stringify({ csv: chunkCsv, source: state.agencyCsvSource }),
        });
        result = await res.json();
      } catch(netErr) {
        state.agencyResult = {
          success: false,
          error: `Network error on chunk ${i + 1} of ${totalChunks}: ${netErr.message}. ${inserted} contacts uploaded so far.`,
          inserted, total_rows: totalRows, skipped_no_email: skippedNoEmail, skipped_dup: skippedDup,
        };
        state.agencyUploading = false; state.agencyProgress = null;
        if (inserted > 0) await Promise.all([loadStatusCounts(), loadSourceCounts()]);
        render(); return;
      }

      if (!result || !result.success) {
        state.agencyResult = {
          success: false,
          error: `Chunk ${i + 1} of ${totalChunks} failed: ${(result && result.error) || ('HTTP ' + (res && res.status))}. ${inserted} contacts uploaded so far.`,
          inserted, total_rows: totalRows, skipped_no_email: skippedNoEmail, skipped_dup: skippedDup,
        };
        state.agencyUploading = false; state.agencyProgress = null;
        if (inserted > 0) await Promise.all([loadStatusCounts(), loadSourceCounts()]);
        render(); return;
      }

      inserted += result.inserted || 0;
      totalRows += result.total_rows || 0;
      skippedNoEmail += result.skipped_no_email || 0;
      skippedDup += result.skipped_dup || 0;
    }

    state.agencyResult = {
      success: true,
      inserted, total_rows: totalRows,
      skipped_no_email: skippedNoEmail, skipped_dup: skippedDup,
    };
    await Promise.all([loadStatusCounts(), loadSourceCounts()]);
  } catch(e) {
    state.agencyResult = { success: false, error: e.message };
  }
  state.agencyUploading = false;
  state.agencyProgress = null;
  render();
}

async function previewAgencyCSV(csvText) {
  state.agencyCsvText = csvText;
  try {
    const res = await fetch('https://udttpnaenmyxviuiwxqw.supabase.co/functions/v1/csv-upload', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVkdHRwbmFlbm15eHZpdWl3eHF3Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzkxNzAwODIsImV4cCI6MjA5NDc0NjA4Mn0.b7zeFYbNPSo7WjFu6-VFhMVelD2g1ja9m3af0Jb5geU' },
      body: JSON.stringify({ csv: csvText, source: state.agencyCsvSource, preview: true }),
    });
    state.agencyCsvPreview = await res.json();
  } catch(e) { state.agencyCsvPreview = { error: e.message }; }
  render();
}

async function runCareHomeScrape() {
  const region = document.getElementById('ch-region') ? document.getElementById('ch-region').value : '';
  const care_type = document.getElementById('ch-type') ? document.getElementById('ch-type').value : 'all';
  const limit = parseInt((document.getElementById('ch-limit') || {value:'20'}).value);
  state.careHomeRunning = true; state.careHomeResult = null; render();
  try {
    const res = await fetch('https://udttpnaenmyxviuiwxqw.supabase.co/functions/v1/care-home-scraper', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVkdHRwbmFlbm15eHZpdWl3eHF3Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzkxNzAwODIsImV4cCI6MjA5NDc0NjA4Mn0.b7zeFYbNPSo7WjFu6-VFhMVelD2g1ja9m3af0Jb5geU' },
      body: JSON.stringify({ region: region, care_type: care_type, limit: limit }),
    });
    state.careHomeResult = await res.json();
    if (state.careHomeResult && state.careHomeResult.success && state.careHomeResult.inserted > 0) {
      await Promise.all([loadStatusCounts(), loadSourceCounts()]);
    }
  } catch(e) { state.careHomeResult = { success: false, error: e.message }; }
  state.careHomeRunning = false; render();
}

async function runTheatreScrape() {
  const region = document.getElementById('pt-region')?.value || '';
  const limit = parseInt(document.getElementById('pt-limit')?.value || '20');
  state.theatreRunning = true; state.theatreResult = null; render();
  try {
    const res = await fetch('https://udttpnaenmyxviuiwxqw.supabase.co/functions/v1/private-theatre-scraper', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVkdHRwbmFlbm15eHZpdWl3eHF3Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzkxNzAwODIsImV4cCI6MjA5NDc0NjA4Mn0.b7zeFYbNPSo7WjFu6-VFhMVelD2g1ja9m3af0Jb5geU' },
      body: JSON.stringify({ region, limit }),
    });
    state.theatreResult = await res.json();
    if (state.theatreResult.success) {
      await Promise.all([loadStatusCounts(), loadSourceCounts()]);
    }
  } catch(e) { state.theatreResult = { success: false, error: e.message }; }
  state.theatreRunning = false; render();
}

function icon(name, size) {
  var s = size || 18;
  var P = {
    activity: '<path d="M22 12h-4l-3 8L9 4l-3 8H2"/>',
    flag: '<path d="M4 22V4"/><path d="M4 4c4-2 8 2 12 0v9c-4 2-8-2-12 0"/>',
    folder: '<path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>',
    home: '<path d="M3 11l9-7 9 7"/><path d="M5 10v10h14V10"/>',
    building: '<rect x="5" y="3" width="14" height="18" rx="1.5"/><path d="M9 7h2M13 7h2M9 11h2M13 11h2M9 15h2M13 15h2"/>',
    mail: '<rect x="3" y="5" width="18" height="14" rx="2"/><path d="m3 7 9 6 9-6"/>',
    download: '<path d="M12 3v12"/><path d="m7 10 5 5 5-5"/><path d="M5 21h14"/>',
    list: '<path d="M8 6h13M8 12h13M8 18h13"/><path d="M3.5 6h.01M3.5 12h.01M3.5 18h.01"/>',
    bell: '<path d="M18 8a6 6 0 0 0-12 0c0 7-3 9-3 9h18s-3-2-3-9"/><path d="M13.7 21a2 2 0 0 1-3.4 0"/>',
    search: '<circle cx="11" cy="11" r="7"/><path d="m21 21-4.3-4.3"/>',
    users: '<path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M22 21v-2a4 4 0 0 0-3-3.9"/><path d="M16 3.1a4 4 0 0 1 0 7.8"/>',
    user: '<path d="M19 21v-2a4 4 0 0 0-4-4H9a4 4 0 0 0-4 4v2"/><circle cx="12" cy="7" r="4"/>',
    ban: '<circle cx="12" cy="12" r="9"/><path d="m5.6 5.6 12.8 12.8"/>',
    upload: '<path d="M12 17V5"/><path d="m7 10 5-5 5 5"/><path d="M5 21h14"/>',
    play: '<path d="M7 4.5v15l12-7.5z"/>',
    refresh: '<path d="M21 12a9 9 0 1 1-2.6-6.3"/><path d="M21 3v6h-6"/>',
  };
  return '<svg class="ico" width="' + s + '" height="' + s + '" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' + (P[name] || '') + '</svg>';
}

async function runScotlandScrape() {
  state.scotRunning = true; state.scotResult = null; render();
  try {
    const spec = (document.getElementById('scot-specialty') || {}).value || state.scotSpecialty || 'physiotherapy';
    const res = await fetch('https://udttpnaenmyxviuiwxqw.supabase.co/functions/v1/nhs-scotland-scraper', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVkdHRwbmFlbm15eHZpdWl3eHF3Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzkxNzAwODIsImV4cCI6MjA5NDc0NjA4Mn0.b7zeFYbNPSo7WjFu6-VFhMVelD2g1ja9m3af0Jb5geU' },
      body: JSON.stringify({ specialty: spec, offset: 0, limit: 50 }),
    });
    const data = await res.json();
    state.scotResult = { inserted: data.inserted || 0, specialty: data.specialty || spec, error: data.error };
    if (data && data.inserted > 0) { await Promise.all([loadStatusCounts(), loadSourceCounts()]); }
  } catch (err) { state.scotResult = { error: err.message }; }
  state.scotRunning = false; render();
}

async function runScotlandScrapeAll() {
  if (state.scotSweepRunning || state.scotRunning) return;
  state.scotSweepRunning = true; state.scotResult = null;
  const specs = ['all'];
  let totalInserted = 0, i = 0;
  for (const spec of specs) {
    i++;
    state.scotSweepMsg = 'Scanning ' + spec.replace(/_/g, ' ') + ' (' + i + '/' + specs.length + ')\u2026';
    render();
    try {
      const res = await fetch('https://udttpnaenmyxviuiwxqw.supabase.co/functions/v1/nhs-scotland-scraper', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVkdHRwbmFlbm15eHZpdWl3eHF3Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzkxNzAwODIsImV4cCI6MjA5NDc0NjA4Mn0.b7zeFYbNPSo7WjFu6-VFhMVelD2g1ja9m3af0Jb5geU' },
        body: JSON.stringify({ specialty: spec, offset: 0, limit: 150 }),
      });
      const data = await res.json();
      if (data && data.inserted) totalInserted += data.inserted;
    } catch (e) { }
  }
  state.scotResult = { swept: true, inserted: totalInserted };
  state.scotSweepMsg = '';
  state.scotSweepRunning = false;
  await Promise.all([loadStatusCounts(), loadSourceCounts()]);
  render();
}

async function runNHSScrape() {
  state.importRunning = true;
  state.importResult = null;
  render();
  try {
    const res = await fetch('https://udttpnaenmyxviuiwxqw.supabase.co/functions/v1/nhs-jobs-scraper', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVkdHRwbmFlbm15eHZpdWl3eHF3Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzkxNzAwODIsImV4cCI6MjA5NDc0NjA4Mn0.b7zeFYbNPSo7WjFu6-VFhMVelD2g1ja9m3af0Jb5geU',
      },
      body: JSON.stringify({
        specialty: state.importSpecialty,
        region:    state.importRegion,
        band:      state.importBand,
        limit:     state.importLimit,
        mode:      'scrape',
      }),
    });
    const data = await res.json();
    state.importResult = data;
    if (data.success && data.inserted > 0) {
      await Promise.all([loadStatusCounts(), loadSourceCounts()]);
    }
  } catch (err) {
    state.importResult = { success: false, error: err.message };
  }
  state.importRunning = false;
  render();
}

// Sweep an entire specialty by calling the scraper repeatedly, advancing the
// page offset each pass until the backend reports done. DB ignores duplicates,
// so overlapping passes are harmless.
async function runNHSScrapeAll() {
  if (state.importSweepRunning || state.importRunning) return;
  state.importSweepRunning = true;
  state.importResult = null;
  let offset = 0, totalInserted = 0, totalFound = 0, runs = 0;
  const MAX_RUNS = 40; // safety ceiling
  state.importSweepMsg = 'Starting full sweep\u2026';
  render();
  try {
    while (runs < MAX_RUNS) {
      const res = await fetch('https://udttpnaenmyxviuiwxqw.supabase.co/functions/v1/nhs-jobs-scraper', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVkdHRwbmFlbm15eHZpdWl3eHF3Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzkxNzAwODIsImV4cCI6MjA5NDc0NjA4Mn0.b7zeFYbNPSo7WjFu6-VFhMVelD2g1ja9m3af0Jb5geU',
        },
        body: JSON.stringify({
          specialty: state.importSpecialty,
          region:    state.importRegion,
          band:      state.importBand,
          limit:     50,
          offset:    offset,
          mode:      'scrape',
        }),
      });
      const data = await res.json();
      runs++;
      if (data && typeof data.inserted === 'number') { totalInserted += data.inserted; totalFound += (data.found || 0); }
      state.importSweepMsg = `Sweeping NHS Jobs \u2014 ${totalInserted} new contacts added so far (pass ${runs})\u2026`;
      render();
      if (!data || data.done || typeof data.next_offset !== 'number') break;
      offset = data.next_offset;
    }
    state.importResult = { success: true, inserted: totalInserted, found: totalFound, jobs_checked: 0, skipped_dup: 0, specialty: state.importSpecialty, sweep: true, runs };
    await Promise.all([loadStatusCounts(), loadSourceCounts()]);
  } catch (err) {
    state.importResult = { success: false, error: err.message };
  }
  state.importSweepRunning = false;
  state.importSweepMsg = '';
  render();
}


async function runNHSScrapeEverything() {
  if (state.importSweepRunning || state.importRunning) return;
  const ALL_SPECS = ['physiotherapy','occupational_therapy','radiography','speech_language','dietetics','podiatry','orthoptics','art_therapy','paramedic','prosthetics','pharmacy','biomedical_science','sterile_services','mental_health','operating_theatres','audiology','advanced_nurse_practitioner','emergency_nurse_practitioner','gp_surgery'];
  state.importSweepRunning = true;
  state.importResult = null;
  let grandInserted = 0, grandFound = 0;
  const MAX_RUNS = 40;
  state.importSweepMsg = 'Starting full sweep of every specialty\u2026';
  render();
  try {
    for (let si = 0; si < ALL_SPECS.length; si++) {
      const spec = ALL_SPECS[si];
      let offset = 0, runs = 0, specInserted = 0;
      while (runs < MAX_RUNS) {
        state.importSweepMsg = `Sweeping ${spec.replace(/_/g,' ')} (${si + 1}/${ALL_SPECS.length}) \u2014 ${grandInserted + specInserted} new contacts so far\u2026`;
        render();
        const res = await fetch('https://udttpnaenmyxviuiwxqw.supabase.co/functions/v1/nhs-jobs-scraper', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVkdHRwbmFlbm15eHZpdWl3eHF3Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzkxNzAwODIsImV4cCI6MjA5NDc0NjA4Mn0.b7zeFYbNPSo7WjFu6-VFhMVelD2g1ja9m3af0Jb5geU' },
          body: JSON.stringify({ specialty: spec, region: state.importRegion, band: state.importBand, limit: 50, offset: offset, mode: 'scrape' }),
        });
        const data = await res.json();
        runs++;
        if (data && typeof data.inserted === 'number') { specInserted += data.inserted; grandFound += (data.found || 0); }
        if (!data || data.done || typeof data.next_offset !== 'number') break;
        offset = data.next_offset;
      }
      grandInserted += specInserted;
    }
    state.importResult = { success: true, inserted: grandInserted, found: grandFound, jobs_checked: 0, skipped_dup: 0, specialty: 'all specialties', sweep: true };
    await Promise.all([loadStatusCounts(), loadSourceCounts()]);
  } catch (err) {
    state.importResult = { success: false, error: err.message };
  }
  state.importSweepRunning = false;
  state.importSweepMsg = '';
  render();
}


// --- Smart CSV upload card renderer (reusable) ---
function renderCsvUploadCard(sourceKey, state) {
  const stateKey = 'csv_' + sourceKey;
  const csvText = state['csvText_' + sourceKey] || '';
  const preview = state['csvPreview_' + sourceKey] || null;
  const uploading = state['csvUploading_' + sourceKey] || false;
  const result = state['csvResult_' + sourceKey] || null;

  let previewHtml = '';
  if (preview && preview.success) {
    previewHtml = `<div class="csv-preview">
      <div class="csv-preview-header">
        <strong>${preview.totalRows} rows</strong> &nbsp;&middot;&nbsp;
        ${preview.hasEmail ? '<span style="color:var(--green-dark)">&#10003; Email column detected</span>' : '<span style="color:#DC2626">&#10005; No email column found &mdash; check column names</span>'}
        ${preview.hasName ? ' &nbsp;&middot;&nbsp; <span style="color:var(--green-dark)">&#10003; Name detected</span>' : ''}
      </div>
      <div class="csv-col-map">
        ${preview.headers.map((h, i) => `<span class="csv-col ${preview.mapped[i] ? 'mapped' : 'unmapped'}">${esc(h)} ${preview.mapped[i] ? '&rarr; ' + preview.mapped[i] : '(ignored)'}</span>`).join('')}
      </div>
    </div>`;
  }

  let resultHtml = '';
  if (result) {
    resultHtml = `<div class="import-result ${result.success ? 'ok' : 'err'}">
      ${result.success
        ? `<div class="import-result-stats">
            <div class="import-stat"><div class="import-stat-val">${result.inserted}</div><div class="import-stat-lbl">Added</div></div>
            <div class="import-stat"><div class="import-stat-val">${result.total_rows}</div><div class="import-stat-lbl">Total Rows</div></div>
            <div class="import-stat"><div class="import-stat-val">${result.skipped_no_email}</div><div class="import-stat-lbl">No Email</div></div>
            <div class="import-stat"><div class="import-stat-val">${result.skipped_dup}</div><div class="import-stat-lbl">Duplicate</div></div>
          </div>
          <p class="muted" style="margin-top:8px;font-size:12px;">&#10003; ${result.inserted} contacts added to ${sourceKey.replace(/_/g,' ')} database.</p>`
        : `<p style="color:#DC2626;font-size:13px;">&#10005; ${esc(result.error || 'Upload failed')}</p>`}
    </div>`;
  }

  return `<div class="import-form">
    <div class="import-form-row" style="grid-template-columns:1fr;">
      <div class="field">
        <label>Select CSV file</label>
        <input type="file" id="csv-input-${sourceKey}" accept=".csv,.txt" style="font-size:13px;padding:6px 0;" data-csv-source="${sourceKey}" />
      </div>
    </div>
    ${previewHtml}
    <div class="import-form-actions">
      <button class="btn primary" id="csv-upload-btn-${sourceKey}"
        ${!csvText || uploading ? 'disabled' : ''}>
        ${uploading ? '<span class="spinner-inline"></span> Uploading&hellip;' : '&#8593; Upload to Database'}
      </button>
      <span class="import-hint">Columns auto-detected. Duplicates (same email) skipped.</span>
    </div>
  </div>
  ${uploading ? '<div class="import-progress"><div class="progress-bar"><div class="fill import-pulse"></div></div><p class="muted" style="margin-top:8px;font-size:12px;">Uploading contacts&hellip;</p></div>' : ''}
  ${resultHtml}`;
}

function renderImport() {
  const SPECIALTIES = [
    { value: 'physiotherapy',        label: 'Physiotherapy' },
    { value: 'occupational_therapy', label: 'Occupational Therapy' },
    { value: 'radiography',          label: 'Radiography' },
    { value: 'speech_language',      label: 'Speech & Language Therapy' },
    { value: 'dietetics',            label: 'Dietetics' },
    { value: 'podiatry',             label: 'Podiatry' },
    { value: 'orthoptics',           label: 'Orthoptics' },
    { value: 'art_therapy',          label: 'Arts Therapies' },
    { value: 'paramedic',            label: 'Paramedic' },
    { value: 'prosthetics',          label: 'Prosthetics & Orthotics' },
    { value: 'pharmacy',             label: 'Pharmacy (NHS)' },
    { value: 'biomedical_science', label: 'Biomedical Science (BMS)' },
    { value: 'sterile_services', label: 'Sterile Services' },
    { value: 'mental_health', label: 'Mental Health' },
    { value: 'operating_theatres', label: 'Operating Theatres' },
    { value: 'audiology', label: 'Audiology' },
    { value: 'advanced_nurse_practitioner', label: 'Advanced Nurse Practitioner (ANP)' },
    { value: 'emergency_nurse_practitioner', label: 'Emergency Nurse Practitioner (ENP)' },
    { value: 'gp_surgery',           label: 'GP Surgeries (Practice Managers)' },
  ];
  const BANDS = [
    { value: '6', label: 'Band 6+' },
    { value: '7', label: 'Band 7+' },
    { value: '8', label: 'Band 8+' },
    { value: 'any', label: 'Any Band' },
  ];
  const REGIONS = [
    'North West','North East, Yorkshire and The Humber',
    'West Midlands','East Midlands','East of England',
    'South East','London','South West',
  ];
  const r = state.importResult;

  const placeholders = [
    { icon: '🔬', title: 'NHS Directory — BMS', sub: 'Biomedical Scientists via NHS pathology lab directories' },
    { icon: '📡', title: 'NHS Staff Banks', sub: 'Bank manager contacts from NHS trust staff bank portals' },
    { icon: '🧠', title: 'CAMHS', sub: 'Child and Adolescent Mental Health Service contacts' },
  ];

  return `
    <div class="import-wrap">
      <h2 class="section-title">Import Contacts</h2>

      <div class="import-card">
        <div class="import-card-header">
          <div class="import-card-icon">${icon('activity',22)}</div>
          <div class="import-card-meta">
            <div class="import-card-title">NHS Jobs — AHP Contacts</div>
            <div class="import-card-sub">Claude agent searches NHS Jobs and extracts hiring manager contacts from job postings</div>
          </div>
          <span class="import-badge live">Live</span>
        </div>

        <div class="import-form">
          <div class="import-form-row">
            <div class="field">
              <label>AHP Specialty</label>
              <select class="select" id="imp-specialty">
                ${SPECIALTIES.map(s => `<option value="${s.value}" ${state.importSpecialty === s.value ? 'selected' : ''}>${s.label}</option>`).join('')}
              </select>
            </div>
            <div class="field">
              <label>Region</label>
              <select class="select" id="imp-region">
                <option value="">All England</option>
                ${REGIONS.map(rg => `<option value="${rg}" ${state.importRegion === rg ? 'selected' : ''}>${rg}</option>`).join('')}
              </select>
            </div>
            <div class="field">
              <label>Minimum Band</label>
              <select class="select" id="imp-band">
                ${BANDS.map(b => `<option value="${b.value}" ${state.importBand === b.value ? 'selected' : ''}>${b.label}</option>`).join('')}
              </select>
            </div>
            <div class="field">
              <label>Max Contacts</label>
              <select class="select" id="imp-limit">
                ${[10,20,30,50].map(n => `<option value="${n}" ${state.importLimit === n ? 'selected' : ''}>${n}</option>`).join('')}
              </select>
            </div>
          </div>
          <div class="import-form-actions">
            <button class="btn primary" id="run-scrape-btn" ${state.importRunning || state.importSweepRunning ? 'disabled' : ''}>
              ${state.importRunning ? '<span class="spinner-inline"></span> Scraping NHS Jobs&hellip;' : icon('play') + ' Run Scraper'}
            </button>
            <button class="btn" id="run-scrape-all-btn" ${state.importRunning || state.importSweepRunning ? 'disabled' : ''}>
              ${state.importSweepRunning ? '<span class="spinner-inline"></span> Sweeping&hellip;' : icon('refresh') + ' Scrape ALL'}
            </button>
            <button class="btn" id="run-scrape-every-btn" ${state.importRunning || state.importSweepRunning ? 'disabled' : ''}>
              ${state.importSweepRunning ? '<span class="spinner-inline"></span> Sweeping&hellip;' : icon('refresh') + ' Scrape ALL Specialties'}
            </button>
            <span class="import-hint">Run Scraper grabs up to 50. Scrape ALL sweeps this specialty; Scrape ALL Specialties sweeps every specialty (can take several minutes).</span>
          </div>
        </div>

        ${state.importRunning ? `
          <div class="import-progress">
            <div class="progress-bar"><div class="fill import-pulse"></div></div>
            <p class="muted" style="margin-top:8px;font-size:12px;">Searching NHS Jobs and reading postings&hellip; please wait</p>
          </div>` : ''}

        ${state.importSweepRunning ? `
          <div class="import-progress">
            <div class="progress-bar"><div class="fill import-pulse"></div></div>
            <p class="muted" style="margin-top:8px;font-size:12px;">${esc(state.importSweepMsg || 'Sweeping all pages\u2026')}</p>
          </div>` : ''}

        ${r ? `<div class="import-result ${r.success ? 'ok' : 'err'}">
          ${r.success ? `
            <div class="import-result-stats">
              <div class="import-stat"><div class="import-stat-val">${r.inserted}</div><div class="import-stat-lbl">Added</div></div>
              <div class="import-stat"><div class="import-stat-val">${r.found}</div><div class="import-stat-lbl">Found</div></div>
              <div class="import-stat"><div class="import-stat-val">${r.jobs_checked||r.skipped_no_email||0}</div><div class="import-stat-lbl">${r.jobs_checked ? 'Checked' : 'No email'}</div></div>
              <div class="import-stat"><div class="import-stat-val">${r.skipped_dup}</div><div class="import-stat-lbl">Duplicate</div></div>
            </div>
            <p class="muted" style="margin-top:8px;font-size:12px;">${r.inserted > 0 ? '&#10003; ' + r.inserted + ' new ' + (r.specialty||'').replace('_',' ') + ' contacts added &mdash; switch to Database &rarr; All Sources to view them' : '&#10003; Already up to date &mdash; no new ' + (r.specialty||'').replace('_',' ') + ' contacts found. Anything matching is already in your database.'}</p>
          ` : `
            <p style="color:#DC2626;font-size:13px;">&#10005; ${esc(r.error || 'Unknown error')}</p>
            ${(r.error||'').includes('ANTHROPIC_API_KEY') ? '<p class="muted" style="margin-top:6px;font-size:12px;">Add key: Supabase Dashboard &rarr; Project Settings &rarr; Edge Functions &rarr; Secrets &rarr; ANTHROPIC_API_KEY</p>' : ''}
          `}
        </div>` : ''}
      </div>

      <!-- NHS Scotland scraper -->
      <div class="import-card">
        <div class="import-card-header">
          <div class="import-card-icon">${icon('flag',22)}</div>
          <div class="import-card-meta">
            <div class="import-card-title">NHS Scotland - AHP Contacts</div>
            <div class="import-card-sub">Scrapes apply.jobs.scot.nhs.uk (JobTrain) for AHP vacancies and pulls the named hiring contact, role, band and town across all Scottish health boards.</div>
          </div>
          <span class="import-badge live">Live</span>
        </div>
        <div class="import-form">
          <div class="import-form-row">
            <div class="field">
              <label>AHP Specialty</label>
              <select class="select" id="scot-specialty">
                ${SPECIALTIES.filter(sp => !['gp_surgery','advanced_nurse_practitioner','emergency_nurse_practitioner'].includes(sp.value)).map(sp => `<option value="${sp.value}" ${(state.scotSpecialty || 'physiotherapy') === sp.value ? 'selected' : ''}>${sp.label}</option>`).join('')}
              </select>
            </div>
          </div>
          <div class="import-form-actions">
            <button class="btn primary" id="run-scot-btn" ${state.scotRunning || state.scotSweepRunning ? 'disabled' : ''}>
              ${state.scotRunning ? '<span class="spinner-inline"></span> Scraping NHS Scotland&hellip;' : icon('play') + ' Run Scraper'}
            </button>
            <button class="btn" id="run-scot-all-btn" ${state.scotRunning || state.scotSweepRunning ? 'disabled' : ''}>
              ${state.scotSweepRunning ? '<span class="spinner-inline"></span> Sweeping&hellip;' : icon('refresh') + ' Scrape ALL Specialties'}
            </button>
            <span class="import-hint">Run Scraper grabs the selected specialty. Scrape ALL Specialties sweeps every AHP specialty across all Scottish health boards (can take a couple of minutes).</span>
          </div>
        </div>
        ${state.scotSweepRunning ? `
          <div class="import-progress">
            <div class="progress-bar"><div class="fill import-pulse"></div></div>
            <p class="muted" style="margin-top:8px;font-size:12px;">${esc(state.scotSweepMsg || 'Sweeping all specialties\u2026')}</p>
          </div>` : ''}
        ${state.scotResult ? `<div class="import-result ${state.scotResult.error ? 'err' : 'ok'}">
          ${state.scotResult.error ? `<p style="color:#DC2626;font-size:13px;">&#10005; ${esc(state.scotResult.error)}</p>` : `<p class="muted" style="font-size:12px;">&#10003; ${state.scotResult.inserted || 0} new contact(s) added${state.scotResult.swept ? ' across all specialties' : (state.scotResult.specialty ? ' for ' + String(state.scotResult.specialty).replace(/_/g,' ') : '')} &mdash; view under Database &rarr; NHS Scotland.</p>`}
        </div>` : ''}
      </div>

            <!-- Agency Outreach CSV Upload -->
      <div class="import-card">
        <div class="import-card-header">
          <div class="import-card-icon">${icon('folder',22)}</div>
          <div class="import-card-meta">
            <div class="import-card-title">Contact List — CSV Upload</div>
            <div class="import-card-sub">Upload any contact CSV. Supports GP Surgeries, Agency Outreach and all other sources. Auto-maps columns: name, email, org, job title, phone, region/geographic area, town etc.</div>
          </div>
          <span class="import-badge live">Live</span>
        </div>
        <div class="import-form">
          <div class="import-form-row">
            <div class="field">
              <label>Source / List Type</label>
              <select class="select" id="agency-csv-source">
                ${[
                  { v: 'gp_surgery',      l: 'GP Surgeries' },
                  { v: 'agency',          l: 'Agency Outreach' },
                  { v: 'private_theatre', l: 'Theatres' },
                  { v: 'children_homes',  l: "Children's Homes" },
                  { v: 'bms',             l: 'BMS' },
                  { v: 'sterile',         l: 'Sterile Services' },
                  { v: 'nhs_staffbank',   l: 'NHS Staff Banks' },
                  { v: 'camhs',           l: 'CAMHS' },
                ].map(s => `<option value="${s.v}" ${state.agencyCsvSource === s.v ? 'selected' : ''}>${s.l}</option>`).join('')}
              </select>
            </div>
            <div class="field">
              <label>Select CSV file</label>
              <input type="file" id="agency-csv-input" accept=".csv,.txt" style="font-size:13px;padding:6px 0;" />
            </div>
          </div>

          ${state.agencyCsvPreview && state.agencyCsvPreview.success ? `
          <div class="csv-preview">
            <div class="csv-preview-header">
              <strong>${state.agencyCsvPreview.totalRows} rows</strong> &nbsp;·&nbsp;
              ${state.agencyCsvPreview.hasEmail ? '<span style="color:var(--green-dark)">✓ Email column detected</span>' : '<span style="color:var(--red)">⚠ No email column found</span>'}
            </div>
            <div class="csv-col-map">
              ${state.agencyCsvPreview.headers.map((h, i) => `
                <span class="csv-col ${state.agencyCsvPreview.mapped[i] ? 'mapped' : 'unmapped'}">
                  ${esc(h)} ${state.agencyCsvPreview.mapped[i] ? '→ '+state.agencyCsvPreview.mapped[i] : '(ignored)'}
                </span>`).join('')}
            </div>
          </div>` : ''}

          <div class="import-form-actions">
            <button class="btn primary" id="agency-upload-btn"
              ${!state.agencyCsvText || state.agencyUploading ? 'disabled' : ''}>
              ${state.agencyUploading ? '<span class="spinner-inline"></span> Uploading&hellip;' : '&#8593; Upload to Database'}
            </button>
            <span class="import-hint">Contacts tagged <code>Source: Agency Outreach</code>. Duplicates (same email) skipped automatically.</span>
          </div>
        </div>
        ${state.agencyUploading ? `<div class="import-progress">
          <div class="progress-bar"><div class="fill" style="width:${state.agencyProgress ? Math.round((state.agencyProgress.currentChunk / state.agencyProgress.totalChunks) * 100) : 5}%;transition:width 0.3s;"></div></div>
          <p class="muted" style="margin-top:8px;font-size:12px;">${state.agencyProgress
            ? `Uploading chunk ${state.agencyProgress.currentChunk} of ${state.agencyProgress.totalChunks} &mdash; ${state.agencyProgress.rowsDone.toLocaleString()} of ${state.agencyProgress.totalRowsInFile.toLocaleString()} rows processed&hellip;`
            : 'Preparing upload&hellip;'}</p>
        </div>` : ''}
        ${state.agencyResult ? `<div class="import-result ${state.agencyResult.success ? 'ok' : 'err'}">
          ${state.agencyResult.success
            ? `<div class="import-result-stats">
                <div class="import-stat"><div class="import-stat-val">${state.agencyResult.inserted}</div><div class="import-stat-lbl">Added</div></div>
                <div class="import-stat"><div class="import-stat-val">${state.agencyResult.total_rows}</div><div class="import-stat-lbl">Total rows</div></div>
                <div class="import-stat"><div class="import-stat-val">${state.agencyResult.skipped_no_email}</div><div class="import-stat-lbl">No email</div></div>
                <div class="import-stat"><div class="import-stat-val">${state.agencyResult.skipped_dup}</div><div class="import-stat-lbl">Duplicate</div></div>
              </div>
              <p class="muted" style="margin-top:8px;font-size:12px;">&#10003; ${state.agencyResult.inserted} contacts added &mdash; view in Database under the appropriate source tab</p>`
            : `<p style="color:#DC2626;font-size:13px;">&#10005; ${esc(state.agencyResult.error || 'Upload failed')}</p>`}
        </div>` : ''}
      </div>


            <!-- Care Homes CSV Upload -->
      <div class="import-card">
        <div class="import-card-header">
          <div class="import-card-icon">${icon('home',22)}</div>
          <div class="import-card-meta">
            <div class="import-card-title">Care Homes — CSV Upload</div>
            <div class="import-card-sub">Upload a CSV of care home contacts. Auto-detects name, email, phone, home name, town and region. Tag your contacts as Care Home in the source dropdown.</div>
          </div>
          <span class="import-badge live">Live</span>
        </div>
        <div class="import-card-template-hint" style="font-size:12px;color:var(--grey-500);margin:0 0 12px 0;padding:0 4px;">
          Expected columns: <code>Home Name</code> <code>Manager Name</code> <code>Email</code> <code>Phone</code> <code>Town</code> <code>Region</code> &mdash;
          <a href="data:text/csv;charset=utf-8,Home%20Name%2CManager%20Name%2CEmail%2CPhone%2CTown%2CRegion%0ASunrise%20Care%20Home%2CMargaret%20Jones%2Cmanager%40sunrise.co.uk%2C01234%20567890%2CManchester%2CNorth%20West" download="care_homes_template.csv" style="color:var(--primary);">Download template</a>
          &nbsp;&middot;&nbsp; <a href="https://www.cqc.org.uk/about-us/transparency/using-cqc-data" target="_blank" rel="noopener" style="color:var(--primary);">Get data from CQC &#x2197;</a>
        </div>
        ${renderCsvUploadCard('care_home', state)}
      </div>


            <!-- Theatres CSV Upload -->
      <div class="import-card">
        <div class="import-card-header">
          <div class="import-card-icon">${icon('building',22)}</div>
          <div class="import-card-meta">
            <div class="import-card-title">Private Hospitals — Theatre Managers CSV</div>
            <div class="import-card-sub">Upload a CSV of private hospital theatre manager contacts. Auto-detects name, email, phone, hospital name, town and region.</div>
          </div>
          <span class="import-badge live">Live</span>
        </div>
        <div class="import-card-template-hint" style="font-size:12px;color:var(--grey-500);margin:0 0 12px 0;padding:0 4px;">
          Expected columns: <code>Hospital Name</code> <code>Contact Name</code> <code>Email</code> <code>Phone</code> <code>Town</code> <code>Region</code> &mdash;
          <a href="data:text/csv;charset=utf-8,Hospital%20Name%2CContact%20Name%2CEmail%2CPhone%2CTown%2CRegion%0ACromwell%20Hospital%2CSarah%20Smith%2Ctheatres%40cromwell.co.uk%2C020%201234%205678%2CLondon%2CLondon" download="private_theatres_template.csv" style="color:var(--primary);">Download template</a>
          &nbsp;&middot;&nbsp; <a href="https://www.phin.org.uk/find-a-hospital" target="_blank" rel="noopener" style="color:var(--primary);">Find hospitals via PHIN &#x2197;</a>
        </div>
        ${renderCsvUploadCard('private_theatre', state)}
      </div>


    </div>
  `;
}

// ============================================================================
//  DASHBOARD
// ============================================================================

const CM_API = 'https://udttpnaenmyxviuiwxqw.supabase.co/functions/v1/contact-manager';
const CM_ANON = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVkdHRwbmFlbm15eHZpdWl3eHF3Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzkxNzAwODIsImV4cCI6MjA5NDc0NjA4Mn0.b7zeFYbNPSo7WjFu6-VFhMVelD2g1ja9m3af0Jb5geU';

async function callCM(action, extra = {}) {
  const res = await fetch(CM_API, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + CM_ANON },
    body: JSON.stringify({ action, ...extra }),
  });
  return res.json();
}

async function loadDashboard() {
  state.dashboardLoading = true;
  state.dashboardData = null;
  render();
  try {
    state.dashboardData = await callCM('dashboard');
  } catch(e) {
    state.dashboardData = { error: e.message };
  }
  state.dashboardLoading = false;
  render();
}

function renderDashboard() {
  const d = state.dashboardData;
  const loading = state.dashboardLoading;

  if (loading || !d) {
    return `<div class="dash-loading"><div class="dash-spinner"></div><p>Loading dashboard…</p></div>`;
  }
  if (d.error) {
    return `<div class="dash-error">Failed to load dashboard: ${esc(d.error)}</div>`;
  }

  const t = d.totals || {};
  const p = d.pipeline || {};
  const s = d.sources || {};
  const emailPct = t.all ? Math.round((t.emailable / t.all) * 100) : 0;

  const pipelineStages = [
    { key: 'new',       label: 'New',       count: p.new       || 0, color: '#6B7280', action: () => { state.view='database'; state.dbStage='new'; loadContactsPage().then(render); } },
    { key: 'contacted', label: 'Contacted', count: p.contacted || 0, color: '#3B82F6', action: () => { state.view='database'; state.sourceFilter='all'; state.dbStage='contacted'; loadContactsPage().then(render); } },
    { key: 'responded', label: 'Responded', count: p.responded || 0, color: '#F59E0B', action: () => { state.view='database'; state.dbStage='responded'; loadContactsPage().then(render); } },
    { key: 'meeting',   label: 'Meeting',   count: p.meeting   || 0, color: '#8B5CF6', action: () => { state.view='database'; state.dbStage='meeting';   loadContactsPage().then(render); } },
    { key: 'live',      label: 'Live',      count: p.live      || 0, color: '#10B981', action: () => { state.view='database'; state.subTab='live'; state.dbStage='all'; loadContactsPage().then(render); } },
  ];
  const pipelineTotal = Object.values(p).reduce((a, b) => a + b, 0) || 1;

  const recent = d.recentSends || [];

  return `
    <div class="dash-wrap">

      <!-- Stat cards -->
      <div class="dash-stats">
        <div class="dash-stat">
          <div class="dash-stat-val">${(t.all || 0).toLocaleString()}</div>
          <div class="dash-stat-lbl">Total contacts</div>
          <div class="dash-stat-sub">${emailPct}% emailable</div>
        </div>
        <div class="dash-stat ${(t.followUpsDue || 0) > 0 ? 'dash-stat-alert' : ''}">
          <div class="dash-stat-val">${(t.followUpsDue || 0).toLocaleString()}</div>
          <div class="dash-stat-lbl">Follow-ups due</div>
          <div class="dash-stat-sub">${(t.followUpsDue || 0) > 0 ? '<a class="dash-link" data-dash-action="followup">View list →</a>' : 'None due today'}</div>
        </div>
        <div class="dash-stat">
          <div class="dash-stat-val">${(t.sentThisWeek || 0).toLocaleString()}</div>
          <div class="dash-stat-lbl">Sent this week</div>
          <div class="dash-stat-sub">${(t.sentToday || 0).toLocaleString()} today &middot; ${(t.sentThisMonth || 0).toLocaleString()} this month</div>
        </div>
        <div class="dash-stat">
          <div class="dash-stat-val">${(t.newToday || 0).toLocaleString()}</div>
          <div class="dash-stat-lbl">New leads today</div>
          <div class="dash-stat-sub">from scrapers &amp; uploads</div>
        </div>
      </div>

      <div class="dash-cols">
        <div class="dash-col-main">

          <!-- Pipeline funnel -->
          <div class="dash-card">
            <div class="dash-card-title">Pipeline</div>
            <div class="dash-pipeline">
              ${pipelineStages.map(s => {
                const pct = Math.max(4, Math.round((s.count / pipelineTotal) * 100));
                return `
                  <div class="dash-pipe-row" data-pipe-stage="${s.key}">
                    <div class="dash-pipe-label">${s.label}</div>
                    <div class="dash-pipe-bar-wrap">
                      <div class="dash-pipe-bar" style="width:${pct}%;background:${s.color}"></div>
                    </div>
                    <div class="dash-pipe-count" style="color:${s.color}">${s.count.toLocaleString()}</div>
                  </div>`;
              }).join('')}
            </div>
          </div>

          <!-- Emails sent by source -->
          <div class="dash-card">
            <div class="dash-card-title">Emails sent by source</div>
            <div class="dash-sends-head"><span class="dash-sends-name"></span><span class="dash-sends-num">Today</span><span class="dash-sends-num">7 days</span><span class="dash-sends-num">30 days</span></div>
            ${[
              { key: 'ahp', label: 'AHP (NHS Jobs + Scotland)' },
              { key: 'gp_surgery', label: 'GP Surgeries' },
              { key: 'anp', label: 'ANP' },
              { key: 'enp', label: 'ENP' },
            ].map(row => {
              const v = (d.sendsBySource || {})[row.key] || {};
              return `<div class="dash-sends-row">
                <span class="dash-sends-name">${row.label}</span>
                <span class="dash-sends-num">${(v.today||0).toLocaleString()}</span>
                <span class="dash-sends-num">${(v.week||0).toLocaleString()}</span>
                <span class="dash-sends-num">${(v.month||0).toLocaleString()}</span>
              </div>`;
            }).join('')}
          </div>
        </div>

        <div class="dash-col-side">

          <!-- Quick actions -->
          <div class="dash-card">
            <div class="dash-card-title">Quick actions</div>
            <div class="dash-actions">
              <button class="btn primary dash-action-btn" data-dash-action="compose">${icon('mail')} Send outreach batch</button>
              <button class="btn dash-action-btn" data-dash-action="import">${icon('download')} Import AHP contacts</button>
              <button class="btn dash-action-btn" data-dash-action="database">${icon('list')} View all contacts</button>
              <button class="btn dash-action-btn" data-dash-action="followup">${icon('bell')} Follow-ups due (${t.followUpsDue || 0})</button>
            </div>
          </div>

          <!-- Recent activity -->
          <div class="dash-card">
            <div class="dash-card-title">Recent sends</div>
            ${recent.length === 0
              ? `<p class="muted" style="font-size:12px;padding:8px 0;">No emails sent yet.</p>`
              : `<div class="dash-recent">
                  ${recent.map(r => {
                    const c = r.contacts || {};
                    const name = [c.first_name, c.last_name].filter(Boolean).join(' ') || c.email || 'Unknown';
                    const when = r.sent_at ? new Date(r.sent_at).toLocaleDateString('en-GB', { day:'numeric', month:'short' }) : '';
                    return `<div class="dash-recent-row">
                      <div class="dash-recent-name">${esc(c.org || name)}</div>
                      <div class="dash-recent-meta">${esc(name)} · ${when}</div>
                    </div>`;
                  }).join('')}
                </div>`}
          </div>

        </div>
      </div>
    </div>
  `;
}




async function loadResponsesData() {
  state.responsesLoading = true; render();
  try {
    const [evRes, replRes, unsubRes] = await Promise.all([
      sb.from('email_events')
        .select('id, event_type, email, occurred_at, link_url, event_data, contacts(first_name, last_name, org)')
        .order('occurred_at', { ascending: false }).limit(200),
      sb.from('replies')
        .select('id, from_email, from_name, subject, body_preview, full_body, received_at, read, contacts(first_name, last_name, org, email)')
        .order('received_at', { ascending: false }).limit(50),
      sb.from('contacts')
        .select('id, first_name, last_name, org, email, notes, status')
        .eq('status', 'unsubscribed')
        .order('updated_at', { ascending: false }).limit(100),
    ]);
    const events  = evRes.data   || [];
    const replies = replRes.data || [];
    const unsubs  = unsubRes.data || [];
    const unread  = replies.filter(function(r) { return !r.read; }).length;
    const bounceEvents = events.filter(function(e) { return e.event_type === 'hard_bounce' || e.event_type === 'soft_bounce'; });
    state.responsesData = {
      events, replies, unsubs,
      stats: {
        total_opens: events.filter(function(e) { return e.event_type === 'opened'; }).length,
        total_clicks: events.filter(function(e) { return e.event_type === 'clicked'; }).length,
        total_bounces: bounceEvents.length,
        total_unsubscribed: unsubs.length,
        unread_replies: unread,
      },
    };
  } catch(e) { state.responsesData = { error: e.message }; }
  state.responsesLoading = false; render();
}

async function syncM365() {
  state.m365Syncing = true; state.m365SyncResult = null; render();
  try {
    if (!state.m365ClientId) {
      state.m365ShowClientIdInput = true;
      state.m365Syncing = false; render(); return;
    }
    if (typeof window.msal === 'undefined') {
      throw new Error('Microsoft authentication library not loaded yet. Please refresh and try again.');
    }
    const msalInstance = new window.msal.PublicClientApplication({
      auth: { clientId: state.m365ClientId, authority: 'https://login.microsoftonline.com/common', redirectUri: window.location.origin }
    });
    await msalInstance.initialize();
    const tokenResponse = await msalInstance.acquireTokenPopup({ scopes: ['Mail.Read', 'User.Read'] });
    const { data: { session } } = await sb.auth.getSession();
    const res = await fetch('https://udttpnaenmyxviuiwxqw.supabase.co/functions/v1/m365-sync', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + session.access_token },
      body: JSON.stringify({ m365Token: tokenResponse.accessToken, daysBack: state.m365DaysBack || 30 }),
    });
    state.m365SyncResult = await res.json();
    if (state.m365SyncResult.success) {
      await loadResponsesData();
      toast('Synced ' + state.m365SyncResult.synced + ' replies from Outlook');
    }
  } catch(e) { state.m365SyncResult = { success: false, error: e.message }; }
  state.m365Syncing = false; render();
}

async function markReplyRead(replyId) {
  await sb.from('replies').update({ read: true }).eq('id', replyId);
  if (state.responsesData && state.responsesData.replies) {
    var r = state.responsesData.replies.find(function(r) { return r.id === replyId; });
    if (r) r.read = true;
  }
  render();
}


async function addContactFromReply(replyId) {
  state.addFromReplyLoading = replyId; render();
  try {
    const reply = state.responsesData.replies.find(r => r.id === replyId);
    if (!reply) throw new Error('Reply not found');
    const email = reply.from_email || '';
    if (!email) throw new Error('No email address in this reply');
    // Check if already in DB
    const { data: existing } = await sb.from('contacts').select('id').eq('email', email.toLowerCase()).single();
    if (existing) {
      toast('Contact already in database');
    } else {
      const nameParts = (reply.from_name || '').split(' ');
      await sb.from('contacts').insert({
        first_name: nameParts[0] || '',
        last_name: nameParts.slice(1).join(' ') || '',
        email: email.toLowerCase().trim(),
        org: reply.contacts?.org || '',
        status: 'lead',
        notes: 'Source: Added from email reply | ' + new Date().toISOString().split('T')[0],
      });
      toast('✓ Contact added to database');
      await loadStatusCounts();
    }
  } catch(e) { toast('Error: ' + e.message); }
  state.addFromReplyLoading = null; render();
}

function renderResponses() {
  if (state.responsesLoading || !state.responsesData) {
    return '<div class="dash-loading"><div class="dash-spinner"></div><p>Loading responses&hellip;</p></div>';
  }
  if (state.responsesData.error) {
    return '<div class="dash-error">Error: ' + esc(state.responsesData.error) + '</div>';
  }

  var d = state.responsesData;
  var s = d.stats || {};
  var replies = d.replies || [];
  var events  = d.events  || [];
  var unsubs  = d.unsubs  || [];

  var EVENT_ICON  = { opened:'&#x1F441;', clicked:'&#x1F5B1;', delivered:'&#x2713;', hard_bounce:'&#x26A0;', soft_bounce:'&#x26A0;', unsubscribed:'&#x1F6AB;', complaint:'&#x26A0;' };
  var EVENT_CLASS = { opened:'event-open', clicked:'event-click', hard_bounce:'event-bounce', soft_bounce:'event-bounce', unsubscribed:'event-bounce', complaint:'event-bounce' };

  var bounceEvents = events.filter(function(e) { return e.event_type === 'hard_bounce' || e.event_type === 'soft_bounce'; });

  // ── Stat cards ────────────────────────────────────────────────────────────
  var stats = '<div class="dash-stats" style="margin-bottom:16px;">'
    + '<div class="dash-stat"><div class="dash-stat-val">' + (s.unread_replies || 0) + '</div><div class="dash-stat-lbl">UNREAD REPLIES<br><span style="font-size:10px;font-weight:400;">' + replies.length + ' total</span></div></div>'
    + '<div class="dash-stat"><div class="dash-stat-val">' + (s.total_opens || 0) + '</div><div class="dash-stat-lbl">EMAIL OPENS<br><span style="font-size:10px;font-weight:400;">Via Brevo</span></div></div>'
    + '<div class="dash-stat"><div class="dash-stat-val">' + (s.total_clicks || 0) + '</div><div class="dash-stat-lbl">LINK CLICKS<br><span style="font-size:10px;font-weight:400;">' + (s.total_unsubscribed || 0) + ' unsubscribed</span></div></div>'
    + '<div class="dash-stat' + (bounceEvents.length > 0 ? ' dash-stat-alert' : '') + '"><div class="dash-stat-val">' + bounceEvents.length + '</div><div class="dash-stat-lbl">BOUNCES<br><span style="font-size:10px;font-weight:400;">' + (bounceEvents.length === 0 ? 'All good' : bounceEvents.filter(function(e){return e.event_type==='hard_bounce';}).length + ' hard, ' + bounceEvents.filter(function(e){return e.event_type==='soft_bounce';}).length + ' soft') + '</span></div></div>'
    + '</div>';

  // ── Bounce panel ─────────────────────────────────────────────────────────
  var bounceHtml = '<div class="responses-panel" style="margin-bottom:16px;grid-column:1/-1;">'
    + '<div class="responses-panel-header"><h3>&#x26A0; Bounced Emails (' + bounceEvents.length + ')</h3>'
    + (bounceEvents.length === 0 ? '<span class="muted" style="font-size:11px;">None yet — bounces will appear here automatically once Brevo webhook is active</span>' : '<span class="muted" style="font-size:11px;">Hard bounce = invalid address. Soft bounce = temporary failure.</span>')
    + '</div>';
  if (bounceEvents.length > 0) {
    var bounceRows = bounceEvents.map(function(ev) {
      var c = ev.contacts || {};
      var name = esc([c.first_name, c.last_name].filter(Boolean).join(' ')) || esc(ev.email);
      var org = esc(c.org || '');
      var reason = ev.event_data ? (ev.event_data.reason || ev.event_data.error || ev.event_data.description || '') : '';
      var when = ev.occurred_at ? new Date(ev.occurred_at).toLocaleDateString('en-GB') : '';
      var typeLabel = ev.event_type === 'hard_bounce' ? '<span style="background:#FEF2F2;color:#DC2626;padding:2px 6px;border-radius:4px;font-size:10px;font-weight:600;">HARD</span>'
                    : '<span style="background:#FFF7ED;color:#EA580C;padding:2px 6px;border-radius:4px;font-size:10px;font-weight:600;">SOFT</span>';
      return '<tr>'
        + '<td style="font-weight:500;">' + name + '</td>'
        + '<td class="muted">' + org + '</td>'
        + '<td style="font-size:12px;color:var(--grey-600);">' + esc(ev.email) + '</td>'
        + '<td>' + typeLabel + '</td>'
        + '<td class="muted" style="font-size:11px;max-width:220px;" title="' + esc(String(reason)) + '">' + esc(String(reason).slice(0,60)) + (String(reason).length > 60 ? '&hellip;' : '') + '</td>'
        + '<td class="muted" style="font-size:11px;">' + when + '</td>'
        + '</tr>';
    }).join('');
    bounceHtml += '<div style="overflow-x:auto;"><table class="table"><thead><tr>'
      + '<th>Contact</th><th>Organisation</th><th>Email</th><th>Type</th><th>Reason</th><th>Date</th>'
      + '</tr></thead><tbody>' + bounceRows + '</tbody></table></div>';
  } else {
    bounceHtml += '<p class="muted" style="font-size:12px;padding:8px 0;">Set up the Brevo webhook to start tracking bounces automatically:<br>'
      + 'Brevo &#x2192; Transactional &#x2192; Settings &#x2192; Webhooks &#x2192; Add URL:<br>'
      + '<code style="font-size:10px;background:var(--grey-100);padding:2px 6px;border-radius:3px;">https://udttpnaenmyxviuiwxqw.supabase.co/functions/v1/brevo-webhook</code><br>'
      + 'Tick: Delivered, Opened, Clicked, Soft bounce, Hard bounce, Unsubscribed</p>';
  }
  bounceHtml += '</div>';

  // ── Unsubscribed panel ────────────────────────────────────────────────────
  var unsubHtml = '';
  if (unsubs.length > 0) {
    var unsubRows = unsubs.map(function(c) {
      var name = esc([c.first_name, c.last_name].filter(Boolean).join(' ')) || esc(c.email);
      var source = '';
      if (c.notes) {
        var m = c.notes.match(/Unsubscribed[^|]+/i);
        if (m) source = m[0].trim();
      }
      return '<tr>'
        + '<td style="font-weight:500;">' + name + '</td>'
        + '<td class="muted">' + esc(c.org || '') + '</td>'
        + '<td style="font-size:12px;color:var(--grey-600);">' + esc(c.email || '') + '</td>'
        + '<td class="muted" style="font-size:11px;">' + esc(source) + '</td>'
        + '</tr>';
    }).join('');
    unsubHtml = '<div class="responses-panel" style="margin-bottom:16px;grid-column:1/-1;">'
      + '<div class="responses-panel-header"><h3>&#x1F6AB; Unsubscribed (' + unsubs.length + ')</h3>'
      + '<span class="muted" style="font-size:11px;">Auto-marked — these contacts are excluded from all future sends</span></div>'
      + '<div style="overflow-x:auto;"><table class="table"><thead><tr>'
      + '<th>Contact</th><th>Organisation</th><th>Email</th><th>Source</th>'
      + '</tr></thead><tbody>' + unsubRows + '</tbody></table></div>'
      + '</div>';
  }

  // ── M365 sync panel ───────────────────────────────────────────────────────
  var syncResult = '';
  if (state.m365SyncResult && !state.m365Syncing) {
    syncResult = '<div class="import-result ' + (state.m365SyncResult.success ? 'ok' : 'err') + '" style="margin-bottom:10px;">'
      + (state.m365SyncResult.success
         ? '<p style="font-size:13px;">&#10003; Synced ' + state.m365SyncResult.synced + ' new repl' + (state.m365SyncResult.synced === 1 ? 'y' : 'ies')
           + ' (' + state.m365SyncResult.total_messages + ' emails checked)'
           + (state.m365SyncResult.auto_unsubscribed > 0 ? ' &mdash; <strong>' + state.m365SyncResult.auto_unsubscribed + ' auto-unsubscribed</strong>' : '') + '</p>'
         : '<p style="color:#DC2626;font-size:13px;">&#10005; ' + esc(state.m365SyncResult.error || 'Sync failed') + '</p>')
      + '</div>';
  }

  var clientIdInput = '';
  if (state.m365ShowClientIdInput) {
    clientIdInput = '<div class="m365-setup">'
      + '<p style="font-size:13px;margin-bottom:8px;">Enter your Azure App Client ID to connect Outlook:</p>'
      + '<input class="search" id="m365-client-id-input" placeholder="e.g. 12345678-1234-1234-1234-123456789abc" value="' + esc(state.m365ClientId||'') + '" style="margin-bottom:8px;width:100%;">'
      + '<button class="btn primary" id="save-m365-client-id">Save &amp; Connect</button>'
      + '<p class="muted" style="font-size:11px;margin-top:8px;">Azure Portal &#x2192; App Registrations &#x2192; New &#x2192; redirect URI = ' + window.location.origin + ' &#x2192; Mail.Read permission</p>'
      + '</div>';
  }

  // ── Replies panel ─────────────────────────────────────────────────────────
  var repliesHtml = '';
  if (replies.length === 0) {
    repliesHtml = '<div class="responses-empty"><p>No replies synced yet.</p><p class="muted" style="font-size:12px;margin-top:6px;">Click Sync from Outlook to search your inbox.</p></div>';
  } else {
    repliesHtml = '<div class="replies-list">'
      + replies.map(function(r) {
          var c = r.contacts || {};
          var name = esc(r.from_name || [c.first_name, c.last_name].filter(Boolean).join(' ') || r.from_email);
          var when = r.received_at ? new Date(r.received_at).toLocaleDateString('en-GB', { day:'numeric', month:'short', hour:'2-digit', minute:'2-digit' }) : '';
          var isExpanded = state.expandedReplyId === r.id;
          var isLoading  = state.addFromReplyLoading === r.id;
          var bodyText = isExpanded
            ? esc(r.full_body || r.body_preview || '(no body)')
            : esc((r.body_preview || '').slice(0, 120) + (r.body_preview && r.body_preview.length > 120 ? '...' : ''));
          return '<div class="reply-card ' + (r.read ? '' : 'reply-unread') + '" style="cursor:pointer;">'
            + '<div class="reply-card-header" data-expand-reply="' + r.id + '">'
            + '<div class="reply-from">' + name + '</div>'
            + '<div class="reply-when">' + when + '</div></div>'
            + '<div class="reply-org" data-expand-reply="' + r.id + '">' + esc(c.org || r.from_email) + '</div>'
            + '<div class="reply-subject" data-expand-reply="' + r.id + '">' + esc(r.subject || '(no subject)') + '</div>'
            + '<div class="reply-preview" data-expand-reply="' + r.id + '" style="white-space:' + (isExpanded ? 'pre-wrap;font-size:12px;max-height:300px;overflow-y:auto;background:var(--grey-50);padding:8px;border-radius:4px;margin-top:4px;' : 'normal;') + '">' + bodyText + '</div>'
            + '<div style="display:flex;gap:8px;margin-top:8px;flex-wrap:wrap;">'
            + '<button class="btn small" data-expand-reply="' + r.id + '">' + (isExpanded ? '&#x25B2; Collapse' : '&#x25BC; Read full email') + '</button>'
            + '<button class="btn small" style="background:var(--green);color:#fff;border-color:var(--green);" data-add-reply="' + r.id + '" ' + (isLoading ? 'disabled' : '') + '>'
            + (isLoading ? '&#x23F3; Adding&hellip;' : '&#x2795; Add to Database') + '</button>'
            + (!r.read ? '<button class="btn small reply-read-btn" data-reply-id="' + r.id + '">Mark read</button>' : '')
            + '</div>'
            + '</div>';
        }).join('')
      + '</div>';
  }

  // ── Events panel ─────────────────────────────────────────────────────────
  var eventsHtml = '';
  if (events.length === 0) {
    eventsHtml = '<div class="responses-empty">'
      + '<p>No engagement events yet.</p>'
      + '<p class="muted" style="font-size:12px;margin-top:6px;">Set up the Brevo webhook to start tracking opens and clicks automatically.<br>'
      + 'Brevo &#x2192; Transactional &#x2192; Settings &#x2192; Webhooks &#x2192; Add:<br>'
      + '<code style="font-size:10px;">https://udttpnaenmyxviuiwxqw.supabase.co/functions/v1/brevo-webhook</code><br>'
      + 'Tick: Delivered, Opened, Clicked, Soft bounce, Hard bounce, Unsubscribed.</p>'
      + '</div>';
  } else {
    eventsHtml = '<div class="events-list">'
      + events.map(function(ev) {
          var c = ev.contacts || {};
          var who  = esc([c.first_name, c.last_name].filter(Boolean).join(' ')) || esc(ev.email);
          var icon = EVENT_ICON[ev.event_type]  || '&bull;';
          var cls  = EVENT_CLASS[ev.event_type] || 'event-default';
          var when = ev.occurred_at ? new Date(ev.occurred_at).toLocaleDateString('en-GB', { day:'numeric', month:'short', hour:'2-digit', minute:'2-digit' }) : '';
          return '<div class="event-row ' + cls + '">'
            + '<span class="event-icon">' + icon + '</span>'
            + '<div class="event-body"><div class="event-who">' + who + (c.org ? ' <span class="muted">&mdash; ' + esc(c.org) + '</span>' : '') + '</div>'
            + '<div class="event-type">' + esc(ev.event_type.replace(/_/g,' ')) + (ev.link_url ? ' <a href="' + esc(ev.link_url) + '" target="_blank" rel="noopener" style="font-size:11px;margin-left:4px;">link</a>' : '') + '</div></div>'
            + '<span class="event-when">' + when + '</span>'
            + '</div>';
        }).join('')
      + '</div>';
  }

  return '<div class="responses-wrap">'
    + stats
    + bounceHtml
    + unsubHtml
    + '<div class="responses-cols">'
    + '<div class="responses-panel">'
    + '<div class="responses-panel-header"><h3>&#x1F4EC; Replies from Outlook</h3>'
    + '<div style="display:flex;gap:8px;align-items:center;flex-wrap:wrap;">'
    + '<select class="select" id="m365-days" style="font-size:12px;padding:4px 8px;width:auto;">'
    + '<option value="7">Last 7 days</option>'
    + '<option value="30"' + (state.m365DaysBack === 30 ? ' selected' : '') + '>Last 30 days</option>'
    + '<option value="90"' + (state.m365DaysBack === 90 ? ' selected' : '') + '>Last 90 days</option>'
    + '</select>'
    + '<button class="btn primary" id="sync-m365-btn"' + (state.m365Syncing ? ' disabled' : '') + '>'
    + (state.m365Syncing ? '<span class="spinner-inline"></span> Syncing&hellip;' : '&#x1F504; Sync from Outlook')
    + '</button></div></div>'
    + clientIdInput + syncResult + repliesHtml
    + '</div>'
    + '<div class="responses-panel">'
    + '<div class="responses-panel-header"><h3>&#x1F4CA; Email Engagement</h3>'
    + '<span class="muted" style="font-size:11px;">Auto-tracked via Brevo webhook</span></div>'
    + eventsHtml
    + '</div>'
    + '</div></div>';
}


async function loadUserProfile() {
  try {
    var sess = (await sb.auth.getSession()).data.session;
    if (!sess) return;
    var res = await fetch('https://udttpnaenmyxviuiwxqw.supabase.co/functions/v1/user-manager', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + sess.access_token },
      body: JSON.stringify({ action: 'me' }),
    });
    if (!res.ok) return;
    var data = await res.json();
    state.userProfile = data.profile || null;
    if (data.profile) {
      state.senderEmail = data.profile.sender_email || '';
      state.senderName  = data.profile.sender_name  || '';
    }
  } catch(e) { console.warn('Profile load (non-fatal):', e.message); }
}


async function loadTeamUsers() {
  state.teamLoading = true; render();
  try {
    var sess = (await sb.auth.getSession()).data.session;
    if (!sess) { state.teamLoading = false; render(); return; }
    var res = await fetch('https://udttpnaenmyxviuiwxqw.supabase.co/functions/v1/user-manager', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + sess.access_token },
      body: JSON.stringify({ action: 'list' }),
    });
    if (res.ok) {
      var data = await res.json();
      state.teamUsers = data.users || [];
    }
  } catch(e) { console.error('loadTeamUsers:', e.message); }
  state.teamLoading = false; render();
}

async function sendInvite() {
  try {
    var sess = (await sb.auth.getSession()).data.session;
    if (!sess) return;
    var res = await fetch('https://udttpnaenmyxviuiwxqw.supabase.co/functions/v1/user-manager', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + sess.access_token },
      body: JSON.stringify({
        action: 'invite',
        email: state.inviteEmail,
        full_name: state.inviteName,
        role: 'user',
        allowed_sources: state.inviteSources,
        sender_email: state.inviteSenderEmail || state.inviteEmail,
        sender_name: state.inviteSenderName || state.inviteName,
      }),
    });
    state.inviteResult = await res.json();
    if (state.inviteResult.success) {
      state.inviteEmail = '';
      state.inviteName = '';
      state.inviteSources = [];
      state.inviteSenderEmail = '';
      state.inviteSenderName = '';
      await loadTeamUsers();
    }
  } catch(e) { state.inviteResult = { success: false, error: e.message }; }
  render();
}

async function saveSenderDetails() {
  state.senderSaving = true; state.senderSaved = false; render();
  try {
    var sess = (await sb.auth.getSession()).data.session;
    var res = await fetch('https://udttpnaenmyxviuiwxqw.supabase.co/functions/v1/user-manager', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + sess.access_token },
      body: JSON.stringify({ action: 'update_sender', sender_email: state.senderEmail, sender_name: state.senderName }),
    });
    var data = await res.json();
    if (data.success) {
      state.senderSaved = true;
      toast('Sender details saved');
      setTimeout(function() { state.senderSaved = false; render(); }, 3000);
    } else { toast('Error: ' + (data.error || 'Unknown')); }
  } catch(e) { toast('Error: ' + e.message); }
  state.senderSaving = false; render();
}

// ===== Vacancy Title Keywords editor (table: specialty_title_keywords) =====
var KW_SPECS = [
  ['pharmacy','Pharmacy'],
  ['gp_surgery','GP Surgery'],
  ['physiotherapy','Physiotherapy'],
  ['occupational_therapy','Occupational Therapy'],
  ['radiography','Radiography'],
  ['speech_language','Speech & Language'],
  ['audiology','Audiology'],
  ['biomedical_science','Biomedical Science'],
  ['sterile_services','Sterile Services'],
  ['mental_health','Mental Health'],
  ['operating_theatres','Operating Theatres'],
  ['dietetics','Dietetics'],
  ['podiatry','Podiatry'],
  ['orthoptics','Orthoptics'],
  ['art_therapy','Art Therapy'],
  ['paramedic','Paramedic'],
  ['prosthetics','Prosthetics'],
  ['advanced_nurse_practitioner','Advanced Nurse Practitioner (ANP)'],
  ['emergency_nurse_practitioner','Emergency Nurse Practitioner (ENP)']
];
var specKw = { loading:false, loaded:false, rows:[] };
async function loadSpecKeywords() {
  if (specKw.loading) return;
  specKw.loading = true;
  try {
    var r = await sb.from('specialty_title_keywords').select('id,specialty,keyword').order('keyword', { ascending: true });
    specKw.rows = (r && r.data) ? r.data : [];
    specKw.loaded = true;
  } catch (e) { console.warn('Keyword load (non-fatal):', e.message); }
  specKw.loading = false;
  render();
}
function renderSpecKeywordsSection() {
  if (!specKw.loaded) {
    if (!specKw.loading) loadSpecKeywords();
    return '<div class="settings-section"><h3 class="settings-section-title">' + icon('search') + ' Vacancy Title Keywords</h3><p class="muted" style="font-size:12px;">Loading keywords&hellip;</p></div>';
  }
  var byspec = {};
  specKw.rows.forEach(function(r){ (byspec[r.specialty] = byspec[r.specialty] || []).push(r); });
  var blocks = KW_SPECS.map(function(p){
    var spec = p[0], label = p[1];
    var list = byspec[spec] || [];
    var chips = list.length ? list.map(function(r){
      return '<span style="display:inline-flex;align-items:center;gap:4px;background:#EEF2FF;color:#3730A3;border-radius:12px;padding:2px 6px 2px 10px;font-size:12px;">'
        + esc(r.keyword)
        + '<button data-kw-del="' + r.id + '" title="Remove" style="border:none;background:transparent;color:#6366F1;cursor:pointer;font-size:15px;line-height:1;padding:0 2px;">&times;</button></span>';
    }).join('') : '<span class="muted" style="font-size:12px;">No keywords yet &mdash; add one below.</span>';
    return '<div style="margin-bottom:14px;">'
      + '<div style="font-weight:600;font-size:13px;margin-bottom:6px;">' + esc(label) + ' <span class="muted" style="font-weight:400;font-size:11px;">(' + list.length + ')</span></div>'
      + '<div style="display:flex;flex-wrap:wrap;gap:6px;margin-bottom:6px;">' + chips + '</div>'
      + '<div style="display:flex;gap:6px;max-width:440px;">'
      + '<input class="search kw-add-input" id="kw-add-input-' + spec + '" placeholder="add a vacancy-title term&hellip;" style="flex:1;" />'
      + '<button class="btn small" data-kw-add="' + spec + '">+ Add</button>'
      + '</div>'
      + '</div>';
  }).join('');
  return '<div class="settings-section">'
    + '<h3 class="settings-section-title">' + icon('search') + ' Vacancy Title Keywords</h3>'
    + '<p class="muted" style="font-size:12px;margin-bottom:14px;">A job is scraped into a source only if its <strong>vacancy title</strong> contains one of these terms. Add spelling variants (e.g. &ldquo;medicine management&rdquo; vs &ldquo;medicines management&rdquo;) to catch more roles, or remove terms that pull in the wrong jobs. Matching is case-insensitive partial match. Changes take effect on the next scrape.</p>'
    + blocks
    + '</div>';
}

async function loadAutoUnsubOrgs() {
  try {
    var res = await sb.from('auto_unsub_orgs').select('*').order('label', { ascending: true });
    state.autoUnsubOrgs = res.data || [];
  } catch (e) { state.autoUnsubOrgs = []; }
  render();
}

async function addAutoUnsubOrg() {
  var nameEl = document.getElementById('unsub-org-input');
  var name = ((nameEl ? nameEl.value : (state.unsubOrgInput || '')) || '').trim();
  if (!name) { state.unsubOrgMsg = 'Enter an organisation name first.'; render(); return; }
  state.unsubOrgAdding = true; state.unsubOrgMsg = ''; render();
  try {
    var pattern = '%' + name + '%';
    var ins = await sb.from('auto_unsub_orgs').insert({ pattern: pattern, label: name });
    if (ins.error && ins.error.code !== '23505') throw ins.error;
    var upd = await sb.from('contacts').update({ status: 'unsubscribed', updated_at: new Date().toISOString() }).ilike('org', pattern).neq('status', 'unsubscribed').select('id');
    var n = (upd.data || []).length;
    state.unsubOrgInput = '';
    state.unsubOrgMsg = 'Added. ' + n + ' existing contact(s) moved to Unsubscribed.';
    await loadAutoUnsubOrgs();
    if (typeof loadStatusCounts === 'function') await loadStatusCounts();
    if (typeof loadSourceCounts === 'function') await loadSourceCounts();
  } catch (e) {
    state.unsubOrgMsg = 'Error: ' + (e.message || e);
  }
  state.unsubOrgAdding = false; render();
}

async function removeAutoUnsubOrg(pattern) {
  if (!window.confirm('Remove this organisation from the Do Not Email list? Existing contacts stay Unsubscribed; only future scrapes will be allowed through.')) return;
  try {
    var del = await sb.from('auto_unsub_orgs').delete().eq('pattern', pattern);
    if (del.error) throw del.error;
    await loadAutoUnsubOrgs();
  } catch (e) {
    state.unsubOrgMsg = 'Error removing: ' + (e.message || e);
    render();
  }
}

function renderSettings() {
  var isAdmin = !state.userProfile || state.userProfile.role === 'admin';

  var sourceOptions = [
    {k:'gp_surgery',label:'GP Surgeries'},
    {k:'children_homes',label:"Children's Homes"},
    {k:'agency',label:'Agency Outreach'},
    {k:'ahp',label:'AHP (NHS Jobs)'},
    {k:'private_theatre',label:'Theatres'},
    {k:'care_home',label:'Care Homes'},
    {k:'bms',label:'BMS'},
    {k:'sterile',label:'Sterile Services'},
    {k:'nhs_staffbank',label:'NHS Staff Banks'},
  ];

  // Build sender section
  var senderSection = '<div class="settings-section">'
    + '<h3 class="settings-section-title">' + icon('mail') + ' My Sender Details</h3>'
    + '<p class="muted" style="font-size:12px;margin-bottom:12px;">Emails you send will come from this name and address. Must be verified in Brevo (Senders &amp; IPs &rarr; Add sender).</p>'
    + '<div class="import-form-row" style="max-width:520px;">'
    + '<div class="field"><label>Your Name</label>'
    + '<input class="search" id="sender-name-input" placeholder="e.g. Chris Thompson - Day Webster Group" value="' + esc(state.senderName || '') + '" /></div>'
    + '<div class="field"><label>Your Email</label>'
    + '<input class="search" id="sender-email-input" type="email" placeholder="e.g. chris@daywebster.com" value="' + esc(state.senderEmail || '') + '" /></div>'
    + '</div>'
    + '<div style="display:flex;align-items:center;gap:10px;margin-top:10px;">'
    + '<button class="btn primary" id="save-sender-btn"' + (state.senderSaving ? ' disabled' : '') + '>'
    + (state.senderSaving ? '<span class="spinner-inline"></span> Saving&hellip;' : 'Save Sender Details')
    + '</button>'
    + (state.senderSaved ? '<span style="color:var(--green-dark);font-size:13px;">&#10003; Saved</span>' : '')
    + '</div>'
    + '<p class="muted" style="font-size:11px;margin-top:8px;">&#9888; Verify your email in Brevo first: Senders &amp; IPs &#x2192; Senders &#x2192; Add &amp; verify.</p>'
    + '</div>';

  // Build team section (admin only)
  var teamSection = '';
  if (isAdmin) {
    var sourceCheckboxes = sourceOptions.map(function(s) {
      return '<label class="source-checkbox-label">'
        + '<input type="checkbox" class="invite-source-cb" value="' + s.k + '"'
        + (state.inviteSources.indexOf(s.k) >= 0 ? ' checked' : '') + '>'
        + s.label + '</label>';
    }).join('');

    var teamRows = state.teamUsers.map(function(u) {
      var isScott = u.email === 'scott.lane@daywebster.com';
      var srcs = (!u.allowed_sources || u.allowed_sources.length === 0) ? 'All sources' : u.allowed_sources.join(', ');
      var lastLogin = u.last_sign_in ? new Date(u.last_sign_in).toLocaleDateString('en-GB') : 'Never';
      return '<tr>'
        + '<td>' + esc(u.full_name || '—') + '</td>'
        + '<td>' + esc(u.email || '—') + '</td>'
        + '<td><span class="role-badge ' + (u.role === 'admin' ? 'role-admin' : 'role-user') + '">' + (u.role || 'user') + '</span></td>'
        + '<td class="muted" style="font-size:11px;">' + esc(srcs) + '</td>'
        + '<td class="muted" style="font-size:11px;">' + esc(u.sender_email || '—') + '</td>'
        + '<td class="muted" style="font-size:11px;">' + lastLogin + '</td>'
        + '<td>' + (isScott ? '<span class="muted">Admin</span>' : '<button class="btn small" data-reset-user="' + esc(u.user_id) + '" data-user-email="' + esc(u.email) + '">Reset password</button> <button class="btn small danger" data-delete-user="' + esc(u.user_id) + '" data-user-email="' + esc(u.email) + '">Remove</button>') + '</td>'
        + '</tr>';
    }).join('');

    var inviteResult = '';
    if (state.inviteResult) {
      inviteResult = '<span class="' + (state.inviteResult.success ? '' : 'text-danger') + '" style="font-size:13px;">'
        + (state.inviteResult.success ? '&#10003; Invite sent &mdash; they will receive a magic link to log in' : '&#10005; ' + esc(state.inviteResult.error || 'Error'))
        + '</span>';
    }

    teamSection = '<div class="settings-section">'
      + '<h3 class="settings-section-title">' + icon('users') + ' Team Management</h3>'
      + '<p class="muted" style="font-size:12px;margin-bottom:12px;">Invite team members and control which data sources they can access. Each user only sees their assigned sources.</p>'
      + '<div class="team-invite-form">'
      + '<div class="import-form-row">'
      + '<div class="field"><label>Full Name</label><input class="search" id="invite-name" placeholder="e.g. Chris Thompson" value="' + esc(state.inviteName) + '" /></div>'
      + '<div class="field"><label>Email</label><input class="search" id="invite-email" placeholder="chris@daywebster.com" value="' + esc(state.inviteEmail) + '" /></div>'
      + '</div>'
      + '<div class="import-form-row">'
      + '<div class="field"><label>Their Sender Name</label><input class="search" id="invite-sender-name" placeholder="Chris Thompson - Day Webster Group" /></div>'
      + '<div class="field"><label>Their Sender Email</label><input class="search" id="invite-sender-email" type="email" placeholder="chris@daywebster.com" /></div>'
      + '</div>'
      + '<div class="field" style="margin-bottom:10px;"><label>Source Access (leave blank = all sources)</label>'
      + '<div class="source-checkboxes">' + sourceCheckboxes + '</div></div>'
      + '<div style="display:flex;gap:8px;align-items:center;">'
      + '<button class="btn primary" id="send-invite-btn">&#x2709; Send Invite</button>'
      + inviteResult
      + '</div>'
      + '</div>'
      + (state.teamLoading ? '<p class="muted" style="margin-top:12px;">Loading team&hellip;</p>' : '')
      + (state.teamUsers.length > 0
          ? '<table class="table" style="margin-top:12px;"><thead><tr><th>Name</th><th>Email</th><th>Role</th><th>Sources</th><th>Sender Email</th><th>Last Login</th><th></th></tr></thead><tbody>' + teamRows + '</tbody></table>'
          : '<p class="muted" style="font-size:12px;margin-top:12px;">No team members yet.</p>')
      + '</div>';
  }

  var kwSection = renderSpecKeywordsSection();
    var blockRows = (state.autoUnsubOrgs || []).map(function(o){
    return '<div style="display:flex;align-items:center;justify-content:space-between;gap:8px;padding:7px 0;border-bottom:1px solid var(--border);">'
      + '<span style="font-size:13px;">' + esc(o.label || o.pattern) + '</span>'
      + '<button class="btn" data-unsub-del="' + esc(o.pattern) + '" style="padding:3px 12px;font-size:12px;">Remove</button>'
      + '</div>';
  }).join('');
  var blockSection = '<div class="settings-section">'
    + '<h3 class="settings-section-title">' + icon('ban') + ' Do Not Email (Auto-Unsubscribe)</h3>'
    + '<p class="muted" style="font-size:12px;margin-bottom:10px;">These organisations are still scraped, but every contact at them is automatically set to Unsubscribed so they are never emailed. Add an organisation when a client asks not to be contacted; remove it to allow emailing again. Matching is by partial name, so &ldquo;Barts Health&rdquo; also covers &ldquo;Barts Health NHS Trust&rdquo;.</p>'
    + '<div class="import-form-row" style="max-width:580px;align-items:flex-end;">'
    + '<div class="field" style="flex:1;"><label>Organisation name</label>'
    + '<input class="search" id="unsub-org-input" placeholder="e.g. Barts Health NHS Trust" value="' + esc(state.unsubOrgInput || '') + '" /></div>'
    + '<button class="btn primary" id="unsub-org-add"' + (state.unsubOrgAdding ? ' disabled' : '') + '>'
    + (state.unsubOrgAdding ? '<span class="spinner-inline"></span> Adding&hellip;' : '&#x2B; Add to list')
    + '</button>'
    + '</div>'
    + (state.unsubOrgMsg ? '<p class="muted" style="font-size:12px;margin-top:8px;">' + esc(state.unsubOrgMsg) + '</p>' : '')
    + '<div style="margin-top:14px;max-width:580px;">'
    + (blockRows || '<p class="muted" style="font-size:12px;">No organisations on the list yet.</p>')
    + '</div>'
    + '</div>';
  return '<div class="settings-wrap">'
    + senderSection
    + teamSection
    + kwSection
    + blockSection
    + '<div class="settings-section">'
    + '<h3 class="settings-section-title">' + icon('upload') + ' Export Data</h3>'
    + '<p class="muted" style="font-size:12px;margin-bottom:10px;">Download all contacts as CSV for backup or analysis.</p>'
    + '<button class="btn primary" id="export-csv-all">&#x2B07; Export All Contacts as CSV</button>'
    + '</div>'
    + '<div class="settings-section">'
    + '<h3 class="settings-section-title">' + icon('user') + ' Account</h3>'
    + '<p class="muted" style="font-size:12px;margin-bottom:10px;">Signed in as <strong>' + esc(state.user.email) + '</strong></p>'
    + '<button class="btn danger" id="sign-out-btn-settings">Sign Out</button>'
    + '</div>'
    + '</div>';
}


function renderModal() {
  const existing = document.querySelector('.modal-overlay');
  if (existing) existing.remove();
  if (!state.modal) return;

  let html = '';
  if (state.modal.type === 'edit-contact' || state.modal.type === 'add-contact') {
    const c = state.modal.contact;
    const isEdit = state.modal.type === 'edit-contact';
    // Determine which source the form should show:
    //  - Edit mode: parse the existing notes to find an embedded source tag.
    //  - Add mode: default to whichever source the user is currently filtering on
    //    in the Database view, falling back to GP surgery.
    const currentSource = isEdit
      ? extractSource(c.notes)
      : (MODAL_SOURCE_TAGS.hasOwnProperty(state.sourceFilter) ? state.sourceFilter : 'gp_surgery');
    // Show only the user-facing portion of the notes (with the source tag removed).
    const userNotes = stripSourceTag(c.notes);
    html = `
      <h2>${isEdit ? 'Edit' : 'Add'} Contact</h2>
      <div class="field-row">
        <div class="field"><label>Title</label><input id="m-title" value="${esc(c.title)}" /></div>
        <div class="field"><label>Job Title</label><input id="m-jobTitle" value="${esc(c.job_title)}" /></div>
      </div>
      <div class="field-row">
        <div class="field"><label>First Name *</label><input id="m-firstName" value="${esc(c.first_name)}" /></div>
        <div class="field"><label>Last Name</label><input id="m-lastName" value="${esc(c.last_name)}" /></div>
      </div>
      <div class="field"><label>Surgery / Org *</label><input id="m-org" value="${esc(c.org)}" /></div>
      <div class="field"><label>Email *</label><input id="m-email" value="${esc(c.email)}" /></div>
      <div class="field"><label>Phone</label><input id="m-phone" value="${esc(c.phone)}" /></div>
      <div class="field-row">
        <div class="field"><label>Town</label><input id="m-town" value="${esc(c.town)}" /></div>
        <div class="field"><label>Postcode</label><input id="m-postcode" value="${esc(c.postcode)}" /></div>
      </div>
      <div class="field-row">
        <div class="field"><label>Region</label><input id="m-region" value="${esc(c.region)}" /></div>
        <div class="field"><label>Country</label><input id="m-country" value="${esc(c.country)}" /></div>
      </div>
      <div class="field"><label>Source / Category *</label>
        <select id="m-source">
          ${MODAL_SOURCE_OPTIONS.map(o => `<option value="${o.k}" ${currentSource === o.k ? 'selected' : ''}>${o.l}</option>`).join('')}
        </select>
        <div class="muted" style="font-size:11px;margin-top:4px;">Which list does this contact belong to? Determines where they appear in the Database tabs.</div>
      </div>
      ${isEdit ? `
        <div class="field"><label>Status</label>
          <select id="m-status">
            <option value="lead" ${c.status==='lead'?'selected':''}>Lead</option>
            <option value="live" ${c.status==='live'?'selected':''}>Live</option>
            <option value="unsubscribed" ${c.status==='unsubscribed'?'selected':''}>Unsubscribed</option>
          </select>
        </div>` : ''}
      <div class="field"><label>Notes</label><textarea id="m-notes" placeholder="Optional notes (the Source above is stored automatically — you don't need to type it here)">${esc(userNotes)}</textarea></div>
      <div class="modal-actions">
        <button class="btn" id="m-cancel">Cancel</button>
        <button class="btn primary" id="m-save">Save</button>
      </div>
    `;
  } else if (state.modal.type === 'edit-template' || state.modal.type === 'add-template') {
    const t = state.modal.template;
    html = `
      <h2>${state.modal.type === 'edit-template' ? 'Edit' : 'New'} Template</h2>
      <div class="token-helper">
        Click a token to insert into the focused field below:
        <code class="token-insert" data-token="{{FirstName}}">{{FirstName}}</code>
        <code class="token-insert" data-token="{{LastName}}">{{LastName}}</code>
        <code class="token-insert" data-token="{{Title}}">{{Title}}</code>
        <code class="token-insert" data-token="{{Org}}">{{Org}}</code>
        <code class="token-insert" data-token="{{Town}}">{{Town}}</code>
        <code class="token-insert" data-token="{{Region}}">{{Region}}</code>
        <code class="token-insert" data-token="{{JobTitle}}">{{JobTitle}}</code>
      </div>
      <div class="field"><label>Template Name *</label><input id="t-name" value="${esc(t.name)}" /></div>
      <div class="field"><label>Subject Line *</label><input id="t-subject" value="${esc(t.subject)}" /></div>
      <div class="field"><label>Email Body *</label><textarea id="t-body" style="min-height:240px;">${esc(t.body)}</textarea></div>
      <div class="modal-actions">
        <button class="btn" id="m-cancel">Cancel</button>
        <button class="btn primary" id="m-save">Save</button>
      </div>
    `;
  } else if (state.modal.type === 'confirm') {
    html = `
      <h2>${esc(state.modal.title)}</h2>
      <p style="margin-bottom:16px;">${esc(state.modal.message)}</p>
      <div class="modal-actions">
        <button class="btn" id="m-cancel">Cancel</button>
        <button class="btn ${state.modal.danger ? 'danger' : 'primary'}" id="m-confirm">${esc(state.modal.confirmText || 'Confirm')}</button>
      </div>
    `;
  }

  const overlay = document.createElement('div');
  overlay.className = 'modal-overlay';
  overlay.innerHTML = `<div class="modal">${html}</div>`;
  document.body.appendChild(overlay);
  bindModalEvents();
}

// ============================================================================
//  EVENT BINDING
// ============================================================================

function bindEvents() {
  document.querySelectorAll('.tab').forEach(t => {
    t.onclick = async () => {
      state.view = t.dataset.view;
      state.page = 1;
      if (state.view === 'dashboard') { loadDashboard(); return; }
      if (state.view === 'database') await loadContactsPage();
      if (state.view === 'compose') { state.composePreviewCounts = null; state.composeBrevoResult = null; }
      if (state.view === 'import') state.importResult = null;
      if (state.view === 'responses') { loadResponsesData(); return; }
      if (state.view === 'settings') { loadTeamUsers(); loadAutoUnsubOrgs(); }
      render();
    };
  });

  document.querySelectorAll('.subtab').forEach(t => {
    t.onclick = async () => {
      state.subTab = t.dataset.subtab;
      state.dbStage = 'all';
      state.page = 1;
      state.search = '';
      state.regionFilter = '';
      // Keep sourceFilter — don't reset it when switching between Lead/Live/Unsub
      if (false) { state.sourceFilter = 'all'; state.sourceStatusCounts = { lead: null, live: null, unsubscribed: null }; }
      await loadContactsPage();
      render();
    };
  });

  // Specialty sub-filter tabs (AHP view)
  document.querySelectorAll('[data-specialty]').forEach(btn => {
    btn.onclick = async () => {
      state.ahpSpecialtyFilter = btn.dataset.specialty;
      state.page = 1;
      await loadContactsPage();
      render();
    };
  });

  // Stage filter tabs (database view)
  document.querySelectorAll('[data-dstage]').forEach(btn => {
    btn.onclick = async () => {
      state.dbStage = btn.dataset.dstage;
      state.page = 1;
      await loadContactsPage();
      render();
    };
  });

  // Dashboard quick-action links
  document.querySelectorAll('[data-dash-action]').forEach(el => {
    el.onclick = () => {
      const a = el.dataset.dashAction;
      if (a === 'followup') {
        state.view = 'database';
        state.subTab = 'lead';
        state.dbStage = 'followup';
        loadContactsPage().then(render);
      } else if (a === 'compose') {
        state.view = 'compose';
        render();
      } else if (a === 'import') {
        state.view = 'import';
        render();
      } else if (a === 'database') {
        state.view = 'database';
        state.dbStage = 'all';
        loadContactsPage().then(render);
      }
    };
  });

  // Source filter tabs
  document.querySelectorAll('.source-tab').forEach(t => {
    t.onclick = async () => {
      state.sourceFilter = t.dataset.source;
      state.subTab = 'lead';
      state.dbStage = 'all';
      state.ahpSpecialtyFilter = 'all';
      state.selected = new Set();
      state.page = 1;
      state.search = '';
      state.regionFilter = '';
      await Promise.all([loadSourceStatusCounts(), loadContactsPage()]);
      render();
    };
  });

  // Select-all checkbox
  const selectAllCb = document.getElementById('select-all-cb');
  if (selectAllCb) {
    const allPageSel = state.currentRows.length > 0 && state.selected.size === state.currentRows.length;
    const somePageSel = state.selected.size > 0 && !allPageSel;
    selectAllCb.indeterminate = somePageSel;
    selectAllCb.onchange = () => {
      if (selectAllCb.checked) {
        state.currentRows.forEach(c => state.selected.add(c.id));
      } else {
        state.currentRows.forEach(c => state.selected.delete(c.id));
      }
      render();
    };
  }

  // Row checkboxes
  document.querySelectorAll('.row-cb').forEach(cb => {
    cb.onclick = e => e.stopPropagation();
    cb.onchange = () => {
      cb.checked ? state.selected.add(cb.dataset.id) : state.selected.delete(cb.dataset.id);
      render();
    };
  });

  // Import scraper form bindings
  const impSpecialty = $('#imp-specialty');
  if (impSpecialty) impSpecialty.onchange = e => { state.importSpecialty = e.target.value; };
  const impRegion = $('#imp-region');
  if (impRegion) impRegion.onchange = e => { state.importRegion = e.target.value; };
  const impBand = $('#imp-band');
  if (impBand) impBand.onchange = e => { state.importBand = e.target.value; };
  const impLimit = $('#imp-limit');
  if (impLimit) impLimit.onchange = e => { state.importLimit = parseInt(e.target.value); };
  // Direct Brevo send panel bindings
  const bRevoFilterBtn = $('#brevo-filter-send-btn');
  if (bRevoFilterBtn) bRevoFilterBtn.onclick = () => { if (!state.composeBrevoSending) sendFilteredViaBrevo(); };

  const bRevoBtn = $('#brevo-send-btn');
  if (bRevoBtn) bRevoBtn.onclick = () => { if (!state.composeBrevoSending) sendSelectedViaBrevo(); };

  const clearSelectedSend = $('#clear-selected-send');
  if (clearSelectedSend) clearSelectedSend.onclick = () => {
    state.composeSelectedIds = null;
    state.composeBrevoResult = null;
    state.selected = new Set();
    render();
  };

  const bRevoTpl = $('#brevo-template-picker');
  if (bRevoTpl) bRevoTpl.onchange = (e) => {
    state.composeTemplateId = e.target.value;
    render();
  };

  const runScrapeBtn = $('#run-scrape-btn');
  if (runScrapeBtn) runScrapeBtn.onclick = () => { if (!state.importRunning) runNHSScrape(); };
  const runScrapeAllBtn = $('#run-scrape-all-btn');
  if (runScrapeAllBtn) runScrapeAllBtn.onclick = () => { if (!state.importRunning && !state.importSweepRunning) runNHSScrapeAll(); };
  const runScrapeEveryBtn = $('#run-scrape-every-btn');
  if (runScrapeEveryBtn) runScrapeEveryBtn.onclick = () => { if (!state.importRunning && !state.importSweepRunning) runNHSScrapeEverything(); };
  const runScotBtn = $('#run-scot-btn');
  if (runScotBtn) runScotBtn.onclick = () => { if (!state.scotRunning && !state.scotSweepRunning) runScotlandScrape(); };
  const runScotAllBtn = $('#run-scot-all-btn');
  if (runScotAllBtn) runScotAllBtn.onclick = () => { if (!state.scotRunning && !state.scotSweepRunning) runScotlandScrapeAll(); };
  const scotSpecialtySel = $('#scot-specialty');
  if (scotSpecialtySel) scotSpecialtySel.onchange = (e) => { state.scotSpecialty = e.target.value; };
  // Agency CSV upload
  const runEnrichBtn = $('#run-enrich-btn');
  if (runEnrichBtn) runEnrichBtn.onclick = () => { if (!state.enrichRunning) runEnrichment(); };
  const enrichLimit = $('#enrich-limit');
  // no state needed for enrich limit — read directly on click

  const agencyCsvSourcePicker = $('#agency-csv-source');
  if (agencyCsvSourcePicker) agencyCsvSourcePicker.onchange = (e) => {
    state.agencyCsvSource = e.target.value;
    state.agencyCsvPreview = null;
    state.agencyResult = null;
  };

  const agencyCsvInput = $('#agency-csv-input');
  if (agencyCsvInput) {
    agencyCsvInput.onchange = (e) => {
      const file = e.target.files[0];
      if (!file) return;
      const reader = new FileReader();
      reader.onload = (ev) => {
        state.agencyResult = null;
        state.agencyCsvPreview = null;
        previewAgencyCSV(ev.target.result);
      };
      reader.readAsText(file);
    };
  }
  const agencyUploadBtn = $('#agency-upload-btn');
  if (agencyUploadBtn) agencyUploadBtn.onclick = () => { if (!state.agencyUploading) runAgencyCSVUpload(); };

  const runCareHomeBtn = $('#run-carehome-btn');
  if (runCareHomeBtn) runCareHomeBtn.onclick = function() { if (!state.careHomeRunning) runCareHomeScrape(); };
  const runTheatreBtn = $('#run-theatre-btn');
  if (runTheatreBtn) runTheatreBtn.onclick = () => { if (!state.theatreRunning) runTheatreScrape(); };

  // Batch action buttons
  document.querySelectorAll('[data-bulk]').forEach(btn => {
    btn.onclick = async () => {
      const action = btn.dataset.bulk;
      if (action === 'clear') { state.selected = new Set(); render(); return; }
      if (action.startsWith('stage-')) { await bulkAction(action); return; }
      if (action === 'move-to-live') { await bulkAction('move-to-live'); return; }
      if (action === 'send-compose') {
        state.composeSelectedIds = [...state.selected];
        state.composeBrevoResult = null;
        state.composeBrevoSending = false;
        state.view = 'compose';
        state.composePreviewCounts = null;
        render();
        return;
      }
      if (action === 'delete') {
        state.modal = {
          type: 'confirm',
          title: `Delete ${state.selected.size} contact${state.selected.size !== 1 ? 's' : ''}?`,
          message: 'This cannot be undone.',
          confirmText: 'Delete', danger: true,
          onConfirm: () => bulkAction('delete')
        };
        renderModal(); return;
      }
      if (action === 'unsubscribe') {
        state.modal = {
          type: 'confirm',
          title: `Unsubscribe ${state.selected.size} contact${state.selected.size !== 1 ? 's' : ''}?`,
          message: 'They will be moved to the Unsubscribes list.',
          confirmText: 'Unsubscribe', danger: false,
          onConfirm: () => bulkAction('unsubscribe')
        };
        renderModal(); return;
      }
      await bulkAction(action);
    };
  });

  const search = $('#search-input');
  if (search) {
    let timer;
    search.oninput = (e) => {
      clearTimeout(timer);
      state.search = e.target.value;
      timer = setTimeout(async () => { state.page = 1; await loadContactsPage(); render(); search.focus(); }, 400);
    };
  }

  const regionFilter = $('#region-filter');
  if (regionFilter) regionFilter.onchange = async (e) => { state.regionFilter = e.target.value; state.page = 1; await loadContactsPage(); render(); };
  const countryFilter = $('#country-filter');
  if (countryFilter) countryFilter.onchange = async (e) => { state.countryFilter = e.target.value; state.page = 1; await loadContactsPage(); render(); };

  document.querySelectorAll('[data-sort]').forEach(el => {
    el.onclick = async () => {
      const key = el.dataset.sort;
      if (state.sortKey === key) state.sortDir = state.sortDir === 'asc' ? 'desc' : 'asc';
      else { state.sortKey = key; state.sortDir = 'asc'; }
      await loadContactsPage();
      render();
    };
  });

  document.querySelectorAll('.page-btn').forEach(b => {
    b.onclick = async () => {
      state.page = parseInt(b.dataset.page);
      await loadContactsPage();
      render();
    };
  });

  document.querySelectorAll('[data-action]').forEach(el => {
    el.onclick = () => handleAction(el.dataset.action, el.dataset.id);
  });

  const addBtn = $('#add-contact-btn');
  if (addBtn) addBtn.onclick = () => {
    state.modal = { type: 'add-contact', contact: {
      title: '', first_name: '', last_name: '', job_title: 'Practice Manager',
      org: '', email: '', phone: '', add1: '', add2: '', town: '', postcode: '',
      region: '', country: 'England', notes: ''
    }};
    renderModal();
  };

  const addTplBtn = $('#add-template-btn');
  if (addTplBtn) addTplBtn.onclick = () => {
    state.modal = { type: 'add-template', template: { name: '', subject: '', body: '' } };
    renderModal();
  };

  // Compose binders
  const composeTemplate = $('#compose-template');
  if (composeTemplate) composeTemplate.onchange = (e) => { state.composeTemplateId = e.target.value; render(); };
  const composeList = $('#compose-list');
  const composeSource = $('#compose-source');
  if (composeSource) composeSource.onchange = (e) => { state.composeSourceFilter = e.target.value; state.composeSpecialtyFilter = 'all'; state.composePreviewCounts = null; render(); };
  const composeSpecialty = $('#compose-specialty');
  if (composeSpecialty) composeSpecialty.onchange = (e) => { state.composeSpecialtyFilter = e.target.value; state.composePreviewCounts = null; render(); };
  if (composeList) composeList.onchange = (e) => { state.composeListFilter = e.target.value; state.composePreviewCounts = null; render(); };
  const composeUncontactedCb = $('#compose-uncontacted');
  if (composeUncontactedCb) composeUncontactedCb.onchange = (e) => { state.composeUncontactedOnly = e.target.checked; state.composePreviewCounts = null; render(); };
  const composeRegion = $('#compose-region');
  if (composeRegion) composeRegion.onchange = (e) => { state.composeRegionFilter = e.target.value; state.composePreviewCounts = null; render(); };
  const composeCountry = $('#compose-country');
  if (composeCountry) composeCountry.onchange = (e) => { state.composeCountryFilter = e.target.value; state.composePreviewCounts = null; render(); };
  const composeTown = $('#compose-town');
  if (composeTown) composeTown.oninput = (e) => { state.composeTownFilter = e.target.value; state.composePreviewCounts = null; };
  const composeBatch = $('#compose-batch');
  if (composeBatch) composeBatch.onchange = (e) => { state.composeBatchSize = parseInt(e.target.value) || 250; render(); };
  const refreshPreview = $('#refresh-preview');
  if (refreshPreview) refreshPreview.onclick = async () => {
    state.composePreviewCounts = await previewComposeCounts();
    render();
  };

  const startOneByOne = $('#start-one-by-one');
  if (startOneByOne) startOneByOne.onclick = async () => {
    state.composeQueue = await buildComposeQueueFromDb();
    if (state.composeQueue.length === 0) { toast('No matching contacts to send to'); return; }
    state.composeBatchId = todayStr() + '_' + uid();
    state.composeIndex = 0;
    state.composeMode = 'one-by-one';
    render();
  };

  const startCsv = $('#start-csv');
  if (startCsv) startCsv.onclick = async () => {
    state.composeQueue = await buildComposeQueueFromDb();
    if (state.composeQueue.length === 0) { toast('No matching contacts to send to'); return; }
    state.composeBatchId = todayStr() + '_' + uid();
    state.composeMode = 'csv';
    render();
  };

  const exitOneByOne = $('#exit-one-by-one');
  if (exitOneByOne) exitOneByOne.onclick = exitComposeMode;
  const exitCsv = $('#exit-csv');
  if (exitCsv) exitCsv.onclick = exitComposeMode;
  const composeFinish = $('#compose-finish');
  if (composeFinish) composeFinish.onclick = exitComposeMode;

  const downloadCsvBtn = $('#download-csv');
  if (downloadCsvBtn) downloadCsvBtn.onclick = downloadCsvForMerge;
  const copyMergeBody = $('#copy-merge-body');
  if (copyMergeBody) copyMergeBody.onclick = () => {
    const t = state.templates.find(x => x.id === state.composeTemplateId);
    copyToClipboard(convertTokensToMergeFields(t.body), 'Email body copied — paste into Word');
  };
  const markBatchSent = $('#mark-batch-sent');
  if (markBatchSent) markBatchSent.onclick = async () => {
    await logBatchSends(state.composeQueue.map(c => c.id), state.composeTemplateId, state.composeBatchId);
    toast(`Logged ${state.composeQueue.length} sends`);
    exitComposeMode();
  };

  // Settings binders
  const exportCsvAll = $('#export-csv-all');
  if (exportCsvAll) exportCsvAll.onclick = exportAllAsCsv;

  // Sign out buttons (both in header and settings)
  // Sender details bindings
  var snd_name = $('#sender-name-input'); if (snd_name) snd_name.oninput = function(e) { state.senderName = e.target.value; };
  var snd_email = $('#sender-email-input'); if (snd_email) snd_email.oninput = function(e) { state.senderEmail = e.target.value; };
  var snd_save = $('#save-sender-btn'); if (snd_save) snd_save.onclick = function() { if (!state.senderSaving) saveSenderDetails(); };
    var unsubAddBtn = document.getElementById('unsub-org-add');
  if (unsubAddBtn) unsubAddBtn.onclick = function(){ if (!state.unsubOrgAdding) addAutoUnsubOrg(); };
  var unsubOrgInputEl = document.getElementById('unsub-org-input');
  if (unsubOrgInputEl) unsubOrgInputEl.oninput = function(e){ state.unsubOrgInput = e.target.value; };
  document.querySelectorAll('[data-unsub-del]').forEach(function(b){ b.onclick = function(){ removeAutoUnsubOrg(b.getAttribute('data-unsub-del')); }; });
  document.querySelectorAll('[data-kw-del]').forEach(function(btn){
    btn.onclick = async function(){
      try { await sb.from('specialty_title_keywords').delete().eq('id', parseInt(btn.dataset.kwDel, 10)); }
      catch(e){ alert('Could not remove keyword: ' + e.message); return; }
      await loadSpecKeywords();
    };
  });
  document.querySelectorAll('[data-kw-add]').forEach(function(btn){
    btn.onclick = async function(){
      var spec = btn.dataset.kwAdd;
      var inp = document.getElementById('kw-add-input-' + spec);
      var val = (inp && inp.value) ? inp.value.trim().toLowerCase() : '';
      if (!val) return;
      try { await sb.from('specialty_title_keywords').insert({ specialty: spec, keyword: val }); }
      catch(e){ alert('Could not add keyword: ' + e.message); return; }
      await loadSpecKeywords();
    };
  });
  document.querySelectorAll('.kw-add-input').forEach(function(inp){
    inp.onkeydown = function(e){ if (e.key === 'Enter') { var b = document.querySelector('[data-kw-add="' + inp.id.replace('kw-add-input-','') + '"]'); if (b) b.onclick(); } };
  });
  // Team invite bindings
  var inv_name = $('#invite-name'); if (inv_name) inv_name.oninput = function(e) { state.inviteName = e.target.value; };
  var inv_email = $('#invite-email'); if (inv_email) inv_email.oninput = function(e) { state.inviteEmail = e.target.value; };
  var inv_sn = $('#invite-sender-name'); if (inv_sn) inv_sn.oninput = function(e) { state.inviteSenderName = e.target.value; };
  var inv_se = $('#invite-sender-email'); if (inv_se) inv_se.oninput = function(e) { state.inviteSenderEmail = e.target.value; };
  var inv_btn = $('#send-invite-btn'); if (inv_btn) inv_btn.onclick = function() { if (state.inviteEmail) sendInvite(); };
  document.querySelectorAll('.invite-source-cb').forEach(function(cb) {
    cb.onchange = function() {
      if (cb.checked) { if (state.inviteSources.indexOf(cb.value) < 0) state.inviteSources.push(cb.value); }
      else { state.inviteSources = state.inviteSources.filter(function(s) { return s !== cb.value; }); }
    };
  });
  document.querySelectorAll('[data-delete-user]').forEach(function(btn) {
    btn.onclick = async function() {
      if (!confirm('Remove ' + btn.dataset.userEmail + ' from the team?')) return;
      var sess2 = (await sb.auth.getSession()).data.session;
      await fetch('https://udttpnaenmyxviuiwxqw.supabase.co/functions/v1/user-manager', {
        method: 'POST', headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + sess2.access_token },
        body: JSON.stringify({ action: 'delete', target_user_id: btn.dataset.deleteUser }),
      });
      await loadTeamUsers();
    };
  });
  document.querySelectorAll('[data-reset-user]').forEach(function(btn) {
    btn.onclick = async function() {
      var pw = prompt('Set a new password for ' + btn.dataset.userEmail + ' (min 8 characters). Give it to them so they can log in:');
      if (pw === null) return;
      pw = pw.trim();
      if (pw.length < 8) { alert('Password must be at least 8 characters.'); return; }
      var sess2 = (await sb.auth.getSession()).data.session;
      var res = await fetch('https://udttpnaenmyxviuiwxqw.supabase.co/functions/v1/user-manager', {
        method: 'POST', headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + sess2.access_token },
        body: JSON.stringify({ action: 'set_password', target_user_id: btn.dataset.resetUser, new_password: pw }),
      });
      var d = await res.json().catch(function() { return {}; });
      if (res.ok && d.success) { toast('Password updated for ' + btn.dataset.userEmail); }
      else { alert('Could not update password: ' + (d.error || ('HTTP ' + res.status))); }
    };
  });
  // M365 responses bindings
  var m365_btn = $('#sync-m365-btn'); if (m365_btn) m365_btn.onclick = function() { if (!state.m365Syncing) syncM365(); };
  var m365_days = $('#m365-days'); if (m365_days) m365_days.onchange = function(e) { state.m365DaysBack = parseInt(e.target.value); };
  var m365_save = $('#save-m365-client-id'); if (m365_save) m365_save.onclick = function() {
    var inp = $('#m365-client-id-input');
    if (inp && inp.value) { state.m365ClientId = inp.value.trim(); state.m365ShowClientIdInput = false; syncM365(); }
  };
  document.querySelectorAll('.reply-read-btn').forEach(function(btn) {
    btn.onclick = function() { markReplyRead(btn.dataset.replyId); };
  // Reply expand/collapse and add-to-DB
  document.querySelectorAll('[data-expand-reply]').forEach(function(el) {
    el.onclick = function(e) {
      e.stopPropagation();
      var id = this.dataset.expandReply;
      state.expandedReplyId = (state.expandedReplyId === id) ? null : id;
      // Mark as read when expanding
      var reply = state.responsesData && state.responsesData.replies && state.responsesData.replies.find(function(r){return r.id===id;});
      if (reply && !reply.read) markReplyRead(id);
      else render();
    };
  });
  document.querySelectorAll('[data-add-reply]').forEach(function(el) {
    el.onclick = function(e) {
      e.stopPropagation();
      addContactFromReply(this.dataset.addReply);
    };
  });
  });
    document.querySelectorAll('#sign-out-btn, #sign-out-btn-settings').forEach(b => {
    b.onclick = signOut;
  });
}

async function exitComposeMode() {
  state.composeMode = null;
  state.composeQueue = null;
  state.composeBatchId = null;
  // Refresh counts in case statuses changed during the send
  await loadStatusCounts();
  render();
}

function bindModalEvents() {
  const overlay = document.querySelector('.modal-overlay');
  if (!overlay) return;
  const closeModal = () => { state.modal = null; renderModal(); };

  overlay.addEventListener('click', (e) => { if (e.target === overlay) closeModal(); });
  const cancelBtn = overlay.querySelector('#m-cancel');
  if (cancelBtn) cancelBtn.addEventListener('click', closeModal);

  const saveBtn = overlay.querySelector('#m-save');
  if (saveBtn) saveBtn.addEventListener('click', async () => {
    if (state.modal.type === 'edit-contact' || state.modal.type === 'add-contact') {
      const c = state.modal.contact;
      const payload = {
        title: overlay.querySelector('#m-title').value.trim() || null,
        first_name: overlay.querySelector('#m-firstName').value.trim() || null,
        last_name: overlay.querySelector('#m-lastName').value.trim() || null,
        job_title: overlay.querySelector('#m-jobTitle').value.trim() || null,
        org: overlay.querySelector('#m-org').value.trim(),
        email: overlay.querySelector('#m-email').value.trim().toLowerCase(),
        phone: overlay.querySelector('#m-phone').value.trim() || null,
        town: overlay.querySelector('#m-town').value.trim() || null,
        postcode: overlay.querySelector('#m-postcode').value.trim() || null,
        region: overlay.querySelector('#m-region').value.trim() || null,
        country: overlay.querySelector('#m-country').value.trim() || null,
        notes: combineSourceAndNotes(
          overlay.querySelector('#m-source').value,
          overlay.querySelector('#m-notes').value
        )
      };
      if (!payload.first_name || !payload.org || !payload.email) {
        toast('First Name, Org, and Email are required', 'error');
        return;
      }
      saveBtn.disabled = true;
      let result;
      if (state.modal.type === 'add-contact') {
        payload.status = state.subTab;
        result = await addContact(payload);
      } else {
        const statusEl = overlay.querySelector('#m-status');
        if (statusEl) payload.status = statusEl.value;
        result = await updateContactById(c.id, payload);
      }
      saveBtn.disabled = false;
      if (result.error) {
        toast('Save failed: ' + result.error.message, 'error');
        return;
      }
      closeModal();
      await Promise.all([loadStatusCounts(), loadContactsPage()]);
      render();
      toast('Saved');
    } else if (state.modal.type === 'edit-template' || state.modal.type === 'add-template') {
      const t = state.modal.template;
      const payload = {
        name: overlay.querySelector('#t-name').value.trim(),
        subject: overlay.querySelector('#t-subject').value.trim(),
        body: overlay.querySelector('#t-body').value
      };
      if (!payload.name || !payload.subject || !payload.body) {
        toast('All fields required', 'error');
        return;
      }
      saveBtn.disabled = true;
      const result = state.modal.type === 'add-template' ? await addTemplate(payload) : await updateTemplateById(t.id, payload);
      saveBtn.disabled = false;
      if (result.error) {
        toast('Save failed: ' + result.error.message, 'error');
        return;
      }
      closeModal();
      await loadTemplates();
      render();
      toast('Template saved');
    }
  });

  const confirmBtn = overlay.querySelector('#m-confirm');
  if (confirmBtn) confirmBtn.addEventListener('click', async () => {
    if (state.modal.onConfirm) await state.modal.onConfirm();
    closeModal();
  });

  overlay.querySelectorAll('.token-insert').forEach(el => {
    el.addEventListener('click', () => {
      const token = el.dataset.token;
      const body = overlay.querySelector('#t-body');
      const subj = overlay.querySelector('#t-subject');
      const target = (document.activeElement === subj) ? subj : body;
      if (target) {
        const start = target.selectionStart || target.value.length;
        target.value = target.value.slice(0, start) + token + target.value.slice(target.selectionEnd || target.value.length);
        target.focus();
        target.setSelectionRange(start + token.length, start + token.length);
      }
    });
  });
}

// ============================================================================
//  ACTIONS (Database row buttons, send-mode buttons)
// ============================================================================

async function bulkAction(action) {
  const ids = [...state.selected];
  if (!ids.length) return;

  if (action === 'unsubscribe') {
    const { error } = await sb.from('contacts').update({ status: 'unsubscribed' }).in('id', ids);
    if (error) return toast('Error: ' + error.message);
    toast(`${ids.length} contact${ids.length !== 1 ? 's' : ''} unsubscribed`);
  } else if (action === 'restore') {
    const { error } = await sb.from('contacts').update({ status: 'lead' }).in('id', ids);
    if (error) return toast('Error: ' + error.message);
    toast(`${ids.length} restored to Leads`);
  } else if (action === 'move-to-live') {
    const { error } = await sb.from('contacts').update({ status: 'live', stage: 'live' }).in('id', ids);
    if (error) return toast('Error: ' + error.message);
    toast(`${ids.length} contact${ids.length !== 1 ? 's' : ''} marked as Live`);
  } else if (action === 'stage-responded') {
    const { error } = await sb.from('contacts').update({ stage: 'responded' }).in('id', ids);
    if (error) return toast('Error: ' + error.message);
    toast(`${ids.length} marked as Responded`);
  } else if (action === 'stage-meeting') {
    const { error } = await sb.from('contacts').update({ stage: 'meeting' }).in('id', ids);
    if (error) return toast('Error: ' + error.message);
    toast(`${ids.length} marked as Meeting`);
  } else if (action === 'delete') {
    const { error } = await sb.from('contacts').delete().in('id', ids);
    if (error) return toast('Error: ' + error.message);
    toast(`${ids.length} contact${ids.length !== 1 ? 's' : ''} deleted`);
  }

  state.selected = new Set();
  await Promise.all([loadStatusCounts(), loadSourceCounts(), loadContactsPage()]);
  render();
}

async function handleAction(action, id) {
  if (action === 'edit') {
    const c = state.currentRows.find(x => x.id === id);
    if (c) { state.modal = { type: 'edit-contact', contact: { ...c } }; renderModal(); }
  }

  else if (action === 'delete') {
    state.modal = {
      type: 'confirm', title: 'Delete contact?', message: 'This cannot be undone. Their email send history will also be deleted.',
      confirmText: 'Delete', danger: true,
      onConfirm: async () => {
        const err = await deleteContactById(id);
        if (err) { toast('Delete failed: ' + err.message, 'error'); return; }
        await Promise.all([loadStatusCounts(), loadContactsPage()]);
        render();
        toast('Deleted');
      }
    };
    renderModal();
  }

  else if (action === 'move-lead' || action === 'move-live' || action === 'move-unsub') {
    const newStatus = action === 'move-lead' ? 'lead' : action === 'move-live' ? 'live' : 'unsubscribed';
    const { error } = await setContactStatus(id, newStatus);
    if (error) { toast('Move failed: ' + error.message, 'error'); return; }
    await Promise.all([loadStatusCounts(), loadContactsPage()]);
    render();
    toast(`Moved to ${STATUS_LABEL[newStatus]}`);
  }

  else if (action === 'edit-template') {
    const t = state.templates.find(x => x.id === id);
    if (t) { state.modal = { type: 'edit-template', template: { ...t } }; renderModal(); }
  }

  else if (action === 'duplicate-template') {
    const t = state.templates.find(x => x.id === id);
    if (!t) return;
    const result = await addTemplate({ name: t.name + ' (copy)', subject: t.subject, body: t.body });
    if (result.error) { toast('Duplicate failed: ' + result.error.message, 'error'); return; }
    await loadTemplates();
    render();
  }

  else if (action === 'delete-template') {
    state.modal = {
      type: 'confirm', title: 'Delete template?', message: 'This cannot be undone.',
      confirmText: 'Delete', danger: true,
      onConfirm: async () => {
        const err = await deleteTemplateById(id);
        if (err) { toast('Delete failed: ' + err.message, 'error'); return; }
        await loadTemplates();
        render();
      }
    };
    renderModal();
  }

  // ----- One-by-one mode buttons -----
  else if (action === 'copy-subject') {
    const tpl = state.templates.find(t => t.id === state.composeTemplateId);
    copyToClipboard(personalize(tpl.subject, state.composeQueue[state.composeIndex]), 'Subject copied');
  }
  else if (action === 'copy-email') {
    copyToClipboard(state.composeQueue[state.composeIndex].email, 'Email address copied');
  }
  else if (action === 'copy-body') {
    const tpl = state.templates.find(t => t.id === state.composeTemplateId);
    copyToClipboard(personalize(tpl.body, state.composeQueue[state.composeIndex]), 'Email body copied — paste into Outlook');
  }
  else if (action === 'mark-sent-next') {
    const c = state.composeQueue[state.composeIndex];
    await logEmailSend(c.id, state.composeTemplateId, state.composeBatchId, 'sent', null);
    state.composeIndex++;
    render();
  }
  else if (action === 'skip-next') {
    state.composeIndex++;
    render();
  }
  else if (action === 'mark-bounced') {
    const c = state.composeQueue[state.composeIndex];
    await logEmailSend(c.id, state.composeTemplateId, state.composeBatchId, 'bounced', 'Bounced during send');
    await updateContactById(c.id, { notes: (c.notes ? c.notes + ' | ' : '') + 'BOUNCED ' + todayStr() });
    toast('Marked as bounced');
    state.composeIndex++;
    render();
  }
  else if (action === 'mark-unsub') {
    const c = state.composeQueue[state.composeIndex];
    await setContactStatus(c.id, 'unsubscribed');
    await logEmailSend(c.id, state.composeTemplateId, state.composeBatchId, 'sent', 'Unsubscribed during send');
    toast('Moved to Unsubscribes');
    state.composeIndex++;
    render();
  }
  else if (action === 'copy-merge-subject') {
    const t = state.templates.find(x => x.id === state.composeTemplateId);
    copyToClipboard(convertTokensToMergeFields(t.subject), 'Subject copied');
  }
}

// ============================================================================
//  CSV EXPORT
// ============================================================================

function downloadCsvForMerge() {
  const headers = ['Title', 'FirstName', 'LastName', 'JobTitle', 'Org', 'Email', 'Phone', 'Town', 'Postcode', 'Region', 'Country'];
  const rows = state.composeQueue.map(c => [c.title, c.first_name, c.last_name, c.job_title, c.org, c.email, c.phone, c.town, c.postcode, c.region, c.country]);
  const csv = [headers.map(csvEscape).join(',')].concat(rows.map(r => r.map(csvEscape).join(','))).join('\n');
  downloadFile(csv, `mailshot_${todayStr()}.csv`, 'text/csv');
  toast('CSV downloaded - ready for Word Mail Merge');
}

async function exportAllAsCsv() {
  toast('Exporting all contacts — this may take a few seconds...');
  // Page through the database in batches
  const all = [];
  const chunkSize = 1000;
  let from = 0;
  while (true) {
    const { data, error } = await sb.from('contacts_with_last_email')
      .select('*').range(from, from + chunkSize - 1).order('status', { ascending: true });
    if (error) { toast('Export failed: ' + error.message, 'error'); return; }
    if (!data || data.length === 0) break;
    all.push(...data);
    if (data.length < chunkSize) break;
    from += chunkSize;
  }

  const headers = ['Status', 'Title', 'First Name', 'Last Name', 'Job Title', 'Org', 'Email', 'Phone', 'Town', 'Postcode', 'Region', 'Country', 'Notes', 'Last Emailed'];
  const rows = all.map(c => [c.status, c.title, c.first_name, c.last_name, c.job_title, c.org, c.email, c.phone, c.town, c.postcode, c.region, c.country, c.notes, c.last_emailed_at ? c.last_emailed_at.slice(0,10) : '']);
  const csv = [headers.map(csvEscape).join(',')].concat(rows.map(r => r.map(csvEscape).join(','))).join('\n');
  downloadFile(csv, `urgent_nursing_contacts_${todayStr()}.csv`, 'text/csv');
  toast(`Exported ${all.length} contacts`);
}

// ============================================================================
//  INIT
// ============================================================================

(async function init() {
  // Sanity check config
  if (window.CONFIG.SUPABASE_URL.includes('YOUR_PROJECT') || window.CONFIG.SUPABASE_ANON_KEY.includes('YOUR_ANON')) {
    $('#app').innerHTML = `
      <div style="padding:40px;max-width:600px;margin:40px auto;background:#FEE2E2;border:1px solid #DC2626;border-radius:8px;color:#7F1D1D;">
        <h2>Configuration needed</h2>
        <p>Edit <code>js/config.js</code> and paste in your Supabase Project URL and anon public key.</p>
        <p>Find them at: Supabase Dashboard → Project Settings → API.</p>
      </div>`;
    return;
  }

  await initAuth();
  if (state.user) {
    await bootApp();
  } else {
    render();
  }
})();
  // Smart CSV upload cards — Children's Homes, Care Homes, Theatres
  ['children_homes', 'care_home', 'private_theatre'].forEach(function(src) {
    var inp = document.getElementById('csv-input-' + src);
    if (inp) {
      inp.onchange = async function() {
        var file = this.files && this.files[0];
        if (!file) return;
        var text = await file.text();
        state['csvText_' + src] = text;
        state['csvPreview_' + src] = null;
        state['csvResult_' + src] = null;
        try {
          var sess = (await sb.auth.getSession()).data.session;
          var res = await fetch('https://udttpnaenmyxviuiwxqw.supabase.co/functions/v1/csv-upload', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + sess.access_token },
            body: JSON.stringify({ csv: text, source: src, preview: true }),
          });
          state['csvPreview_' + src] = await res.json();
        } catch(e) { console.error('Preview error', e); }
        render();
      };
    }
    var btn = document.getElementById('csv-upload-btn-' + src);
    if (btn) {
      btn.onclick = async function() {
        var text = state['csvText_' + src];
        if (!text) return;
        state['csvUploading_' + src] = true;
        state['csvResult_' + src] = null;
        render();
        try {
          var sess = (await sb.auth.getSession()).data.session;
          var res = await fetch('https://udttpnaenmyxviuiwxqw.supabase.co/functions/v1/csv-upload', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + sess.access_token },
            body: JSON.stringify({ csv: text, source: src }),
          });
          state['csvResult_' + src] = await res.json();
          if (state['csvResult_' + src] && state['csvResult_' + src].success) {
            await Promise.all([loadStatusCounts(), loadSourceCounts()]);
            toast('\u2713 ' + (state['csvResult_' + src].inserted || 0) + ' contacts added');
          }
        } catch(e) { state['csvResult_' + src] = { success: false, error: e.message }; }
        state['csvUploading_' + src] = false;
        render();
      };
    }
  });
