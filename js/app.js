// ============================================================================
//  Urgent Nursing Outreach Manager — Main App
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
  view: 'database',
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
  // Source filter
  sourceFilter: 'all',
  sourceCounts: {},
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
        <img src="data:image/webp;base64,${window.LOGO_B64}" alt="Urgent Nursing" />
        <h1>Outreach Manager</h1>
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

async function loadFilterOptions() {
  // Get distinct regions and countries (small, cacheable)
  const { data: rData } = await sb.from('contacts').select('region').not('region', 'is', null).neq('region', '');
  const { data: cData } = await sb.from('contacts').select('country').not('country', 'is', null).neq('country', '');
  state.regions = Array.from(new Set((rData || []).map(r => r.region))).sort();
  state.countries = Array.from(new Set((cData || []).map(r => r.country))).sort();
}


async function loadSourceCounts() {
  const [allRes, chRes, gpRes] = await Promise.all([
    sb.from('contacts').select('id', { count: 'exact', head: true }),
    sb.from('contacts').select('id', { count: 'exact', head: true })
      .ilike('notes', '%Ofsted Register%'),
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
    all:            allRes.count || 0,
    gp_surgery:     gpRes.count  || 0,
    children_homes: chRes.count  || 0,
  };
}

async function loadContactsPage() {
  state.loadingPage = true;
  state.selected = new Set();
  const start = (state.page - 1) * state.pageSize;
  const end = start + state.pageSize - 1;

  let query = sb.from('contacts_with_last_email').select('*', { count: 'exact' })
    .eq('status', state.subTab);

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
      .not('notes', 'ilike', '%Source: CAMHS%');
  } else if (sf !== 'all') {
    const SOURCE_TAG = {
      agency:          'Source: Agency Outreach',
      pharmacy:        'Source: Pharmacy Outreach',
      bms:             'Source: BMS Outreach',
      sterile:         'Source: Sterile Services',
      private_theatre: 'Source: Private Theatre',
      nhs_staffbank:   'Source: NHS Staff Bank',
      nhs_theatre:     'Source: NHS Theatre',
      camhs:           'Source: CAMHS',
    };
    if (SOURCE_TAG[sf]) query = query.ilike('notes', `%${SOURCE_TAG[sf]}%`);
  }
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

async function buildComposeQueueFromDb() {
  let query = sb.from('contacts').select('*').eq('status', state.composeListFilter);
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
  await Promise.all([loadStatusCounts(), loadSourceCounts(), loadTemplates(), loadFilterOptions()]);
  await loadContactsPage();
  render();
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
      <img src="data:image/webp;base64,${window.LOGO_B64}" alt="Urgent Nursing" />
      <h1>Outreach Manager</h1>
      <span class="badge">${state.counts.lead} Leads · ${state.counts.live} Live · ${state.counts.unsubscribed} Unsubs</span>
      <span class="user-pill">${esc(state.user.email)} <button id="sign-out-btn" title="Sign out">Sign out</button></span>
    </div>
    <div class="tabs">
      <div class="tab ${state.view === 'database' ? 'active' : ''}" data-view="database">Database</div>
      <div class="tab ${state.view === 'templates' ? 'active' : ''}" data-view="templates">Templates</div>
      <div class="tab ${state.view === 'compose' ? 'active' : ''}" data-view="compose">Compose</div>
      <div class="tab ${state.view === 'settings' ? 'active' : ''}" data-view="settings">Settings</div>
      <div class="tab ${state.view === 'import' ? 'active' : ''}" data-view="import">⬇ Import</div>
    </div>
    <div class="main" id="main">
      ${state.view === 'database' ? renderDatabase() :
        state.view === 'templates' ? renderTemplates() :
        state.view === 'compose' ? renderCompose() :
        state.view === 'import' ? renderImport() :
        renderSettings()}
    </div>
  `;
}

function renderDatabase() {
  const SOURCES = [
    { key: 'all',             label: 'All Sources',        live: true  },
    { key: 'gp_surgery',      label: 'GP Surgeries',       live: true  },
    { key: 'children_homes',  label: "Children's Homes",   live: true  },
    { key: 'agency',          label: 'Agency Outreach',    live: false },
    { key: 'pharmacy',        label: 'Pharmacy',           live: false },
    { key: 'bms',             label: 'BMS',                live: false },
    { key: 'sterile',         label: 'Sterile Services',   live: false },
    { key: 'private_theatre', label: 'Private Theatres',   live: false },
    { key: 'nhs_staffbank',   label: 'NHS Staff Banks',    live: false },
    { key: 'nhs_theatre',     label: 'NHS Theatres',       live: false },
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
      ${SOURCES.map(s => `
        <button class="source-tab${state.sourceFilter === s.key ? ' active' : ''}${!s.live ? ' soon' : ''}"
          data-source="${s.key}"${!s.live ? ' disabled title="Coming soon"' : ''}>
          ${esc(s.label)}
          ${s.live && state.sourceCounts[s.key] != null
            ? `<span class="source-count">${Number(state.sourceCounts[s.key]).toLocaleString()}</span>`
            : !s.live ? '<span class="source-soon">soon</span>' : ''}
        </button>
      `).join('')}
    </div>

    ${selN > 0 ? `
    <div class="batch-bar">
      <span class="batch-count">${selN} selected</span>
      <button class="btn small batch-btn" data-bulk="unsubscribe">⊘ Unsubscribe</button>
      <button class="btn small batch-btn" data-bulk="restore">↺ Restore to Lead</button>
      <button class="btn small batch-btn danger" data-bulk="delete">✕ Delete</button>
      <button class="btn small batch-btn secondary" data-bulk="clear">Clear</button>
    </div>` : ''}

    <div class="subtabs">
      <div class="subtab ${state.subTab === 'lead' ? 'active' : ''}" data-subtab="lead">Leads<span class="count">${state.counts.lead}</span></div>
      <div class="subtab ${state.subTab === 'live' ? 'active' : ''}" data-subtab="live">Live<span class="count">${state.counts.live}</span></div>
      <div class="subtab ${state.subTab === 'unsubscribed' ? 'active' : ''}" data-subtab="unsubscribed">Unsubscribes<span class="count">${state.counts.unsubscribed}</span></div>
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
            <th data-sort="org">Surgery / Org</th>
            <th data-sort="first_name">Contact</th>
            <th data-sort="job_title">Role</th>
            <th data-sort="email">Email</th>
            <th data-sort="town">Town</th>
            <th data-sort="region">Region</th>
            <th data-sort="last_emailed_at">Last Emailed</th>
            <th>Actions</th>
          </tr>
        </thead>
        <tbody>
          ${state.currentRows.map(c => `
            <tr class="${state.selected.has(c.id) ? 'row-selected' : ''}">
              <td style="width:36px;text-align:center">
                <input type="checkbox" class="row-cb" data-id="${c.id}" ${state.selected.has(c.id) ? 'checked' : ''} />
              </td>
              <td class="ellipsis" title="${esc(c.org)}">${esc(c.org)}</td>
              <td>${esc([c.title, c.first_name, c.last_name].filter(Boolean).join(' '))}</td>
              <td>${esc(c.job_title)}</td>
              <td class="ellipsis" title="${esc(c.email)}">${esc(c.email)}</td>
              <td>${esc(c.town)}</td>
              <td>${esc(c.region)}</td>
              <td>${c.last_emailed_at ? esc(c.last_emailed_at.slice(0, 10)) : '<span class="muted">—</span>'}</td>
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

function renderCompose() {
  if (state.composeMode === 'one-by-one' && state.composeQueue) return renderOneByOne();
  if (state.composeMode === 'csv' && state.composeQueue) return renderCsvExport();

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
          <label>From list</label>
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

    <div class="compose-step">
      <h3>4. Pick output mode</h3>
      <div class="stat-row">
        <button class="btn primary" id="start-one-by-one" ${!template || !previewMatch ? 'disabled' : ''}>
          📧 One-by-one Copy Mode
        </button>
        <button class="btn accent" id="start-csv" ${!template || !previewMatch ? 'disabled' : ''}>
          📊 Mail Merge CSV Export
        </button>
      </div>
      <div class="muted" style="margin-top:8px;">
        <strong>One-by-one</strong>: cycles through each contact, you copy & paste personalised emails into Outlook (safest for NHS).<br>
        <strong>CSV Export</strong>: downloads filtered list + email body for use with Word Mail Merge (faster for big sends).
      </div>
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
    { icon: '📋', title: 'Companies House — Pharmacy', sub: 'Superintendent pharmacist contacts from registered pharmacy businesses' },
    { icon: '🔬', title: 'NHS Directory — BMS', sub: 'Biomedical Scientists via NHS pathology lab directories' },
    { icon: '🏨', title: 'CQC Register — Private Theatres', sub: 'Theatre manager contacts from the CQC registered providers list' },
    { icon: '📡', title: 'NHS Staff Banks', sub: 'Bank manager contacts from NHS trust staff bank portals' },
  ];

  return `
    <div class="import-wrap">
      <h2 class="section-title">Import Contacts</h2>

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
      <p>Urgent Nursing Outreach Manager — Day Webster Group. Data lives in Supabase; access is restricted to authorised Day Webster Group email domains. Daily automated database backups run on the Supabase free tier (Dashboard → Database → Backups).</p>
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
      if (state.view === 'database') await loadContactsPage();
      if (state.view === 'compose') state.composePreviewCounts = null;
      if (state.view === 'import') state.importResult = null;
      render();
    };
  });

  document.querySelectorAll('.subtab').forEach(t => {
    t.onclick = async () => {
      state.subTab = t.dataset.subtab;
      state.page = 1;
      state.search = '';
      state.regionFilter = '';
      await loadContactsPage();
      render();
    };
  });

  // Source filter tabs
  document.querySelectorAll('.source-tab:not([disabled])').forEach(t => {
    t.onclick = async () => {
      state.sourceFilter = t.dataset.source;
      state.page = 1;
      state.search = '';
      state.regionFilter = '';
      await loadContactsPage();
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
  const runScrapeBtn = $('#run-scrape-btn');
  if (runScrapeBtn) runScrapeBtn.onclick = () => { if (!state.importRunning) runNHSScrape(); };

  // Batch action buttons
  document.querySelectorAll('[data-bulk]').forEach(btn => {
    btn.onclick = async () => {
      const action = btn.dataset.bulk;
      if (action === 'clear') { state.selected = new Set(); render(); return; }
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
