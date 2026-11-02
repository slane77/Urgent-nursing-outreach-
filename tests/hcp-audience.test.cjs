const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const path=require('node:path');
const app=fs.readFileSync(path.join(__dirname,'../js/app.js'),'utf8');
function section(start,end){const i=app.indexOf(start);assert.ok(i>=0,start);const j=app.indexOf(end,i);assert.ok(j>i,end);return app.slice(i,j);}
const helpers=section('const HCP_AREAS =','const MODAL_SOURCE_OPTIONS =');
const priority="HCP - Priority children's complex care";
const development="HCP - Children's commissioning development";
function fixtures(){return [
 {id:'lead',email:'lead@example.invalid',status:'lead',group_name:priority,care_group:'Bromley'},
 {id:'live',email:'live@example.invalid',status:'live',group_name:priority,care_group:'Bromley'},
 {id:'other-area',email:'area@example.invalid',status:'live',group_name:priority,care_group:'Lewisham'},
 {id:'development',email:'dev@example.invalid',status:'lead',group_name:development,care_group:'Bromley'},
 {id:'unreviewed',email:'raw@example.invalid',status:'lead',group_name:'',care_group:'Bromley'},
 {id:'unsubscribed',email:'unsub@example.invalid',status:'unsubscribed',group_name:priority,care_group:'Bromley'},
 {id:'bounced',email:'bounce@example.invalid',status:'bounced',group_name:priority,care_group:'Bromley'},
].map(r=>({...r,notes:'Source: HCP Complex Care',department:'icb',stage:'new',updated_at:'2026-11-02',org:r.id}));}
function harness(){
 const rows=fixtures();const queries=[];
 const state={subTab:'eligible',dbStage:'all',sourceFilter:'hcp',page:1,pageSize:50,sortKey:'org',sortDir:'asc',selected:new Set(),hcpAreaFilter:'all',hcpAudienceFilter:'priority',hcpCommissioningFilter:'all',composeSourceFilter:'hcp',composeListFilter:'eligible',composeAreaFilter:'all',composeHcpAudienceFilter:'priority',composeHcpCommissioningFilter:'all',composeBatchSize:250,composeUncontactedOnly:false,templates:[],counts:{lead:5,live:2},regions:[],countries:[]};
 const sb={from(table){const predicates=[];const calls=[];let range=[0,9999];const q={
  select(){return this;},eq(k,v){calls.push(['eq',k,v]);predicates.push(r=>r[k]===v);return this;},
  in(k,values){calls.push(['in',k,values]);predicates.push(r=>values.includes(r[k]));return this;},
  is(k,v){predicates.push(r=>v===null?r[k]==null:r[k]===v);return this;},
  ilike(k,v){const token=v.replaceAll('%','').toLowerCase();predicates.push(r=>(r[k]||'').toLowerCase().includes(token));return this;},
  order(){return this;},range(a,b){range=[a,b];return this;},limit(n){range=[0,n-1];return this;},
  then(resolve,reject){queries.push({table,calls});const filtered=rows.filter(r=>predicates.every(f=>f(r)));return Promise.resolve({data:filtered.slice(range[0],range[1]+1),count:filtered.length}).then(resolve,reject);}
 };return q;}};
 const ctx=vm.createContext({state,sb,console,esc:v=>String(v??'').replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('"','&quot;'),canSendContactSource:()=>true,loadSourceStatusCounts:async()=>{},render(){},toast(message){throw Error(message);}});
 vm.runInContext(helpers+section('function applyComposeSourceFilter(', '// Sub-audience filter for Compose:')+section('function londonDayStart(','async function loadTemplates()')+section('function applyComposeSubFilter(','// ============================================================================\n//  RENDER')+section('async function buildAllComposeContactsFromDb()','async function sendSelectedViaBrevo()')+section('function renderCompose()','function renderBrevoSend()'),ctx);
 return {ctx,state,rows,queries};
}
test('HCP priority audience includes Leads and Live and excludes suppressed, development and unreviewed contacts',async()=>{
 const {ctx,state}=harness();await ctx.loadContactsPage();assert.deepEqual(Array.from(state.currentRows,r=>r.id).sort(),['lead','live','other-area']);
});
test('commissioning area narrows the same audience independently of organisation type',async()=>{
 const {ctx,state}=harness();state.hcpCommissioningFilter='Bromley';await ctx.loadContactsPage();assert.deepEqual(Array.from(state.currentRows,r=>r.id).sort(),['lead','live']);
});
test('database, preview, batch and complete export agree on recipients',async()=>{
 const {ctx,state}=harness();state.hcpCommissioningFilter='Bromley';state.composeHcpCommissioningFilter='Bromley';await ctx.loadContactsPage();
 const expected=Array.from(state.currentRows,r=>r.id).sort();assert.equal((await ctx.previewComposeCounts()).matching,expected.length);
 assert.deepEqual(Array.from(await ctx.buildComposeQueueFromDb(),r=>r.id).sort(),expected);
 assert.deepEqual(Array.from(await ctx.buildAllComposeContactsFromDb(),r=>r.id).sort(),expected);
});
test('reviewed expansion is deliberate and still excludes unreviewed and suppressed contacts',async()=>{
 const {ctx,state}=harness();state.hcpAudienceFilter='reviewed';await ctx.loadContactsPage();assert.deepEqual(Array.from(state.currentRows,r=>r.id).sort(),['development','lead','live','other-area']);
});
test('switching to HCP defaults to priority contacts across Leads and Live',async()=>{
 const {ctx,state}=harness();state.subTab='lead';state.sourceFilter='gp_surgery';await ctx.changeDatabaseSource('hcp');assert.equal(state.subTab,'eligible');assert.equal(state.hcpAudienceFilter,'priority');assert.equal(state.currentRows.length,3);
 await ctx.openDatabaseView('all','hcp');assert.equal(state.subTab,'eligible');assert.equal(state.currentRows.length,3);
});
test('explicit Leads-only selection remains supported',async()=>{
 const {ctx,state}=harness();state.subTab='lead';state.composeListFilter='lead';await ctx.loadContactsPage();assert.deepEqual(Array.from(state.currentRows,r=>r.id),['lead']);assert.equal((await ctx.previewComposeCounts()).matching,1);
});
test('non-HCP audiences retain a single status even with a stale combined value',()=>{
 const {ctx}=harness();const calls=[];const q={eq:(...a)=>calls.push(a),in:()=>assert.fail('Combined status must be HCP only')};ctx.applyContactStatusFilter(q,'eligible','gp_surgery');assert.deepEqual(calls,[['status','lead']]);
});
test('Compose renders accessible referral and commissioning controls only for HCP',()=>{
 const {ctx,state}=harness();let html=ctx.renderCompose();assert.match(html,/id="compose-hcp-audience"/);assert.match(html,/for="compose-hcp-audience"/);assert.match(html,/id="compose-hcp-commissioning"/);assert.match(html,/value="eligible" selected/);assert.match(html,/Review named contacts and shared inboxes/);
 state.composeSourceFilter='gp_surgery';state.composeListFilter='lead';html=ctx.renderCompose();assert.doesNotMatch(html,/id="compose-hcp-audience"/);assert.doesNotMatch(html,/value="eligible"/);
});

