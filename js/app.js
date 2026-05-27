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
  // User profile
  userProfile: null,
  senderEmail: '',
  senderName: '',
  senderSaving: false,
  senderSaved: false,
  // Team management
  teamUsers: [],
  teamLoading: false,
  inviteEmail: '',
  inviteName: '',
  inviteSources: [],
  inviteResult: null,
  inviteSenderEmail: '',
  inviteSenderName: '',
  // Import / scraper
  importSpecialty: 'physiotherapy',
  importRegion: '',
  importBand: '7',
  importLimit: 20,
  importRunning: false,
  importResult: null,
  careHomeRunning: false,
  careHomeResult: null,
  pharmacyRunning: false,
  pharmacyResult: null,
  agencyCsvText: null,
  agencyCsvPreview: null,
  agencyCsvSource: 'gp_surgery',
  enrichRunning: false,
  enrichResult: null,
  responsesLoading: false,
  responsesData: null,
  m365Syncing: false,
  m365SyncResult: null,
  m365ShowClientIdInput: false,
  m365ClientId: localStorage?.getItem?.('m365ClientId') || '',
  m365DaysBack: 30,
  agencyUploading: false,
  agencyResult: null,
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
        <img src="/dw-logo.jpg" alt="Day Webster Group" />
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
    gp_surgery:      null, // special case
    children_homes:  'Ofsted Register',
    agency:          'Source: Agency Outreach',
    pharmacy:        'Source: Pharmacy Outreach',
    ahp:             'Source: NHS Jobs AHP',
    private_theatre: 'Source: Private Theatre',
    care_home:       'Source: Care Home',
    care_home:       'Source: Care Home',
    bms:             'Source: BMS Outreach',
    sterile:         'Source: Sterile Services',
    nhs_staffbank:   'Source: NHS Staff Bank',
    ahp:             'Source: NHS Jobs AHP',
    camhs:           'Source: CAMHS',
  };

  function applyFilter(q) {
    if (sf === 'gp_surgery') {
      return q
        .not('notes', 'ilike', '%Ofsted Register%')
        .not('notes', 'ilike', '%Source: Agency%')
        .not('notes', 'ilike', '%Source: Pharmacy%')
        .not('notes', 'ilike', '%Source: BMS%')
        .not('notes', 'ilike', '%Source: Sterile%')
        .not('notes', 'ilike', '%Source: Private Theatre%')
        .not('notes', 'ilike', '%Source: NHS Staff Bank%')
        .not('notes', 'ilike', '%Source: CAMHS%')
        .not('notes', 'ilike', '%Source: NHS Jobs AHP%');
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
  state.regions = Array.from(new Set((rData || []).map(r => r.region))).sort();
  state.countries = Array.from(new Set((cData || []).map(r => r.country))).sort();
}


async function loadSourceCounts() {
  const [allRes, chRes, gpRes, ahpRes, agencyRes, pharmRes, theatreRes, careHomeRes] = await Promise.all([
    sb.from('contacts').select('id', { count: 'exact', head: true }),
    sb.from('contacts').select('id', { count: 'exact', head: true })
      .ilike('notes', '%Ofsted Register%'),
    sb.from('contacts').select('id', { count: 'exact', head: true }).ilike('notes', '%Source: NHS Jobs AHP%'),
    sb.from('contacts').select('id', { count: 'exact', head: true }).ilike('notes', '%Source: Agency Outreach%'),
    sb.from('contacts').select('id', { count: 'exact', head: true }).ilike('notes', '%Source: Pharmacy Outreach%'),
    sb.from('contacts').select('id', { count: 'exact', head: true }).ilike('notes', '%Source: Private Theatre%'),
    sb.from('contacts').select('id', { count: 'exact', head: true }).ilike('notes', '%Source: Care Home%'),
    sb.from('contacts').select('id', { count: 'exact', head: true })
      .not('notes', 'ilike', '%Ofsted Register%')
      .not('notes', 'ilike', '%Source: Agency%')
      .not('notes', 'ilike', '%Source: Pharmacy%')
      .not('notes', 'ilike', '%Source: BMS%')
      .not('notes', 'ilike', '%Source: Sterile%')
      .not('notes', 'ilike', '%Source: Private Theatre%')
      .not('notes', 'ilike', '%Source: NHS Staff Bank%')
      .not('notes', 'ilike', '%Source: NHS Theatre%')
      .not('notes', 'ilike', '%Source: CAMHS%'),
  ]);
  state.sourceCounts = {
    all:            allRes.count    || 0,
    gp_surgery:     gpRes.count     || 0,
    children_homes: chRes.count     || 0,
    ahp:            ahpRes.count    || 0,
    agency:         agencyRes.count || 0,
    pharmacy:       pharmRes.count  || 0,
    private_theatre: theatreRes.count || 0,
  };
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
      .not('notes', 'ilike', '%Source: Agency Outreach%')
      .not('notes', 'ilike', '%Source: Pharmacy Outreach%')
      .not('notes', 'ilike', '%Source: BMS Outreach%')
      .not('notes', 'ilike', '%Source: Sterile Services%')
      .not('notes', 'ilike', '%Source: Private Theatre%')
      .not('notes', 'ilike', '%Source: NHS Staff Bank%')
      .not('notes', 'ilike', '%Source: NHS Theatre%')
      .not('notes', 'ilike', '%Source: CAMHS%')
      .not('notes', 'ilike', '%Source: NHS Jobs AHP%');
  } else if (sf === 'ahp') {
    query = query.ilike('notes', '%Source: NHS Jobs AHP%');
    if (state.ahpSpecialtyFilter && state.ahpSpecialtyFilter !== 'all') {
      query = query.ilike('notes', `%Specialty: ${state.ahpSpecialtyFilter}%`);
    }
  } else if (sf === 'agency') {
    query = query.ilike('notes', '%Source: Agency Outreach%');
  } else if (sf === 'pharmacy') {
    query = query.ilike('notes', '%Source: Pharmacy Outreach%');
  } else if (sf === 'private_theatre') {
    query = query.ilike('notes', '%Source: Private Theatre%');
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
      .not('notes', 'ilike', '%Source: Private Theatre%')
      .not('notes', 'ilike', '%Source: NHS Staff Bank%')
      .not('notes', 'ilike', '%Source: NHS Theatre%')
      .not('notes', 'ilike', '%Source: CAMHS%')
      .not('notes', 'ilike', '%Source: NHS Jobs AHP%');
  }
  const SOURCE_TAGS = {
    children_homes:  'Ofsted Register',
    agency:          'Source: Agency Outreach',
    pharmacy:        'Source: Pharmacy Outreach',
    ahp:             'Source: NHS Jobs AHP',
    private_theatre: 'Source: Private Theatre',
    care_home:       'Source: Care Home',
    care_home:       'Source: Care Home',
    bms:             'Source: BMS Outreach',
    sterile:         'Source: Sterile Services',
    nhs_staffbank:   'Source: NHS Staff Bank',
    ahp:             'Source: NHS Jobs AHP',
    camhs:           'Source: CAMHS',
  };
  const tag = SOURCE_TAGS[source];
  if (tag) return q.ilike('notes', `%${tag}%`);
  return q; // 'all' — no filter
}

