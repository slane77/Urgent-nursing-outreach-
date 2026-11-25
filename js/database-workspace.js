// Shared contact workspace. Sending remains in the existing reviewed campaign flow.
const DB_SOURCES=[
 ['all','All databases','Overview'],['hcp','Homecare Providers','Care partnerships'],
 ['ahp','NHS Jobs · England','NHS recruitment'],['nhs_scotland','NHS Scotland','NHS recruitment'],['hse','HSE · Ireland','NHS recruitment'],
 ['anp','Advanced nurse practitioners','NHS recruitment'],['enp','Emergency nurse practitioners','NHS recruitment'],
 ['gp_surgery','GP surgeries','Other databases'],['children_homes',"Children’s homes",'Other databases'],['care_home','Care homes','Other databases'],
 ['private_theatre','Theatres','Other databases'],['agency','Agency outreach','Other databases'],['foi','FOI · NHS trusts','Other databases']
];
const DB_SPECIALTIES=[['all','All specialties'],['physiotherapy','Physiotherapy'],['occupational_therapy','Occupational therapy'],['radiography','Radiography'],['speech_language','Speech & language'],['dietetics','Dietetics'],['podiatry','Podiatry'],['orthoptics','Orthoptics'],['art_therapy','Arts therapies'],['paramedic','Paramedic'],['prosthetics','Prosthetics'],['pharmacy','Pharmacy'],['biomedical_science','Biomedical science'],['sterile_services','Sterile services'],['mental_health','Mental health'],['camhs','CAMHS'],['operating_theatres','Theatres'],['audiology','Audiology'],['gp_surgery','GP surgeries']];
const DB_VIEW_KEYS=['sourceFilter','subTab','dbStage','search','regionFilter','countryFilter','ahpSpecialtyFilter','hcpAreaFilter','hcpAudienceFilter','hcpCommissioningFilter','hcpReadyOnly','dbOwnerFilter','dbBandFilter','recentImportPeriod','recentImportUncontactedOnly','sortKey','sortDir'];
function dbPreferences(){try{return JSON.parse(localStorage.getItem('outreach-db:'+state.user.id)||'{}');}catch{return {};}}
function saveDbPreferences(p){try{localStorage.setItem('outreach-db:'+state.user.id,JSON.stringify(p));return true;}catch{toast('Your browser could not save this view.','error');return false;}}
function dbOptions(options,value){return options.map(([k,l])=>`<option value="${esc(k)}" ${String(value??'')===String(k)?'selected':''}>${esc(l)}</option>`).join('');}
function dbName(c){return [c.first_name,c.last_name].filter(Boolean).join(' ')||'Shared inbox';}
function dbUserName(id){return !id?'Unassigned':(state.dbDirectory||[]).find(p=>p.user_id===id)?.full_name||'Team member';}
function dbDate(s){return s?new Date(s.length===10?s+'T12:00:00Z':s).toLocaleDateString('en-GB',{timeZone:'Europe/London',day:'numeric',month:'short',year:'numeric'}):'—';}
function dbSafeUrl(s){try{const u=new URL(s);return ['http:','https:'].includes(u.protocol)?u.href:'';}catch{return '';}}
function dbIsJobs(){return ['ahp','nhs_scotland','hse','anp','enp'].includes(state.sourceFilter);}
function dbStatus(c){return c.status==='bounced'?'Bounced':c.status==='unsubscribed'?'Unsubscribed':c.status==='live'?'Live':({new:'Uncontacted',contacted:'Contacted',responded:'Responded',meeting:'Meeting'})[effectiveContactStage(c)]||'Lead';}
function dbService(c){return state.sourceFilter==='hcp'?({complex_care:'Complex care',mental_health:'Mental health',both:'Complex care & mental health',needs_review:'General HCP',other:'Other'})[c.hcp_pathway]||'General HCP':dbIsJobs()?extractSpecialty(c.notes).replaceAll('_',' '):(c.care_group&&c.care_group!==c.org?c.care_group:c.job_title)||'—';}
function dbOwnerOptions(includeAll=true){return [...(includeAll?[['all','Team view'],['mine','My contacts'],['unassigned','Unassigned']]:[['','Unassigned']]),...(state.dbDirectory||[]).filter(p=>!p.activity_archived).map(p=>[p.user_id,p.full_name])];}
async function loadDbDirectory(){
 if(!state.user||state.dbDirectoryFor===state.user.id)return;
 const user=state.user.id;
 try{const {data,error}=await sb.rpc('outreach_team_directory');if(state.user?.id!==user)return;if(error)throw error;state.dbDirectory=data||[];state.dbDirectoryFor=user;}
 catch{state.dbDirectory=[];state.dbDirectoryError=true;}
}
function dbSavedFilters(){return Object.fromEntries(DB_VIEW_KEYS.map(k=>[k,state[k]]));}
function dbAppliedFilters(){
 const result=[];
 if(state.search)result.push(['search','Search: '+state.search]);
 if(state.regionFilter)result.push(['regionFilter','Area: '+state.regionFilter]);
 if(state.countryFilter)result.push(['countryFilter',state.countryFilter]);
 if(state.dbOwnerFilter&&state.dbOwnerFilter!=='all')result.push(['dbOwnerFilter',state.dbOwnerFilter==='mine'?'My contacts':dbUserName(state.dbOwnerFilter==='unassigned'?null:state.dbOwnerFilter)]);
 if(state.dbBandFilter)result.push(['dbBandFilter','Band: '+state.dbBandFilter]);
 if(state.ahpSpecialtyFilter&&state.ahpSpecialtyFilter!=='all'&&dbIsJobs())result.push(['ahpSpecialtyFilter',DB_SPECIALTIES.find(s=>s[0]===state.ahpSpecialtyFilter)?.[1]||state.ahpSpecialtyFilter]);
 if(state.sourceFilter==='hcp'){
  if(state.hcpAreaFilter!=='all')result.push(['hcpAreaFilter',HCP_AREAS.find(a=>a.k===state.hcpAreaFilter)?.l||state.hcpAreaFilter]);
  if(state.hcpCommissioningFilter!=='all')result.push(['hcpCommissioningFilter',state.hcpCommissioningFilter]);
  if(state.hcpAudienceFilter!=='all')result.push(['hcpAudienceFilter',[...HCP_SEGMENT_OPTIONS,...HCP_CASE_AUDIENCES,...HCP_AUDIENCES,{k:'cm_all',l:'Case managers'}].find(a=>a.k===state.hcpAudienceFilter)?.l||state.hcpAudienceFilter]);
 }
 return result;
}
function renderContactWorkspace(){
 const hcp=state.sourceFilter==='hcp',jobs=dbIsJobs(),intake=isRecentImportView(state.dbStage);
 const prefs=dbPreferences(),sources=DB_SOURCES.filter(s=>s[0]!=='hcp'||hcpTabVisible());
 const sourceLabel=sources.find(s=>s[0]===state.sourceFilter)?.[1]||'Contacts';
 const n=state.selected.size,total=state.totalRows,pages=Math.max(1,Math.ceil(total/state.pageSize)),canSelect=!intake&&!state.loadingPage&&canSelectDatabasePage();
 
 const activeList=intake?'recent':state.subTab==='bounced'?'bounced':state.subTab==='unsubscribed'?'unsubscribed':state.subTab==='live'?'live':['cqc_hold','procurement_hold'].includes(state.hcpAudienceFilter)&&hcp?state.hcpAudienceFilter:state.dbStage!=='all'?state.dbStage:state.hcpReadyOnly?'ready':'all';
 const filters=dbAppliedFilters();
 const visibleRows=state.loadingPage?[]:state.currentRows;
 return `<section class="db-workspace">
  <header class="db-heading"><div><span class="db-eyebrow">CONTACT WORKSPACE</span><h2>${esc(sourceLabel)}</h2><p>${hcp?'Build referral relationships and prepare relevant outreach.':jobs?'Turn recruitment activity into conversations with hiring teams.':'Find the right people and keep the next conversation moving.'}</p></div><button class="btn primary" id="add-contact-btn">+ Add contact</button></header>
  <div class="db-switchbar"><div class="db-field db-source-field"><label for="db-source-picker">Database</label><select id="db-source-picker" class="select">${[...new Set(sources.map(s=>s[2]))].map(g=>`<optgroup label="${esc(g)}">${dbOptions(sources.filter(s=>s[2]===g).map(s=>[s[0],s[1]+' · '+Number(state.sourceCounts[s[0]]||0).toLocaleString()]),state.sourceFilter)}</optgroup>`).join('')}</select></div><button class="btn" id="db-pin-source" aria-label="${prefs.pins?.includes(state.sourceFilter)?'Unpin':'Pin'} this database">${prefs.pins?.includes(state.sourceFilter)?'★ Pinned':'☆ Pin'}</button><div class="db-field"><label for="db-owner-filter">Contact owner</label><select class="select" id="db-owner-filter">${dbOptions(dbOwnerOptions(),state.dbOwnerFilter||'all')}</select></div><div class="db-field"><label for="db-saved-view">My saved views</label><select class="select" id="db-saved-view"><option value="">Choose a saved view</option>${(prefs.views||[]).map((v,i)=>`<option value="${i}">${esc(v.name)}</option>`).join('')}</select></div><button class="btn" id="db-save-view">Save view</button></div>
  ${prefs.pins?.length?`<div class="db-pins">${sources.filter(s=>prefs.pins.includes(s[0])).map(s=>`<button class="db-link" data-db-source="${s[0]}">${esc(s[1])}</button>`).join('')}</div>`:''}
  ${state.dbSavingView?'<form id="db-save-view-form" class="db-save-form"><label for="db-view-name">View name</label><input id="db-view-name" maxlength="60" required placeholder="e.g. London case managers" /><button class="btn primary" type="submit">Save on this browser</button><button class="btn" type="button" id="db-save-view-cancel">Cancel</button></form>':''}
  <nav class="db-worklists" aria-label="Contact work lists">${[['all',hcp?'Leads & relationships':'Leads'],['new','Uncontacted'],['recent','Recently added'],...(hcp?[['ready','Ready for outreach']]:[]),['followup','Follow-ups due'],['responded','Responded'],['meeting','Meetings']].map(([k,l])=>`<button class="${activeList===k?'active':''}" data-db-work="${k}" ${activeList===k?'aria-current="page"':''}>${l}</button>`).join('')}<label class="db-more-list">Other lists<select id="db-other-list" aria-label="Other contact lists"><option value="">Choose…</option>${dbOptions([['contacted','Contacted'],['lead','Leads'],['live','Live relationships'],['bounced','Bounced emails'],['unsubscribed','Unsubscribed'],...(hcp?[['cqc_hold','CQC re-engagement'],['procurement_hold','Framework / onboarding']]:[])],activeList)}</select></label></nav>
  <div class="db-searchbar"><input class="search" id="search-input" aria-label="Search contacts" placeholder="Search contacts, organisations, emails or locations…" value="${esc(state.search)}" />
   ${hcp?`<select class="select" id="db-main-audience" aria-label="HCP audience">${dbOptions([['all','All HCP leads'],['complex_care','Complex-care commissioning'],['mental_health','Mental-health commissioning'],['cm_all','Case management']],['complex_care','mental_health','cm_all'].includes(state.hcpAudienceFilter)?state.hcpAudienceFilter:'all')}</select>`:jobs?`<select class="select" id="db-specialty" aria-label="Specialty">${dbOptions(DB_SPECIALTIES,state.ahpSpecialtyFilter)}</select>`:''}
   <button class="btn" id="db-more-filters" aria-expanded="${!!state.dbMoreFilters}">Filters${filters.length?' · '+filters.length:''}</button><button class="db-link" id="db-clear-filters">Clear all</button>
  </div>
  ${intake?`<div class="db-intake"><label for="recent-import-period">Added</label><select class="select" id="recent-import-period">${dbOptions([['today','Today'],['yesterday','Yesterday'],['7','Last 7 days'],['14','Last 14 days'],['30','Last 30 days']],state.dbStage==='added_today'?'today':state.recentImportPeriod||'7')}</select><label><input type="checkbox" id="recent-import-uncontacted" ${state.recentImportUncontactedOnly?'checked':''} /> Uncontacted only</label><span>Includes all statuses. Choose Leads to prepare outreach.</span></div>`:''}
  ${state.dbMoreFilters?`<div class="db-filter-panel">
   <div class="db-field"><label for="region-filter">Recorded area / coverage</label><input id="region-filter" list="db-region-options" placeholder="Type to find an area…" value="${esc(state.regionFilter)}" /><datalist id="db-region-options">${state.regions.map(r=>`<option value="${esc(r)}"></option>`).join('')}</datalist><small>Headquarters and coverage are retained as supplied.</small></div>
   <div class="db-field"><label for="country-filter">Country</label><select class="select" id="country-filter">${dbOptions([['','All countries'],...state.countries.map(r=>[r,r])],state.countryFilter)}</select></div>
   ${jobs?`<div class="db-field"><label for="db-band-filter">Recorded band</label><input id="db-band-filter" placeholder="e.g. 6 or 7+" value="${esc(state.dbBandFilter||'')}" /></div>`:''}
   ${hcp?`<div class="db-field"><label for="db-team-type">Organisation type</label><select class="select" id="db-team-type">${dbOptions([['all','All organisation types'],...HCP_AREAS.map(a=>[a.k,a.l])],state.hcpAreaFilter)}</select></div><div class="db-field"><label for="db-hcp-commissioning">Commissioning patch</label><select class="select" id="db-hcp-commissioning">${dbOptions([['all','All commissioning patches'],...HCP_COMMISSIONING_AREAS.map(a=>[a,a])],state.hcpCommissioningFilter)}</select></div><div class="db-field"><label for="db-hcp-audience">Specific service / previous campaign</label><select class="select" id="db-hcp-audience">${dbOptions([['all','All HCP leads'],...HCP_SEGMENT_OPTIONS.map(a=>[a.k,a.l]),['cm_all','All case managers'],...HCP_CASE_AUDIENCES.map(a=>[a.k,a.l]),...HCP_AUDIENCES.map(a=>[a.k,a.l])],state.hcpAudienceFilter)}</select></div>`:''}
  </div>`:''}
  ${filters.length?`<div class="db-filter-chips">${filters.map(([k,l])=>`<button data-db-clear="${k}" title="Remove filter">${esc(l)} <span aria-hidden="true">×</span></button>`).join('')}</div>`:''}
  <div class="db-results"><span>${state.loadingPage?'Loading contacts…':`${total.toLocaleString()} matching contacts${total?` · showing ${(state.page-1)*state.pageSize+1}–${Math.min(state.page*state.pageSize,total)}`:''}`}</span><label>Sort <select id="db-sort" aria-label="Sort contacts">${dbOptions([['org:asc','Organisation A–Z'],['created_at:desc','Newest first'],['last_emailed_at:desc','Recently contacted'],['follow_up_date:asc','Follow-up date']],state.sortKey+':'+state.sortDir)}</select></label></div>
  ${state.contactsError?`<p role="alert" class="db-error">Contacts could not be loaded: ${esc(state.contactsError)}</p>`:''}
  ${n?`<div class="db-bulk" role="region" aria-label="Selected contacts"><strong>${n} selected</strong>${canSelect&&['lead','live','eligible'].includes(state.subTab)?`<button class="btn primary" data-bulk="send-compose">Prepare email · ${n}</button>`:''}<select id="db-bulk-owner" aria-label="Assign selected contacts"><option value="">Assign owner…</option>${dbOptions([['unassigned','Unassigned'],...dbOwnerOptions(false).filter(([k])=>k)],'')}</select><select id="db-bulk-stage" aria-label="Update selected contacts"><option value="">Update status…</option>${dbOptions([['stage-responded','Responded'],['stage-meeting','Meeting'],['move-to-live','Live relationship'],['unsubscribe','Unsubscribe']], '')}</select><button class="db-link" data-bulk="clear">Clear selection</button></div>`:''}
  <div class="db-table-wrap"><table class="table db-table ${intake?'db-intake-table':''}"><thead><tr><th class="db-check">${canSelect?'<input type="checkbox" id="select-all-cb" aria-label="Select all matching contacts across all pages" '+(state.currentRows.length&&state.currentRows.every(c=>state.selected.has(c.id))?'checked':'')+' />':intake?'Status':''}</th><th>Contact / organisation</th><th>${jobs?'Vacancy / specialty':'Service / audience'}</th><th>Area</th><th>Owner</th><th>Latest activity</th><th>Next action</th></tr></thead><tbody>${visibleRows.map(c=>`<tr class="${state.selected.has(c.id)?'row-selected':''}"><td class="db-check">${canSelect?`<input type="checkbox" class="row-cb" data-id="${esc(c.id)}" aria-label="Select ${esc(dbName(c))}" ${state.selected.has(c.id)?'checked':''} />`:intake?esc(c.status)+' / '+esc(effectiveContactStage(c)):''}</td><td><button class="db-contact-link" data-db-contact="${esc(c.id)}">${esc(dbName(c))}</button><strong class="db-org">${esc(c.org||'Organisation not recorded')}</strong><span class="db-secondary" title="${esc(c.email||'')}">${esc(c.email||'No email recorded')}</span></td><td><span class="db-primary">${esc(jobs?c.vacancy_title||c.job_title||'Vacancy not recorded':dbService(c))}</span><span class="db-secondary">${esc(jobs?dbService(c)+(c.band_requested?' · Band '+c.band_requested:''):c.group_name?.replace(/^HCP - /,'')||(c.job_title!==dbService(c)?c.job_title:'')||'')}</span>${hcp&&['cqc_hold','procurement_hold','not_relevant'].includes(c.hcp_outreach_status)?`<span class="db-status db-hold">${esc(HCP_READINESS_LABELS[c.hcp_outreach_status])}</span>`:''}</td><td>${esc(hcp&&c.care_group?c.care_group:c.town||c.region||'—')}<span class="db-secondary">${esc(c.country||'')}</span></td><td>${esc(dbUserName(c.owner_user_id))}</td><td><span class="db-status ${['bounced','unsubscribed'].includes(c.status)?'db-hold':''}">${esc(dbStatus(c))}</span><span class="db-secondary">${c.last_recorded_send_at?`Sent ${esc(dbDate(c.last_recorded_send_at))}<br>${c.last_sent_by?esc(dbUserName(c.last_sent_by)):'Sender not recorded'}`:'No recorded send'}</span></td><td>${c.follow_up_date?`<span class="db-secondary">Follow up ${renderFollowUpDate(c.follow_up_date)}</span>`:''}<button class="db-link" data-db-contact="${esc(c.id)}">Open contact →</button></td></tr>`).join('')||'<tr><td colspan="7" class="db-empty">'+(state.loadingPage?'Loading…':'No contacts match this view. Try clearing filters or choosing Team view.')+'</td></tr>'}</tbody></table></div>
  <footer class="db-footer"><div>${canSelect?`<button class="btn" id="db-select-matching" ${!total?'disabled':''}>Select all matching · ${total.toLocaleString()}</button>`:''}${!canSelect&&!intake?'<span>Choose an assigned database to select recipients.</span>':''}</div><span>Page ${state.page} of ${pages}</span><div><button class="page-btn btn" data-page="${state.page-1}" ${state.page===1?'disabled':''}>Previous</button><button class="page-btn btn" data-page="${state.page+1}" ${state.page>=pages?'disabled':''}>Next</button></div></footer>
  ${renderDbDrawer()}
 </section>`;
}