test('MH home-discharge audience includes specialist and warm introduction routes while excluding placements and suppressed records',async()=>{
 const {ctx,state,rows}=harness();
 const add=(id,group,role,status='lead')=>rows.push({...rows[0],id,email:id+'@example.invalid',group_name:group,status,contact_notes:'MH home-discharge audience: '+role+' | Own/family-home scope only'});
 add('mh-adult','HCP - MH discharge home - adult pathways','mh_adult');
 add('mh-child','HCP - MH discharge home - CYP pathways','mh_cyp','live');
 add('mh-warm',priority,'mh_warm','live');
 add('mh-clinical','HCP - MH discharge home - clinical introductions','mh_discharge');
 add('mh-unsub','HCP - MH discharge home - adult pathways','mh_adult','unsubscribed');
 rows.push({...rows[0],id:'homefinding',group_name:development,contact_notes:'Residential placement and home-finding enquiry'});
 state.hcpAudienceFilter='mh_home';state.composeHcpAudienceFilter='mh_home';
 await ctx.loadContactsPage();
 const expected=['mh-adult','mh-child','mh-clinical','mh-warm'];
 assert.deepEqual(Array.from(state.currentRows,r=>r.id).sort(),expected);
 assert.equal((await ctx.previewComposeCounts()).matching,4);
 assert.deepEqual(Array.from(await ctx.buildAllComposeContactsFromDb(),r=>r.id).sort(),expected);
 state.hcpAudienceFilter='mh_warm';await ctx.loadContactsPage();
 assert.deepEqual(Array.from(state.currentRows,r=>r.id),['mh-warm'],'Warm contact keeps its existing primary classification');
 state.hcpAudienceFilter='mh_cyp';await ctx.loadContactsPage();
 assert.deepEqual(Array.from(state.currentRows,r=>r.id),['mh-child']);
 assert.match(ctx.renderCompose(),/No residential placement or accommodation offer/);
});