async function buildComposeQueueFromDb() {
  let query = sb.from('contacts').select('*').eq('status', state.composeListFilter);
  query = applyComposeSourceFilter(query, state.composeSourceFilter);
  if (state.composeRegionFilter) query = query.eq('region', state.composeRegionFilter);
  if (state.composeCountryFilter) query = query.eq('country', state.composeCountryFilter);
  if (state.composeTownFilter) query = query.ilike('town', `%${state.composeTownFilter}%`);

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
  let q = sb.from('contacts').select('*', { count: 'exact', head: true })
    .eq('status', state.composeListFilter);
  q = applyComposeSourceFilter(q, state.composeSourceFilter);
  if (state.composeRegionFilter) q = q.eq('region', state.composeRegionFilter);
  if (state.composeCountryFilter) q = q.eq('country', state.composeCountryFilter);
  if (state.composeTownFilter) q = q.ilike('town', `%${state.composeTownFilter}%`);
  const { count } = await q;
  return { matching: count || 0 };
}

// ============================================================================
//  RENDER — top-level dispatch
// ============================================================================

async function bootApp() {
  $('#app').innerHTML = '<div style="padding:40px;text-align:center;color:#6B7280;">Loading data...</div>';
  // Load user profile to determine access level
  const { data: { session: bootSession } } = await sb.auth.getSession();
  if (bootSession) {
    const profileRes = await fetch(`${SB_URL}/functions/v1/user-manager`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + bootSession.access_token },
      body: JSON.stringify({ action: 'me' }),
    });
    const profileData = await profileRes.json();
    state.userProfile = profileData.profile || null;
    if (profileData.profile) {
      state.senderEmail = profileData.profile.sender_email || '';
      state.senderName  = profileData.profile.sender_name  || '';
    }
  }
  await Promise.all([loadStatusCounts(), loadSourceCounts(), loadSourceStatusCounts(), loadTemplates(), loadFilterOptions()]);
  await loadContactsPage();
  render();
  // Load dashboard data in background (non-blocking)
  loadDashboard();
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
      <img src="/dw-logo.jpg" alt="Day Webster Group" />
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
      <div class="tab ${state.view === 'responses' ? 'active' : ''} ${state.responsesData?.stats?.unread_replies > 0 ? 'tab-badge' : ''}" data-view="responses">📬 Responses${state.responsesData?.stats?.unread_replies > 0 ? ` <span class="tab-count">${state.responsesData.stats.unread_replies}</span>` : ''}</div>
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
  // Filter sources based on user permissions
  const userSources = state.userProfile?.allowed_sources || [];
  const isAdmin = !state.userProfile || state.userProfile.role === 'admin' || userSources.length === 0;

  const SOURCES = [
    { key: 'all',             label: 'All Sources',        live: true  },
    { key: 'gp_surgery',      label: 'GP Surgeries',       live: true  },
    { key: 'children_homes',  label: "Children's Homes",   live: true  },
    { key: 'agency',          label: 'Agency Outreach',    live: true  },
    { key: 'ahp',             label: 'NHS Jobs AHP',       live: true  },
    { key: 'care_home',       label: 'Care Homes',         live: true  },
    { key: 'pharmacy',        label: 'Pharmacy',           live: true  },
    { key: 'bms',             label: 'BMS',                live: false },
    { key: 'sterile',         label: 'Sterile Services',   live: false },
    { key: 'private_theatre', label: 'Private Theatres',   live: true  },
    { key: 'nhs_staffbank',   label: 'NHS Staff Banks',    live: false },
    { key: 'camhs',           label: 'CAMHS',              live: false },
  ];

  const total = state.totalRows;
  const start = (state.page - 1) * state.pageSize;
  const totalPages = Math.max(1, Math.ceil(total / state.pageSize));
  const selN = state.selected.size;
  const allPageSel = selN > 0 && selN === state.currentRows.length;
  const somePageSel = selN > 0 && !allPageSel;

  return `
    <div class="source-tabs">
      ${SOURCES.filter(s => s.key === 'all' || isAdmin || userSources.includes(s.key)).map(s => `
        <button class="source-tab${state.sourceFilter === s.key ? ' active' : ''}${!s.live ? ' soon' : ''}"
          data-source="${s.key}"${!s.live ? ' disabled title="Coming soon"' : ''}>
          ${esc(s.label)}
          ${s.live && state.sourceCounts[s.key] != null
            ? `<span class="source-count">${Number(state.sourceCounts[s.key]).toLocaleString()}</span>`
            : !s.live ? '<span class="source-soon">soon</span>' : ''}
          ${s.key === 'children_homes' && s.live ? '<span class="source-warn" title="Most have placeholder emails — run enrichment">⚠</span>' : ''}
        </button>
      `).join('')}
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
      ${state.sourceFilter !== 'all' ? `<div class="source-filter-label">Showing: <strong>${state.sourceFilter.replace(/_/g,' ')}</strong></div>` : ''}
      <div class="subtab ${state.subTab === 'lead' ? 'active' : ''}" data-subtab="lead">Leads<span class="count">${state.sourceFilter !== 'all' ? (state.sourceStatusCounts.lead ?? 0) : state.counts.lead}</span></div>
      <div class="subtab ${state.subTab === 'live' ? 'active' : ''}" data-subtab="live">Live<span class="count">${state.sourceFilter !== 'all' ? (state.sourceStatusCounts.live ?? 0) : state.counts.live}</span></div>
      <div class="subtab ${state.subTab === 'unsubscribed' ? 'active' : ''}" data-subtab="unsubscribed">Unsubscribes<span class="count">${state.sourceFilter !== 'all' ? (state.sourceStatusCounts.unsubscribed ?? 0) : state.counts.unsubscribed}</span></div>
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
            ${state.sourceFilter !== 'ahp' ? `<th data-sort="org">Surgery / Org</th><th data-sort="first_name">Contact</th><th data-sort="job_title">Role</th><th data-sort="email">Email</th><th data-sort="town">Town</th><th data-sort="region">Region</th>` : ''}
            ${state.sourceFilter === 'ahp' ? `
              <th>Contact Name</th>
              <th>Email</th>
              <th>Phone</th>
              <th>NHS Trust</th>
              <th>Department</th>
              <th>Specialty</th>
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
              ${state.sourceFilter !== 'ahp' ? `
              <td class="ellipsis" title="${esc(c.org)}">${esc(c.org)}</td>
              <td>${esc([c.title, c.first_name, c.last_name].filter(Boolean).join(' '))}</td>
              <td>${esc(c.job_title)}</td>
              <td class="ellipsis" title="${esc(c.email)}">${esc(c.email)}</td>
              <td>${esc(c.town)}</td>
              <td>${esc(c.region)}</td>` : ''}
              ${state.sourceFilter === 'ahp'
                ? `<td>${esc(([c.first_name,c.last_name].filter(Boolean).join(' ')) || '—')}</td>
                   <td class="ellipsis" title="${esc(c.email)}">${esc(c.email || '—')}</td>
                   <td>${esc(c.phone || '—')}</td>
                   <td class="ellipsis" title="${esc(c.org)}">${esc(c.org || '—')}</td>
                   <td>${esc(c.department || '—')}</td>
                   <td>${esc(extractSpecialty(c.notes))}</td>
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
      <code>{{FirstName}}</code> <code>{{LastName}}</code> <code>{{Title}}</code>
      <code>{{Org}}</code> <code>{{Town}}</code> <code>{{Region}}</code> <code>{{JobTitle}}</code>
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




async function saveSenderDetails() {
  state.senderSaving = true; state.senderSaved = false; render();
  try {
    const { data: { session } } = await sb.auth.getSession();
    const res = await fetch('https://udttpnaenmyxviuiwxqw.supabase.co/functions/v1/user-manager', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + session?.access_token },
      body: JSON.stringify({
        action: 'update_sender',
        sender_email: state.senderEmail,
        sender_name:  state.senderName,
      }),
    });
    const data = await res.json();
    if (data.success) {
      state.senderSaved = true;
      // Update the local profile cache
      if (state.userProfile) {
        state.userProfile.sender_email = state.senderEmail;
        state.userProfile.sender_name  = state.senderName;
      }
      toast('Sender details saved ✓');
      setTimeout(() => { state.senderSaved = false; render(); }, 3000);
    } else {
      toast('Error: ' + (data.error || 'Unknown'));
    }
  } catch(e) { toast('Error: ' + e.message); }
  state.senderSaving = false; render();
}

async function loadTeamUsers() {
  state.teamLoading = true; render();
  try {
    const { data: { session } } = await sb.auth.getSession();
    const res = await fetch('https://udttpnaenmyxviuiwxqw.supabase.co/functions/v1/user-manager', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + session?.access_token },
      body: JSON.stringify({ action: 'list' }),
    });
    const data = await res.json();
    state.teamUsers = data.users || [];
  } catch(e) { console.error('loadTeamUsers:', e); }
  state.teamLoading = false; render();
}

async function sendInvite() {
  const { data: { session } } = await sb.auth.getSession();
  const res = await fetch('https://udttpnaenmyxviuiwxqw.supabase.co/functions/v1/user-manager', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + session?.access_token },
    body: JSON.stringify({
      action: 'invite',
      email: state.inviteEmail,
      full_name: state.inviteName,
      role: 'user',
      allowed_sources: state.inviteSources,
      sender_email: state.inviteSenderEmail || state.inviteEmail,
      sender_name:  state.inviteSenderName  || state.inviteName,
    }),
  });
  state.inviteResult = await res.json();
  if (state.inviteResult.success) {
    state.inviteEmail = ''; state.inviteName = ''; state.inviteSources = [];
    await loadTeamUsers();
  }
  render();
}

async function sendFilteredViaBrevo() {
  const template = state.templates.find(t => t.id === state.composeTemplateId);
  if (!template) return toast('Select a template first');

  state.composeBrevoSending = true;
  state.composeBrevoResult = null;
  render();

  try {
    // Build queue from current filters
    const queue = await buildComposeQueueFromDb();
    if (!queue.length) {
      state.composeBrevoResult = { error: 'No contacts match your current filters' };
      state.composeBrevoSending = false;
      render();
      return;
    }

    const ids = queue.map(c => c.id);
    const { data: { session } } = await sb.auth.getSession();
    const token = session?.access_token;
    if (!token) throw new Error('Not authenticated');

    const batchId = 'batch_' + Date.now();
    const res = await fetch('https://udttpnaenmyxviuiwxqw.supabase.co/functions/v1/send-mailshot', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ' + token,
      },
      body: JSON.stringify({
        templateId: template.id,
        contactIds: ids,
        batchId,
        senderEmail: 'scott.lane@daywebster.com',
        senderName: 'Day Webster Group',
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
              {k:'pharmacy',       l:'Pharmacy'},
              {k:'private_theatre',l:'Private Theatres'},
              {k:'ahp',            l:'AHP (NHS Jobs)'},
              {k:'care_home',     l:'Care Homes'},
              {k:'bms',            l:'BMS'},
              {k:'sterile',        l:'Sterile Services'},
              {k:'nhs_staffbank',  l:'NHS Staff Banks'},
              {k:'camhs',          l:'CAMHS'},
            ].map(s => `<option value="${s.k}" ${state.composeSourceFilter===s.k?'selected':''}>${s.l}</option>`).join('')}
          </select>
        </div>
        <div class="field">
          <label>Status</label>
          <select class="select" id="compose-list">
            <option value="lead" ${state.composeListFilter==='lead'?'selected':''}>Leads (${state.counts.lead})</option>
            <option value="live" ${state.composeListFilter==='live'?'selected':''}>Live (${state.counts.live})</option>
          </select>
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
          ${state.composeBrevoSending ? '<span class="spinner-inline"></span> Sending&hellip;' : '&#9654;&nbsp;Send ' + Math.min(previewMatch, state.composeBatchSize) + ' Emails via Brevo'}
        </button>
        ${!template ? '<span class="muted" style="font-size:12px;">Select a template first</span>' : ''}
        ${!previewMatch ? '<span class="muted" style="font-size:12px;">No contacts match — adjust filters</span>' : ''}
      </div>

      ${state.composeBrevoSending ? `
        <div class="import-progress" style="margin-top:12px;">
          <div class="progress-bar"><div class="fill import-pulse"></div></div>
          <p class="muted" style="margin-top:6px;font-size:12px;">Sending personalised emails via Brevo&hellip;</p>
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
          ${state.senderEmail ? `<p class="muted" style="margin:4px 0 0;font-size:11px;">Sending from: <strong>${esc(state.senderName || state.senderEmail)}</strong> &lt;${esc(state.senderEmail)}&gt;</p>` : ''}
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
            : '&#9654;&nbsp;Send ' + ids.length + ' Emails via Brevo'}
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

