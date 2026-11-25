const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const app=fs.readFileSync(path.join(__dirname,'../js/app.js'),'utf8');
const workspace=fs.readFileSync(path.join(__dirname,'../js/database-workspace.js'),'utf8');
function part(a,b){return app.slice(app.indexOf(a),app.indexOf(b,app.indexOf(a)));}
function harness(extra={}){
 const storage=new Map();
 const state={user:{id:'one'},view:'database',sourceFilter:'hcp',subTab:'eligible',dbStage:'all',hcpAudienceFilter:'all',hcpAreaFilter:'all',hcpCommissioningFilter:'all',page:1,pageSize:50,currentRows:[],selected:new Set(),sourceCounts:{},totalRows:0,regions:[],countries:[],templates:[],...extra};
 const ctx=vm.createContext({state,console,URL,localStorage:{getItem:k=>storage.get(k),setItem:(k,v)=>storage.set(k,v)},esc:s=>String(s??'').replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('"','&quot;'),render(){},toast(){},hcpTabVisible:()=>true,canSelectDatabasePage:()=>true,isRecentImportView:s=>s==='recent',effectiveContactStage:c=>c.stage||'new',renderFollowUpDate:s=>s,extractSpecialty:()=> 'physiotherapy'});
 vm.runInContext(part('const HCP_AREAS =','const MODAL_SOURCE_OPTIONS ='),ctx);
 vm.runInContext(workspace,ctx);return ctx;
}
test('Saved views are isolated by account, and contain filters rather than contact data',()=>{
 const ctx=harness();ctx.saveDbPreferences({views:[{name:'My view',filters:ctx.dbSavedFilters()}]});
 assert.equal(ctx.dbPreferences().views.length,1);
 assert.equal(ctx.dbPreferences().views[0].filters.currentRows,undefined);
 ctx.state.user={id:'two'};assert.equal(ctx.dbPreferences().views,undefined);
});
test('A general HCP lead can be used without invented role evidence; explicit holds still need a changed reason',()=>{
 const ctx=harness();
 assert.equal(ctx.hcpQualificationError({}, {hcp_outreach_status:'ready',hcp_pathway:'needs_review'}),null);
 assert.ok(ctx.hcpQualificationError({hcp_outreach_status:'cqc_hold',hcp_qualification_notes:'Inspection required'}, {hcp_outreach_status:'ready',hcp_pathway:'needs_review',hcp_qualification_notes:'Inspection required'}));
 const html=ctx.renderContactWorkspace();assert.doesNotMatch(html,/Needs review|Needs qualification/);
 assert.match(html,/CQC re-engagement/);assert.match(html,/Bounced emails/);
});
test('Contact content is escaped and external source links only accept HTTP or HTTPS',()=>{
 const ctx=harness({currentRows:[{id:'example',first_name:'<script>bad</script>',org:'<img src=x>',email:'test@example.invalid',status:'lead',hcp_outreach_status:'ready'}],totalRows:1});
 const html=ctx.renderContactWorkspace();assert.doesNotMatch(html,/<script>|<img src=x>/);assert.match(html,/&lt;script&gt;/);
 assert.equal(ctx.dbSafeUrl('javascript:alert(1)'),'');assert.equal(ctx.dbSafeUrl('https://example.invalid/job'),'https://example.invalid/job');
});
test('Owner and band filters apply to the same builder used for listing and selecting all matches',()=>{
 const ctx=harness({sourceFilter:'all',subTab:'lead',dbOwnerFilter:'mine',dbBandFilter:'6'});
 vm.runInContext(part('function applyContactFilters(', 'async function loadContactsPage()'),ctx);
 const calls=[];const q={eq(k,v){calls.push([k,v]);return this;},is(k,v){calls.push([k,v]);return this;}};
 ctx.applyContactFilters(q);assert.ok(calls.some(([k,v])=>k==='owner_user_id'&&v==='one'));assert.ok(calls.some(([k,v])=>k==='band_requested'&&v==='6'));
 calls.length=0;ctx.state.dbOwnerFilter='unassigned';ctx.applyContactFilters(q);assert.ok(calls.some(([k,v])=>k==='owner_user_id'&&v===null));
});
test('Select-all response is discarded if the user changes owner filters while it loads',async()=>{
 const ctx=harness();let finish;
 ctx.sb={from:()=>({select(){return this;},order(){return this;},limit(){return new Promise(r=>finish=r);}})};
 ctx.applyContactFilters=q=>q;
 vm.runInContext(part('async function selectAllMatchingContacts()', 'function setDatabasePageSelection('),ctx);
 const pending=ctx.selectAllMatchingContacts();ctx.state.dbOwnerFilter='mine';finish({data:[{id:'wrong-person'}],count:1});await pending;
 assert.equal(ctx.state.selected.size,0);
});
test('Drawer response does not reopen a contact closed while history was loading',async()=>{
 const ctx=harness({currentRows:[{id:'contact',email:null}]});let finish;
 ctx.document={getElementById:()=>null};
 ctx.sb={from:()=>({select(){return this;},in(){return this;},order(){return this;},limit(){return new Promise(r=>finish=r);}})};
 const pending=ctx.openDbContact('contact');ctx.state.dbDrawer=null;finish({data:[]});await pending;
 assert.equal(ctx.state.dbDrawer,null);
});