let dbDrawerRequest=0;
async function openDbContact(id){
 const c=state.currentRows.find(r=>r.id===id);if(!c)return;
 const request=++dbDrawerRequest,user=state.user.id;
 state.dbDrawer={contact:{...c},loading:true};render();document.getElementById('db-close-contact')?.focus();
 try{
  let related=[c];
  if(c.email&&!c.email_pending){const {data,error}=await sb.from('contacts').select('id,org,first_name,last_name,vacancy_title,job_title,source_url,created_at,status').ilike('email',c.email.replace(/[\\%_]/g,'\\$&')).order('created_at',{ascending:false}).limit(100);if(error)throw error;related=data||[c];}
  const {data,error}=await sb.from('email_sends').select('id,contact_id,sent_at,status,sent_by,template_id').in('contact_id',[...new Set([c.id,...related.map(r=>r.id)])]).order('sent_at',{ascending:false}).limit(50);if(error)throw error;
  if(request!==dbDrawerRequest||state.user?.id!==user||state.dbDrawer?.contact.id!==id)return;
  state.dbDrawer={contact:{...c},related,sends:data||[],loading:false};render();document.getElementById('db-close-contact')?.focus();
 }catch(e){if(request!==dbDrawerRequest||state.user?.id!==user)return;state.dbDrawer={contact:{...c},loading:false,error:e.message};render();}
}
function renderDbDrawer(){
 const d=state.dbDrawer;if(!d)return '';const c=d.contact;
 const owners=dbOwnerOptions(false);
 if(c.owner_user_id&&!owners.some(([k])=>k===c.owner_user_id))owners.push([c.owner_user_id,dbUserName(c.owner_user_id)+' (former team member)']);
 return `<div class="db-drawer-backdrop"><aside class="db-drawer" role="dialog" aria-modal="true" aria-labelledby="db-contact-title"><header><div><span class="db-eyebrow">CONTACT DETAILS</span><h2 id="db-contact-title">${esc(dbName(c))}</h2><p>${esc(c.org||'')}</p></div><button class="btn" id="db-close-contact" aria-label="Close contact">×</button></header>
 <div class="db-drawer-body"><section><div class="db-detail-grid">${[['Email',c.email],['Phone',c.phone],['Role',c.job_title],['Location',[c.add1,c.add2,c.town,c.postcode].filter(Boolean).join(', ')],['Recorded coverage',c.region],['Commissioning patch / group',c.care_group]].map(([k,v])=>`<div><span>${k}</span><strong>${esc(v||'—')}</strong></div>`).join('')}</div><button class="btn" id="db-edit-contact">Edit contact details</button></section>
 <form id="db-contact-form"><h3>Relationship & next step</h3><div class="db-detail-grid"><label>Owner<select class="select" id="db-contact-owner">${dbOptions(owners,c.owner_user_id||'')}</select></label><label>Stage<select class="select" id="db-contact-stage">${dbOptions([['new','Uncontacted'],['contacted','Contacted'],['responded','Responded'],['meeting','Meeting'],['live','Live']],c.stage||'new')}</select></label><label>Follow-up date<input type="date" id="db-contact-followup" value="${esc(c.follow_up_date||'')}" /></label></div><label>Team notes<textarea id="db-contact-notes" rows="5">${esc(c.contact_notes||'')}</textarea></label><button class="btn primary" type="submit" ${d.saving?'disabled':''}>${d.saving?'Saving…':'Save changes'}</button><p class="db-secondary">Contact status: ${esc(dbStatus(c))}. Saving notes does not release an unsubscribe, bounce or hold.</p></form>
 ${c.hcp_qualification_notes?`<section><h3>Background / requirements</h3><p class="db-notes">${esc(c.hcp_qualification_notes)}</p></section>`:''}
 <section><h3>Vacancies & linked records</h3>${d.loading?'<p>Loading linked records…</p>':(d.related||[c]).map(r=>{const u=dbSafeUrl(r.source_url);return `<article class="db-history"><strong>${esc(r.vacancy_title||r.job_title||r.org||'Contact record')}</strong><span>${esc(r.org||'')} · ${esc(dbDate(r.created_at))}</span>${u?`<a href="${esc(u)}" target="_blank" rel="noopener">View original source ↗</a>`:''}</article>`;}).join('')}<p class="db-secondary">Up to 100 records with this exact email address. Records remain separate.</p></section>
 <section><h3>Email activity</h3>${d.error?`<p role="alert">Could not load activity: ${esc(d.error)}</p>`:d.loading?'<p>Loading activity…</p>':(d.sends||[]).map(s=>`<article class="db-history"><strong>${esc(s.status==='sent'?'Recorded as sent':s.status)}</strong><span>${esc(dbDate(s.sent_at))} · ${s.sent_by?esc(dbUserName(s.sent_by)):'Sender not recorded'}</span><span>${esc(state.templates.find(t=>t.id===s.template_id)?.name||'Template not recorded')}</span></article>`).join('')||'<p>No email activity recorded.</p>'}<p class="db-secondary">Latest 50 app records across linked contacts. Manual send records are not delivery confirmations.</p></section>
 <details><summary>Original source notes</summary><p class="db-notes">${esc(c.notes||'No source notes')}</p></details>
 </div></aside></div>`;
}
async function dbReload(){state.page=1;state.dbDrawer=null;await loadContactsPage();render();}
async function dbWorkList(key){
 state.dbStage='all';state.hcpReadyOnly=false;state.subTab=state.sourceFilter==='hcp'?'eligible':'lead';
 if(['cqc_hold','procurement_hold'].includes(state.hcpAudienceFilter))state.hcpAudienceFilter='all';
 if(['lead','live','bounced','unsubscribed'].includes(key))state.subTab=key;
 else if(key==='ready')state.hcpReadyOnly=true;
 else if(['cqc_hold','procurement_hold'].includes(key)){state.hcpAudienceFilter=key;state.hcpAreaFilter='all';}
 else if(key==='recent'){state.dbStage='recent';state.subTab='all';state.sortKey='created_at';state.sortDir='desc';}
 else if(key!=='all')state.dbStage=key;
 await dbReload();
}
function bindContactWorkspace(){
 if(state.view!=='database')return;
 const on=(id,event,fn)=>{const e=document.getElementById(id);if(e)e[event]=fn;};
 on('db-source-picker','onchange',e=>changeDatabaseSource(e.target.value));
 document.querySelectorAll('[data-db-source]').forEach(e=>e.onclick=()=>changeDatabaseSource(e.dataset.dbSource));
 document.querySelectorAll('[data-db-work]').forEach(e=>e.onclick=()=>dbWorkList(e.dataset.dbWork));
 on('db-other-list','onchange',e=>{if(e.target.value)dbWorkList(e.target.value);});
 on('db-owner-filter','onchange',async e=>{state.dbOwnerFilter=e.target.value;await dbReload();});
 on('db-specialty','onchange',async e=>{state.ahpSpecialtyFilter=e.target.value;await dbReload();});
 on('db-team-type','onchange',async e=>{state.hcpAreaFilter=e.target.value;await dbReload();});
 on('db-band-filter','onchange',async e=>{state.dbBandFilter=e.target.value.trim();await dbReload();});
 on('db-main-audience','onchange',async e=>{state.hcpAudienceFilter=e.target.value;state.hcpAreaFilter='all';state.hcpReadyOnly=false;await dbReload();});
 on('db-more-filters','onclick',()=>{state.dbMoreFilters=!state.dbMoreFilters;render();});
 on('db-clear-filters','onclick',async()=>{Object.assign(state,{search:'',regionFilter:'',countryFilter:'',dbOwnerFilter:'all',dbBandFilter:'',ahpSpecialtyFilter:'all',hcpAreaFilter:'all',hcpAudienceFilter:'all',hcpCommissioningFilter:'all',hcpReadyOnly:false});await dbWorkList('all');});
 document.querySelectorAll('[data-db-clear]').forEach(e=>e.onclick=async()=>{const k=e.dataset.dbClear;state[k]=['dbOwnerFilter','ahpSpecialtyFilter','hcpAreaFilter','hcpAudienceFilter','hcpCommissioningFilter'].includes(k)?'all':'';await dbReload();});
 on('db-sort','onchange',async e=>{[state.sortKey,state.sortDir]=e.target.value.split(':');await dbReload();});
 on('db-pin-source','onclick',()=>{const p=dbPreferences();p.pins=(p.pins||[]).includes(state.sourceFilter)?p.pins.filter(x=>x!==state.sourceFilter):[...(p.pins||[]),state.sourceFilter];saveDbPreferences(p);render();});
 on('db-save-view','onclick',()=>{state.dbSavingView=true;render();document.getElementById('db-view-name')?.focus();});
 on('db-save-view-cancel','onclick',()=>{state.dbSavingView=false;render();});
 on('db-save-view-form','onsubmit',e=>{e.preventDefault();const name=document.getElementById('db-view-name').value.trim();if(!name)return;const p=dbPreferences();p.views=[...(p.views||[]).filter(v=>v.name!==name),{name,filters:dbSavedFilters()}].slice(-20);if(saveDbPreferences(p)){state.dbSavingView=false;render();toast('View saved for your account on this browser.');}});
 on('db-saved-view','onchange',async e=>{if(e.target.value==='')return;const v=dbPreferences().views?.[Number(e.target.value)];if(!v)return;for(const k of DB_VIEW_KEYS)if(k in v.filters)state[k]=v.filters[k];state.dbMoreFilters=false;await Promise.all([loadSourceStatusCounts(),dbReload()]);});
 document.querySelectorAll('[data-db-contact]').forEach(e=>e.onclick=()=>openDbContact(e.dataset.dbContact));
 on('db-close-contact','onclick',()=>{const id=state.dbDrawer?.contact.id;++dbDrawerRequest;state.dbDrawer=null;render();document.querySelector('[data-db-contact="'+id+'"]')?.focus();});
 on('db-edit-contact','onclick',()=>{const c=state.dbDrawer.contact;state.dbDrawer=null;render();state.modal={type:'edit-contact',contact:{...c}};renderModal();});
 on('db-contact-form','onsubmit',async e=>{
  e.preventDefault();const d=state.dbDrawer;if(d.saving)return;
  const patch={owner_user_id:document.getElementById('db-contact-owner').value||null,stage:document.getElementById('db-contact-stage').value,follow_up_date:document.getElementById('db-contact-followup').value||null,contact_notes:document.getElementById('db-contact-notes').value};
  d.saving=true;document.querySelector('#db-contact-form button[type="submit"]').disabled=true;
  const {data,error}=await updateContactById(d.contact.id,patch);d.saving=false;
  if(state.dbDrawer!==d)return;if(error){toast('Save failed: '+error.message,'error');render();return;}
  Object.assign(d.contact,data);await loadContactsPage();render();toast('Contact updated.');
 });
 on('db-bulk-owner','onchange',async e=>{
  const owner=e.target.value;if(!owner)return;const ids=[...state.selected];e.target.disabled=true;
  const {data,error}=await sb.from('contacts').update({owner_user_id:owner==='unassigned'?null:owner}).in('id',ids).select('id');
  if(error){toast('Assignment failed: '+error.message,'error');e.target.disabled=false;return;}
  await dbReload();toast(`${data?.length||0} contacts assigned.`);
 });
 on('db-bulk-stage','onchange',e=>{const action=e.target.value;if(!action)return;if(action==='unsubscribe'){state.modal={type:'confirm',title:`Unsubscribe ${state.selected.size} contacts?`,message:'These contacts will be excluded from outreach.',confirmText:'Unsubscribe',onConfirm:()=>bulkAction('unsubscribe')};renderModal();}else bulkAction(action);});
 const drawer=document.querySelector('.db-drawer');
 if(drawer)drawer.onkeydown=e=>{if(e.key==='Escape'){document.getElementById('db-close-contact').click();return;}if(e.key==='Tab'){const items=[...drawer.querySelectorAll('button,a[href],input,select,textarea,summary')].filter(x=>!x.disabled&&x.getClientRects().length);const first=items[0],last=items[items.length-1];if(e.shiftKey&&document.activeElement===first){last.focus();e.preventDefault();}else if(!e.shiftKey&&document.activeElement===last){first.focus();e.preventDefault();}}};
}