async function runAgencyCSVUpload() {
  if (!state.agencyCsvText) return;
  state.agencyUploading = true; state.agencyResult = null; render();
  try {
    const res = await fetch('https://udttpnaenmyxviuiwxqw.supabase.co/functions/v1/csv-upload', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVkdHRwbmFlbm15eHZpdWl3eHF3Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzkxNzAwODIsImV4cCI6MjA5NDc0NjA4Mn0.b7zeFYbNPSo7WjFu6-VFhMVelD2g1ja9m3af0Jb5geU' },
      body: JSON.stringify({ csv: state.agencyCsvText, source: state.agencyCsvSource }),
    });
    state.agencyResult = await res.json();
    if (state.agencyResult.success) {
      await Promise.all([loadStatusCounts(), loadSourceCounts()]);
    }
  } catch(e) { state.agencyResult = { success: false, error: e.message }; }
  state.agencyUploading = false; render();
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
  const region = document.getElementById('ch-region')?.value || '';
  const care_type = document.getElementById('ch-type')?.value || 'all';
  const limit = parseInt(document.getElementById('ch-limit')?.value || '20');
  state.careHomeRunning = true; state.careHomeResult = null; render();
  try {
    const res = await fetch('https://udttpnaenmyxviuiwxqw.supabase.co/functions/v1/care-home-scraper', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVkdHRwbmFlbm15eHZpdWl3eHF3Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzkxNzAwODIsImV4cCI6MjA5NDc0NjA4Mn0.b7zeFYbNPSo7WjFu6-VFhMVelD2g1ja9m3af0Jb5geU' },
      body: JSON.stringify({ region, care_type, limit }),
    });
    state.careHomeResult = await res.json();
    if (state.careHomeResult.success && state.careHomeResult.inserted > 0) {
      await Promise.all([loadStatusCounts(), loadSourceCounts()]);
    }
  } catch(e) { state.careHomeResult = { success: false, error: e.message }; }
  state.careHomeRunning = false; render();
}

