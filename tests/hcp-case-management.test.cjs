const {test}=require('node:test');
const assert=require('node:assert/strict');
const vm=require('node:vm');
const fs=require('node:fs');
const path=require('node:path');
const app=fs.readFileSync(path.join(__dirname,'../js/app.js'),'utf8');
const helpers=app.slice(app.indexOf('const HCP_AREAS ='),app.indexOf('const MODAL_SOURCE_OPTIONS ='));
const ctx=vm.createContext({esc:s=>String(s??'')});
vm.runInContext(helpers,ctx);
const records=[
 {id:'ready',department:'case_management',group_name:'HCP - Case management - Adult injury & rehabilitation',status:'lead',hcp_outreach_status:'ready'},
 {id:'hold',department:'case_management',group_name:'HCP - Case management - Adult injury & rehabilitation',status:'lead',hcp_outreach_status:'cqc_hold'},
 {id:'unsub',department:'case_management',group_name:'HCP - Case management - Adult injury & rehabilitation',status:'unsubscribed',hcp_outreach_status:'ready'},
 {id:'cyp',department:'case_management',group_name:'HCP - Case management - Children & young people',status:'live',hcp_outreach_status:'ready'},
 {id:'icb',department:'icb',group_name:'HCP - Case management - Adult injury & rehabilitation',status:'lead',hcp_outreach_status:'ready'}
];
function query(){const p=[];return {eq(k,v){p.push(r=>r[k]===v);return this},in(k,v){p.push(r=>v.includes(r[k]));return this},rows(){return records.filter(r=>p.every(f=>f(r))).map(r=>r.id)}}}
test('Case-management workspace includes holds for review but excludes other team types',()=>{
 assert.deepEqual(ctx.applyHcpTargeting(query(),'cm_all','all').rows(),['ready','hold','unsub','cyp']);
});
test('Adult segment excludes children and similarly labelled non-case-management records',()=>{
 assert.deepEqual(ctx.applyHcpTargeting(query(),'cm_adult','all').rows(),['ready','hold','unsub']);
});
test('Sending a case-management segment still excludes CQC holds and unsubscribes',()=>{
 const q=ctx.applyContactStatusFilter(query(),'eligible','hcp');
 assert.deepEqual(ctx.applyHcpTargeting(q,'cm_adult','all').rows(),['ready']);
});
test('Sending all case managers keeps live contacts without releasing holds',()=>{
 const q=ctx.applyContactStatusFilter(query(),'eligible','hcp');
 assert.deepEqual(ctx.applyHcpTargeting(q,'cm_all','all').rows(),['ready','cyp']);
});
test('Database and Compose expose the same service categories and review explanation',()=>{
 for(const prefix of ['db-hcp','compose-hcp']){
  const html=ctx.renderHcpTargeting(prefix,'cm_cyp','all');
  assert.match(html,/value="cm_cyp" selected/);
  assert.match(html,/optgroup label="Case management"/);
  assert.match(html,/Compose excludes these from sending/);
 }
});