async function runPharmacyScrape() {
  const region = document.getElementById('ph-region')?.value || '';
  const limit = parseInt(document.getElementById('ph-limit')?.value || '20');
  state.pharmacyRunning = true; state.pharmacyResult = null; render();
  try {
    const res = await fetch('https://udttpnaenmyxviuiwxqw.supabase.co/functions/v1/pharmacy-scraper', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVkdHRwbmFlbm15eHZpdWl3eHF3Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzkxNzAwODIsImV4cCI6MjA5NDc0NjA4Mn0.b7zeFYbNPSo7WjFu6-VFhMVelD2g1ja9m3af0Jb5geU' },
      body: JSON.stringify({ region, limit }),
    });
    state.pharmacyResult = await res.json();
    if (state.pharmacyResult.success) {
      await Promise.all([loadStatusCounts(), loadSourceCounts()]);
    }
  } catch(e) { state.pharmacyResult = { success: false, error: e.message }; }
  state.pharmacyRunning = false; render();
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

      <!-- Children's Homes Email Enrichment -->
      <div class="import-card">
        <div class="import-card-header">
          <div class="import-card-icon">🏠</div>
          <div class="import-card-meta">
            <div class="import-card-title">Children's Homes — Email Enrichment</div>
            <div class="import-card-sub">Claude agent searches each home's website to find contact email addresses. 711 homes loaded, run multiple times to enrich batches of 50.</div>
          </div>
          <span class="import-badge live">Live</span>
        </div>
        <div class="import-form">
          <div class="import-form-row" style="grid-template-columns:1fr;">
            <div class="field">
              <label>Batch size per run</label>
              <select class="select" id="enrich-limit">
                <option value="20">20 homes</option>
                <option value="50" selected>50 homes</option>
              </select>
            </div>
          </div>
          <div class="import-form-actions">
            <button class="btn primary" id="run-enrich-btn" ${state.enrichRunning ? 'disabled' : ''}>
              ${state.enrichRunning ? '<span class="spinner-inline"></span> Enriching&hellip;' : '&#9654; Run Enrichment'}
            </button>
            <span class="import-hint">Each run processes a batch and takes 2&ndash;5 minutes. Run multiple times to work through all 711 homes. Contacts already enriched are skipped automatically.</span>
          </div>
        </div>
        ${state.enrichRunning ? '<div class="import-progress"><div class="progress-bar"><div class="fill import-pulse"></div></div><p class="muted" style="margin-top:8px;font-size:12px;">Searching home websites for contact emails&hellip;</p></div>' : ''}
        ${state.enrichResult ? `<div class="import-result ${state.enrichResult.success ? 'ok' : 'err'}">
          ${state.enrichResult.success ? `
            <div class="import-result-stats">
              <div class="import-stat"><div class="import-stat-val">${state.enrichResult.emails_found || 0}</div><div class="import-stat-lbl">Emails found</div></div>
              <div class="import-stat"><div class="import-stat-val">${state.enrichResult.not_found || 0}</div><div class="import-stat-lbl">Not found</div></div>
              <div class="import-stat"><div class="import-stat-val">${state.enrichResult.enriched_total || 0}</div><div class="import-stat-lbl">Processed</div></div>
            </div>
            <p class="muted" style="margin-top:8px;font-size:12px;">&#10003; Batch complete. Run again to process the next 50 homes.</p>`
          : `<p style="color:#DC2626;font-size:13px;">&#10005; ${esc(state.enrichResult.error || 'Error')}</p>`}
        </div>` : ''}
      </div>


      <!-- Agency Outreach CSV Upload -->
      <div class="import-card">
        <div class="import-card-header">
          <div class="import-card-icon">📂</div>
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
                  { v: 'pharmacy',        l: 'Pharmacy' },
                  { v: 'private_theatre', l: 'Private Theatres' },
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
        ${state.agencyUploading ? '<div class="import-progress"><div class="progress-bar"><div class="fill import-pulse"></div></div></div>' : ''}
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


      <div class="import-card">
        <div class="import-card-header">
          <div class="import-card-icon">🏥</div>
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
            <button class="btn primary" id="run-scrape-btn" ${state.importRunning ? 'disabled' : ''}>
              ${state.importRunning ? '<span class="spinner-inline"></span> Scraping NHS Jobs&hellip;' : '&#9654; Run Scraper'}
            </button>
            <span class="import-hint">Agent reads NHS Jobs postings and extracts "For further details" contact blocks. Takes 1&ndash;3 minutes.</span>
          </div>
        </div>

        ${state.importRunning ? `
          <div class="import-progress">
            <div class="progress-bar"><div class="fill import-pulse"></div></div>
            <p class="muted" style="margin-top:8px;font-size:12px;">Searching NHS Jobs and reading postings&hellip; please wait</p>
          </div>` : ''}

        ${r ? `<div class="import-result ${r.success ? 'ok' : 'err'}">
          ${r.success ? `
            <div class="import-result-stats">
              <div class="import-stat"><div class="import-stat-val">${r.inserted}</div><div class="import-stat-lbl">Added</div></div>
              <div class="import-stat"><div class="import-stat-val">${r.found}</div><div class="import-stat-lbl">Found</div></div>
              <div class="import-stat"><div class="import-stat-val">${r.skipped_no_email}</div><div class="import-stat-lbl">No email</div></div>
              <div class="import-stat"><div class="import-stat-val">${r.skipped_dup}</div><div class="import-stat-lbl">Duplicate</div></div>
            </div>
            <p class="muted" style="margin-top:8px;font-size:12px;">&#10003; ${r.inserted} new ${(r.specialty||'').replace('_',' ')} contacts added &mdash; switch to Database &rarr; All Sources to view them</p>
          ` : `
            <p style="color:#DC2626;font-size:13px;">&#10005; ${esc(r.error || 'Unknown error')}</p>
            ${(r.error||'').includes('ANTHROPIC_API_KEY') ? '<p class="muted" style="margin-top:6px;font-size:12px;">Add key: Supabase Dashboard &rarr; Project Settings &rarr; Edge Functions &rarr; Secrets &rarr; ANTHROPIC_API_KEY</p>' : ''}
          `}
        </div>` : ''}
      </div>



      <!-- Care Homes Scraper -->
      <div class="import-card">
        <div class="import-card-header">
          <div class="import-card-icon">🏡</div>
          <div class="import-card-meta">
            <div class="import-card-title">Care Homes — Registered Managers</div>
            <div class="import-card-sub">Claude agent finds registered care home managers across England with email addresses. Covers residential, nursing, dementia and supported living.</div>
          </div>
          <span class="import-badge live">Live</span>
        </div>
        <div class="import-form">
          <div class="import-form-row">
            <div class="field">
              <label>Region</label>
              <select class="select" id="ch-region">
                <option value="">All England</option>
                ${['North West','North East, Yorkshire and The Humber','West Midlands','East Midlands','East of England','South East','London','South West'].map(r => `<option value="${r}">${r}</option>`).join('')}
              </select>
            </div>
            <div class="field">
              <label>Care Type</label>
              <select class="select" id="ch-type">
                <option value="all">All Types</option>
                <option value="residential">Residential</option>
                <option value="nursing">Nursing</option>
                <option value="dementia">Dementia</option>
                <option value="learning_disability">Learning Disability</option>
              </select>
            </div>
            <div class="field">
              <label>Max Contacts</label>
              <select class="select" id="ch-limit">
                ${[10,20,30,50].map(n => `<option value="${n}" ${n===20?'selected':''}>${n}</option>`).join('')}
              </select>
            </div>
          </div>
          <div class="import-form-actions">
            <button class="btn primary" id="run-carehome-btn" ${state.careHomeRunning ? 'disabled' : ''}>
              ${state.careHomeRunning ? '<span class="spinner-inline"></span> Searching&hellip;' : '&#9654; Run Care Home Scraper'}
            </button>
            <span class="import-hint">Searches for care home registered managers with email addresses. Takes 2&ndash;4 minutes per run.</span>
          </div>
        </div>
        ${state.careHomeRunning ? '<div class="import-progress"><div class="progress-bar"><div class="fill import-pulse"></div></div></div>' : ''}
        ${state.careHomeResult ? `<div class="import-result ${state.careHomeResult.success ? 'ok' : 'err'}">
          ${state.careHomeResult.success ? `
            <div class="import-result-stats">
              <div class="import-stat"><div class="import-stat-val">${state.careHomeResult.inserted}</div><div class="import-stat-lbl">Added</div></div>
              <div class="import-stat"><div class="import-stat-val">${state.careHomeResult.found}</div><div class="import-stat-lbl">Found</div></div>
              <div class="import-stat"><div class="import-stat-val">${state.careHomeResult.skipped_no_email}</div><div class="import-stat-lbl">No email</div></div>
              <div class="import-stat"><div class="import-stat-val">${state.careHomeResult.skipped_dup}</div><div class="import-stat-lbl">Dupe</div></div>
            </div>` : `<p style="color:#DC2626;font-size:13px;">&#10005; ${esc(state.careHomeResult.error || 'Error')}</p>`}
        </div>` : ''}
      </div>

      <!-- Pharmacy Scraper -->
      <div class="import-card">
        <div class="import-card-header">
          <div class="import-card-icon">💊</div>
          <div class="import-card-meta">
            <div class="import-card-title">Pharmacy — Superintendent Pharmacists</div>
            <div class="import-card-sub">CQC register + Claude agent finds superintendent pharmacist emails at independent pharmacies</div>
          </div>
          <span class="import-badge live">Live</span>
        </div>
        <div class="import-form">
          <div class="import-form-row">
            <div class="field"><label>Region</label>
              <select class="select" id="ph-region">
                <option value="">All England</option>
                ${REGIONS.map(rg => `<option value="${rg}">${rg}</option>`).join('')}
              </select>
            </div>
            <div class="field"><label>Max Contacts</label>
              <select class="select" id="ph-limit">
                ${[10,20,30,50].map(n => `<option value="${n}" ${n===20?'selected':''}>${n}</option>`).join('')}
              </select>
            </div>
          </div>
          <div class="import-form-actions">
            <button class="btn primary" id="run-pharmacy-btn" ${state.pharmacyRunning ? 'disabled' : ''}>
              ${state.pharmacyRunning ? '<span class="spinner-inline"></span> Searching&hellip;' : '&#9654; Run Pharmacy Scraper'}
            </button>
            <span class="import-hint">Independent pharmacies from CQC register. Finds superintendent pharmacist email per pharmacy. 2&ndash;5 min.</span>
          </div>
        </div>
        ${state.pharmacyRunning ? `<div class="import-progress"><div class="progress-bar"><div class="fill import-pulse"></div></div></div>` : ''}
        ${state.pharmacyResult ? `<div class="import-result ${state.pharmacyResult.success ? 'ok' : 'err'}">
          ${state.pharmacyResult.success
            ? `<div class="import-result-stats">
                <div class="import-stat"><div class="import-stat-val">${state.pharmacyResult.inserted}</div><div class="import-stat-lbl">Added</div></div>
                <div class="import-stat"><div class="import-stat-val">${state.pharmacyResult.found}</div><div class="import-stat-lbl">Found</div></div>
                <div class="import-stat"><div class="import-stat-val">${state.pharmacyResult.skipped_no_email}</div><div class="import-stat-lbl">No email</div></div>
                <div class="import-stat"><div class="import-stat-val">${state.pharmacyResult.skipped_dup}</div><div class="import-stat-lbl">Dupe</div></div>
              </div>`
            : `<p style="color:#DC2626;font-size:13px;">&#10005; ${esc(state.pharmacyResult.error || 'Error')}</p>`}
        </div>` : ''}
      </div>

      <!-- Private Theatre Scraper -->
      <div class="import-card">
        <div class="import-card-header">
          <div class="import-card-icon">🏨</div>
          <div class="import-card-meta">
            <div class="import-card-title">Private Hospitals — Theatre Managers</div>
            <div class="import-card-sub">CQC independent acute hospital register + Claude agent finds theatre manager contacts</div>
          </div>
          <span class="import-badge live">Live</span>
        </div>
        <div class="import-form">
          <div class="import-form-row">
            <div class="field"><label>Region</label>
              <select class="select" id="pt-region">
                <option value="">All England</option>
                ${REGIONS.map(rg => `<option value="${rg}">${rg}</option>`).join('')}
              </select>
            </div>
            <div class="field"><label>Max Contacts</label>
              <select class="select" id="pt-limit">
                ${[10,20,30,50].map(n => `<option value="${n}" ${n===20?'selected':''}>${n}</option>`).join('')}
              </select>
            </div>
          </div>
          <div class="import-form-actions">
            <button class="btn primary" id="run-theatre-btn" ${state.theatreRunning ? 'disabled' : ''}>
              ${state.theatreRunning ? '<span class="spinner-inline"></span> Searching&hellip;' : '&#9654; Run Theatre Scraper'}
            </button>
            <span class="import-hint">Independent acute hospitals from CQC. Finds theatre manager / head of theatres contact. 2&ndash;5 min.</span>
          </div>
        </div>
        ${state.theatreRunning ? `<div class="import-progress"><div class="progress-bar"><div class="fill import-pulse"></div></div></div>` : ''}
        ${state.theatreResult ? `<div class="import-result ${state.theatreResult.success ? 'ok' : 'err'}">
          ${state.theatreResult.success
            ? `<div class="import-result-stats">
                <div class="import-stat"><div class="import-stat-val">${state.theatreResult.inserted}</div><div class="import-stat-lbl">Added</div></div>
                <div class="import-stat"><div class="import-stat-val">${state.theatreResult.found}</div><div class="import-stat-lbl">Found</div></div>
                <div class="import-stat"><div class="import-stat-val">${state.theatreResult.skipped_no_email}</div><div class="import-stat-lbl">No email</div></div>
                <div class="import-stat"><div class="import-stat-val">${state.theatreResult.skipped_dup}</div><div class="import-stat-lbl">Dupe</div></div>
              </div>`
            : `<p style="color:#DC2626;font-size:13px;">&#10005; ${esc(state.theatreResult.error || 'Error')}</p>`}
        </div>` : ''}
      </div>

      ${placeholders.map(p => `
        <div class="import-card disabled">
          <div class="import-card-header">
            <div class="import-card-icon">${p.icon}</div>
            <div class="import-card-meta">
              <div class="import-card-title">${p.title}</div>
              <div class="import-card-sub">${p.sub}</div>
            </div>
            <span class="import-badge soon">Soon</span>
          </div>
        </div>
      `).join('')}
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
          <div class="dash-stat-sub">${(t.sentThisMonth || 0).toLocaleString()} this month</div>
        </div>
        <div class="dash-stat">
          <div class="dash-stat-val">${(p.live || 0).toLocaleString()}</div>
          <div class="dash-stat-lbl">Live clients</div>
          <div class="dash-stat-sub"><a class="dash-link" data-dash-action="compose">Send outreach →</a></div>
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

          <!-- Source health -->
          <div class="dash-card">
            <div class="dash-card-title">Data Sources</div>
            <div class="dash-sources">
              ${[
                { key: 'gp_surgery', label: 'GP Surgeries', count: s.gp_surgery || 0, emailable: s.gp_surgery || 0, icon: '🏥' },
                { key: 'children_homes', label: "Children's Homes", count: s.children_homes || 0, emailable: 0, icon: '🏠', warn: true },
                { key: 'ahp', label: 'AHP (NHS Jobs)', count: s.ahp || 0, emailable: s.ahp || 0, icon: '⚕️' },
              ].map(src => {
                const pct = src.count ? Math.round((src.emailable / src.count) * 100) : 0;
                const health = pct === 0 ? 'warn' : pct < 50 ? 'amber' : 'ok';
                return `
                  <div class="dash-source-row">
                    <span class="dash-source-icon">${src.icon}</span>
                    <span class="dash-source-name">${src.label}</span>
                    <span class="dash-source-count">${src.count.toLocaleString()}</span>
                    <span class="dash-source-health dash-health-${health}">${
                      pct === 0 && src.count > 0 ? '⚠ No emails' : pct + '% emailable'
                    }</span>
                  </div>`;
              }).join('')}
            </div>
            ${(s.children_homes || 0) > 0 ? `
              <div class="dash-warn-banner">
                ⚠ <strong>${(s.children_homes||0).toLocaleString()} Children's Homes</strong> have placeholder emails.
                Add <code>ANTHROPIC_API_KEY</code> in Supabase Secrets then trigger the enrichment agent to find real emails.
              </div>` : ''}
          </div>
        </div>

        <div class="dash-col-side">

          <!-- Quick actions -->
          <div class="dash-card">
            <div class="dash-card-title">Quick actions</div>
            <div class="dash-actions">
              <button class="btn primary dash-action-btn" data-dash-action="compose">✉ Send outreach batch</button>
              <button class="btn dash-action-btn" data-dash-action="import">⬇ Import AHP contacts</button>
              <button class="btn dash-action-btn" data-dash-action="database">📋 View all contacts</button>
              <button class="btn dash-action-btn" data-dash-action="followup">🔔 Follow-ups due (${t.followUpsDue || 0})</button>
            </div>
          </div>

          <!-- Recent activity -->
          <div class="dash-card">
            <div class="dash-card-title">Recent sends</div>
            ${recent.length === 0
              ? `<p class="muted" style="font-size:12px;padding:8px 0;">No emails sent yet.<br>Set up Brevo API key and send your first batch.</p>`
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


// ============================================================================
//  RESPONSES TAB — Engagement (Brevo) + Replies (M365)
// ============================================================================

const SB_URL_RESP  = 'https://udttpnaenmyxviuiwxqw.supabase.co';
const SB_ANON_RESP = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVkdHRwbmFlbm15eHZpdWl3eHF3Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzkxNzAwODIsImV4cCI6MjA5NDc0NjA4Mn0.b7zeFYbNPSo7WjFu6-VFhMVelD2g1ja9m3af0Jb5geU';

// Microsoft Azure App Registration Client ID
// To set up: Azure Portal → App registrations → New → add redirect URI for your Vercel URL
// Scope needed: Mail.Read
const M365_CLIENT_ID = Deno?.env ? '' : (window.M365_CLIENT_ID || '');

async function loadResponsesData() {
  state.responsesLoading = true;
  render();
  try {
    const [eventsRes, repliesRes, statsRes] = await Promise.all([
      // Recent events
      sb.from('email_events')
        .select('id, event_type, email, occurred_at, link_url, batch_id, contacts(first_name, last_name, org)')
        .order('occurred_at', { ascending: false })
        .limit(50),
      // Unread replies
      sb.from('replies')
        .select('id, from_email, from_name, subject, body_preview, received_at, read, contacts(first_name, last_name, org)')
        .order('received_at', { ascending: false })
        .limit(50),
      // Engagement stats
      sb.from('email_events').select('event_type, id', { count: 'exact' }),
    ]);

    const events = eventsRes.data || [];
    const replies = repliesRes.data || [];
    const allEvents = statsRes.data || [];

    const stats = {
      total_opens:       allEvents.filter(e => e.event_type === 'opened').length,
      total_clicks:      allEvents.filter(e => e.event_type === 'clicked').length,
      total_bounces:     allEvents.filter(e => ['hard_bounce','soft_bounce'].includes(e.event_type)).length,
      total_unsubscribed: allEvents.filter(e => e.event_type === 'unsubscribed').length,
      unread_replies:    replies.filter(r => !r.read).length,
    };

    state.responsesData = { events, replies, stats };
  } catch(e) {
    state.responsesData = { error: e.message };
  }
  state.responsesLoading = false;
  render();
}

async function syncM365Replies() {
  // Use MSAL popup to get access token
  state.m365Syncing = true;
  state.m365SyncResult = null;
  render();

  try {
    // Check if MSAL is loaded
    if (typeof window.msal === 'undefined') {
      throw new Error('Microsoft authentication library not loaded. Please refresh the page and try again.');
    }

    const msalConfig = {
      auth: {
        clientId: state.m365ClientId || '',
        authority: 'https://login.microsoftonline.com/common',
        redirectUri: window.location.origin,
      }
    };

    if (!msalConfig.auth.clientId) {
      state.m365ShowClientIdInput = true;
      state.m365Syncing = false;
      render();
      return;
    }

    const msalInstance = new window.msal.PublicClientApplication(msalConfig);
    await msalInstance.initialize();

    const loginRequest = { scopes: ['Mail.Read', 'User.Read'] };
    const tokenResponse = await msalInstance.acquireTokenPopup(loginRequest);
    const m365Token = tokenResponse.accessToken;

    // Call our Edge Function with the token
    const { data: { session } } = await sb.auth.getSession();
    const res = await fetch(`${SB_URL_RESP}/functions/v1/m365-sync`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ' + session?.access_token,
      },
      body: JSON.stringify({ m365Token, daysBack: state.m365DaysBack || 30 }),
    });

    state.m365SyncResult = await res.json();
    if (state.m365SyncResult.success) {
      await loadResponsesData();
      toast(`Synced ${state.m365SyncResult.synced} replies from Outlook ✓`);
    }
  } catch(e) {
    state.m365SyncResult = { success: false, error: e.message };
  }

  state.m365Syncing = false;
  render();
}

async function markReplyRead(replyId) {
  await sb.from('replies').update({ read: true }).eq('id', replyId);
  if (state.responsesData?.replies) {
    const r = state.responsesData.replies.find(r => r.id === replyId);
    if (r) r.read = true;
  }
  render();
}

function renderResponses() {
  if (state.responsesLoading || !state.responsesData) {
    return `<div class="dash-loading"><div class="dash-spinner"></div><p>Loading responses&hellip;</p></div>`;
  }

  const d = state.responsesData;
  if (d.error) return `<div class="dash-error">Error: ${esc(d.error)}</div>`;

  const s = d.stats || {};
  const replies = d.replies || [];
  const events = d.events || [];
  const unreadReplies = replies.filter(r => !r.read);

  const EVENT_ICONS = {
    opened: '👁',
    clicked: '🖱',
    delivered: '✓',
    sent: '📤',
    hard_bounce: '⚠',
    soft_bounce: '↩',
    unsubscribed: '⊘',
    complaint: '🚫',
    replied: '↩',
  };

  const EVENT_COLORS = {
    opened: 'event-open',
    clicked: 'event-click',
    delivered: 'event-delivered',
    hard_bounce: 'event-bounce',
    soft_bounce: 'event-bounce',
    unsubscribed: 'event-unsub',
    complaint: 'event-bounce',
  };

  return `
    <div class="responses-wrap">

      <!-- Stats row -->
      <div class="dash-stats" style="margin-bottom:16px;">
        <div class="dash-stat">
          <div class="dash-stat-val">${s.unread_replies || 0}</div>
          <div class="dash-stat-lbl">Unread replies</div>
          <div class="dash-stat-sub">${replies.length} total</div>
        </div>
        <div class="dash-stat">
          <div class="dash-stat-val">${s.total_opens || 0}</div>
          <div class="dash-stat-lbl">Email opens</div>
          <div class="dash-stat-sub">Tracked via Brevo</div>
        </div>
        <div class="dash-stat">
          <div class="dash-stat-val">${s.total_clicks || 0}</div>
          <div class="dash-stat-lbl">Link clicks</div>
          <div class="dash-stat-sub">${s.total_unsubscribed || 0} unsubscribed</div>
        </div>
        <div class="dash-stat ${s.total_bounces > 0 ? 'dash-stat-alert' : ''}">
          <div class="dash-stat-val">${s.total_bounces || 0}</div>
          <div class="dash-stat-lbl">Bounces</div>
          <div class="dash-stat-sub">${s.total_bounces > 0 ? 'Check contacts' : 'All good'}</div>
        </div>
      </div>

      <div class="responses-cols">

        <!-- REPLIES from Outlook -->
        <div class="responses-panel">
          <div class="responses-panel-header">
            <h3>📬 Replies from Outlook</h3>
            <div style="display:flex;gap:8px;align-items:center;flex-wrap:wrap;">
              <select class="select" id="m365-days" style="font-size:12px;padding:4px 8px;width:auto;">
                <option value="7">Last 7 days</option>
                <option value="30" selected>Last 30 days</option>
                <option value="90">Last 90 days</option>
              </select>
              <button class="btn primary" id="sync-m365-btn" ${state.m365Syncing ? 'disabled' : ''}>
                ${state.m365Syncing ? '<span class="spinner-inline"></span> Syncing&hellip;' : '🔄 Sync from Outlook'}
              </button>
            </div>
          </div>

          ${state.m365ShowClientIdInput ? `
          <div class="m365-setup">
            <p style="font-size:13px;margin-bottom:10px;">To sync Outlook replies, enter your Azure App Client ID:</p>
            <input class="search" id="m365-client-id-input" placeholder="e.g. 12345678-1234-1234-1234-123456789abc"
              value="${esc(state.m365ClientId || '')}" style="margin-bottom:8px;" />
            <button class="btn primary" id="save-m365-client-id">Save & Connect</button>
            <p class="muted" style="font-size:11px;margin-top:8px;">
              Register a free Azure app: Azure Portal → App Registrations → New → 
              add <code>${window.location.origin}</code> as redirect URI → 
              grant <code>Mail.Read</code> permission → copy Client ID.
            </p>
          </div>` : ''}

          ${state.m365SyncResult && !state.m365Syncing ? `
          <div class="import-result ${state.m365SyncResult.success ? 'ok' : 'err'}" style="margin-bottom:12px;">
            ${state.m365SyncResult.success
              ? `<p style="font-size:13px;">✓ Synced ${state.m365SyncResult.synced} new replies from ${state.m365SyncResult.total_messages} emails checked</p>`
              : `<p style="color:#DC2626;font-size:13px;">✗ ${esc(state.m365SyncResult.error || 'Sync failed')}</p>`}
          </div>` : ''}

          ${replies.length === 0 ? `
          <div class="responses-empty">
            <p>No replies synced yet.</p>
            <p class="muted" style="font-size:12px;margin-top:6px;">Click "Sync from Outlook" to search your inbox for emails from contacts in your database.</p>
          </div>` : `
          <div class="replies-list">
            ${replies.map(r => {
              const c = r.contacts || {};
              const name = r.from_name || esc([c.first_name, c.last_name].filter(Boolean).join(' ')) || r.from_email;
              const when = r.received_at ? new Date(r.received_at).toLocaleDateString('en-GB', { day:'numeric', month:'short', hour:'2-digit', minute:'2-digit' }) : '';
              return `
                <div class="reply-card ${r.read ? '' : 'reply-unread'}" data-reply-id="${r.id}">
                  <div class="reply-card-header">
                    <div class="reply-from">${esc(name)}</div>
                    <div class="reply-when">${when}</div>
                  </div>
                  <div class="reply-org">${esc(c.org || r.from_email)}</div>
                  <div class="reply-subject">${esc(r.subject || '(no subject)')}</div>
                  <div class="reply-preview">${esc(r.body_preview || '')}</div>
                  ${!r.read ? `<button class="btn small reply-read-btn" data-reply-id="${r.id}">Mark read</button>` : ''}
                </div>`;
            }).join('')}
          </div>`}
        </div>

        <!-- ENGAGEMENT from Brevo -->
        <div class="responses-panel">
          <div class="responses-panel-header">
            <h3>📊 Email Engagement</h3>
            <span class="muted" style="font-size:11px;">Auto-tracked via Brevo webhook</span>
          </div>

          ${events.length === 0 ? `
          <div class="responses-empty">
            <p>No engagement events yet.</p>
            <p class="muted" style="font-size:12px;margin-top:6px;">
              Set up the Brevo webhook to start tracking opens and clicks.<br>
              Webhook URL: <code style="font-size:10px;word-break:break-all;">${SB_URL_RESP}/functions/v1/brevo-webhook</code>
            </p>
            <p class="muted" style="font-size:11px;margin-top:8px;">
              Brevo Dashboard → Transactional → Settings → Webhooks → Add new → paste URL above → 
              select: Delivered, Opened, Clicked, Soft bounce, Hard bounce, Unsubscribed.
            </p>
          </div>` : `
          <div class="events-list">
            ${events.map(ev => {
              const c = ev.contacts || {};
              const who = esc([c.first_name, c.last_name].filter(Boolean).join(' ')) || esc(ev.email);
              const org = esc(c.org || '');
              const icon = EVENT_ICONS[ev.event_type] || '•';
              const cls  = EVENT_COLORS[ev.event_type] || 'event-default';
              const when = ev.occurred_at ? new Date(ev.occurred_at).toLocaleDateString('en-GB', { day:'numeric', month:'short', hour:'2-digit', minute:'2-digit' }) : '';
              return `
                <div class="event-row ${cls}">
                  <span class="event-icon">${icon}</span>
                  <div class="event-body">
                    <div class="event-who">${who} ${org ? `<span class="muted">— ${org}</span>` : ''}</div>
                    <div class="event-type">${esc(ev.event_type.replace(/_/g,' '))} ${ev.link_url ? `<a href="${esc(ev.link_url)}" target="_blank" class="event-link">↗</a>` : ''}</div>
                  </div>
                  <span class="event-when">${when}</span>
                </div>`;
            }).join('')}
          </div>`}
        </div>

      </div>
    </div>
  `;
}


function renderSettings() {
  return `
    <h2 class="section-title">Settings</h2>
    <div class="settings-card">
      <h3>📤 Export Data</h3>
      <p>Download a backup of contacts as CSV. Useful for ad-hoc analysis or as a safety net.</p>
      <button class="btn primary" id="export-csv-all">⬇ Export All Contacts as CSV</button>
    </div>
    <div class="settings-card">
      <h3>👤 Account</h3>
      <p>Signed in as <strong>${esc(state.user.email)}</strong></p>
      <button class="btn danger" id="sign-out-btn-settings">Sign Out</button>
    </div>
    <div class="settings-card">
      <h3>ℹ️ About</h3>
      <p>Urgent Nursing Day Webster Outreach — Day Webster Group. Data lives in Supabase; access is restricted to authorised Day Webster Group email domains. Daily automated database backups run on the Supabase free tier (Dashboard → Database → Backups).</p>
    </div>
  `;
}

function renderModal() {
  const existing = document.querySelector('.modal-overlay');
  if (existing) existing.remove();
  if (!state.modal) return;

  let html = '';
  if (state.modal.type === 'edit-contact' || state.modal.type === 'add-contact') {
    const c = state.modal.contact;
    const isEdit = state.modal.type === 'edit-contact';
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
      ${isEdit ? `
        <div class="field"><label>Status</label>
          <select id="m-status">
            <option value="lead" ${c.status==='lead'?'selected':''}>Lead</option>
            <option value="live" ${c.status==='live'?'selected':''}>Live</option>
            <option value="unsubscribed" ${c.status==='unsubscribed'?'selected':''}>Unsubscribed</option>
          </select>
        </div>` : ''}
      <div class="field"><label>Notes</label><textarea id="m-notes">${esc(c.notes)}</textarea></div>
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
      if (state.view === 'settings' && state.userProfile?.role === 'admin') { loadTeamUsers(); }
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
      // Reset source filter for unsubs/live so all contacts are visible
      if (t.dataset.subtab === 'unsubscribed' || t.dataset.subtab === 'live') {
        state.sourceFilter = 'all';
        state.sourceStatusCounts = { lead: null, live: null, unsubscribed: null };
      }
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
  document.querySelectorAll('.source-tab:not([disabled])').forEach(t => {
    t.onclick = async () => {
      state.sourceFilter = t.dataset.source;
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
  // Agency CSV upload
  // Responses tab bindings
  const syncM365Btn = $('#sync-m365-btn');
  if (syncM365Btn) syncM365Btn.onclick = () => { if (!state.m365Syncing) syncM365Replies(); };

  // Sender details bindings
  const senderNameInput = $('#sender-name-input');
  if (senderNameInput) senderNameInput.oninput = e => { state.senderName = e.target.value; };
  const senderEmailInput = $('#sender-email-input');
  if (senderEmailInput) senderEmailInput.oninput = e => { state.senderEmail = e.target.value; };
  const saveSenderBtn = $('#save-sender-btn');
  if (saveSenderBtn) saveSenderBtn.onclick = () => { if (!state.senderSaving) saveSenderDetails(); };

  // Team management bindings
  if (state.view === 'settings' && state.userProfile?.role === 'admin' && state.teamUsers.length === 0) {
    loadTeamUsers();
  }
  const sendInviteBtn = $('#send-invite-btn');
  const inviteSenderNameInput = $('#invite-sender-name');
  const inviteSenderEmailInput = $('#invite-sender-email');
  if (sendInviteBtn) sendInviteBtn.onclick = () => {
    if (state.inviteEmail) {
      state.inviteSenderName  = inviteSenderNameInput?.value  || '';
      state.inviteSenderEmail = inviteSenderEmailInput?.value || state.inviteEmail;
      sendInvite();
    }
  };
  const inviteNameInput = $('#invite-name');
  if (inviteNameInput) inviteNameInput.oninput = e => { state.inviteName = e.target.value; };
  const inviteEmailInput = $('#invite-email');
  if (inviteEmailInput) inviteEmailInput.oninput = e => { state.inviteEmail = e.target.value; };
  document.querySelectorAll('.invite-source-cb').forEach(cb => {
    cb.onchange = () => {
      if (cb.checked) { state.inviteSources = [...new Set([...state.inviteSources, cb.value])]; }
      else { state.inviteSources = state.inviteSources.filter(s => s !== cb.value); }
    };
  });
  document.querySelectorAll('[data-delete-user]').forEach(btn => {
    btn.onclick = async () => {
      if (!confirm('Remove ' + btn.dataset.userEmail + ' from the team?')) return;
      const { data: { session } } = await sb.auth.getSession();
      await fetch('https://udttpnaenmyxviuiwxqw.supabase.co/functions/v1/user-manager', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + session?.access_token },
        body: JSON.stringify({ action: 'delete', target_user_id: btn.dataset.deleteUser }),
      });
      await loadTeamUsers();
    };
  });

  const m365DaysSelect = $('#m365-days');
  if (m365DaysSelect) m365DaysSelect.onchange = e => { state.m365DaysBack = parseInt(e.target.value); };

  const saveM365Btn = $('#save-m365-client-id');
  if (saveM365Btn) saveM365Btn.onclick = () => {
    const input = $('#m365-client-id-input');
    if (input?.value) {
      state.m365ClientId = input.value.trim();
      localStorage?.setItem?.('m365ClientId', state.m365ClientId);
      state.m365ShowClientIdInput = false;
      syncM365Replies();
    }
  };

  document.querySelectorAll('.reply-read-btn').forEach(btn => {
    btn.onclick = () => markReplyRead(btn.dataset.replyId);
  });

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
  if (runCareHomeBtn) runCareHomeBtn.onclick = () => { if (!state.careHomeRunning) runCareHomeScrape(); };
  const runPharmacyBtn = $('#run-pharmacy-btn');
  if (runPharmacyBtn) runPharmacyBtn.onclick = () => { if (!state.pharmacyRunning) runPharmacyScrape(); };
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
  if (composeSource) composeSource.onchange = (e) => { state.composeSourceFilter = e.target.value; state.composePreviewCounts = null; render(); };
  if (composeList) composeList.onchange = (e) => { state.composeListFilter = e.target.value; state.composePreviewCounts = null; render(); };
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
        notes: overlay.querySelector('#m-notes').value.trim() || null
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
