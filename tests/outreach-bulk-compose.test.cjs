const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const path=require('node:path');
const app=fs.readFileSync(path.join(__dirname,'../js/app.js'),'utf8');
function section(start,end){const i=app.indexOf(start),j=app.indexOf(end,i);assert.ok(i>=0&&j>i);return app.slice(i,j);}
function harness(rows=[],delay){
 const template={id:'template',name:'HCP introduction',subject:'Hello',body:'Hello {{Org}}'};
 const state={user:{id:'scott'},userProfile:{role:'admin'},view:'compose',templates:[template],composeTemplateId:'template',composeSourceFilter:'hcp',composeListFilter:'eligible',composeAreaFilter:'all',composeHcpAudienceFilter:'priority',composeHcpCommissioningFilter:'all',composeBatchSize:250,composeUncontactedOnly:false};
 const calls=[],messages=[],queries=[];let reads=0;
 const sb={from(table){const predicates=[];let range=[0,9999];const q={
  select(){return this;},eq(k,v){predicates.push(r=>r[k]===v);return this;},in(k,vs){predicates.push(r=>vs.includes(r[k]));return this;},
  is(k,v){predicates.push(r=>v===null?r[k]==null:r[k]===v);return this;},
  ilike(k,v){const token=v.replaceAll('%','').toLowerCase();predicates.push(r=>String(r[k]||'').toLowerCase().includes(token));return this;},
  order(){return this;},range(a,b){range=[a,b];return this;},
  then(resolve,reject){reads++;queries.push({table,range});const filtered=rows.filter(r=>predicates.every(fn=>fn(r)));const result={data:filtered.slice(range[0],range[1]+1)};return (delay?delay(result):Promise.resolve(result)).then(resolve,reject);}
 };return q;}};
 const ctx=vm.createContext({state,sb,console,Set,JSON,Number,String,Math,Array,
  canSendContactSource:(profile,source)=>!!profile&&(profile.role==='admin'||profile.allowed_sources?.includes(source))&&['hcp','ahp'].includes(source),
  COMPOSE_SRC_LABELS:{hcp:'HCP',ahp:'AHP'},
  composeSenderFields:()=>({source:state.composeSourceFilter}),
  withConnectionTimeout:p=>p,toast:m=>messages.push(m),render(){},
  reviewContactMailshot:async(...args)=>calls.push(args),
  queueMailshot:()=>assert.fail('Opening review must not queue emails'),
 });
 vm.runInContext(section('const HCP_AREAS =','const MODAL_SOURCE_OPTIONS =')+section('function applyComposeSourceFilter(','async function buildComposeQueueFromDb()')+section('function contactSendError(','async function reviewContactMailshot(')+section('async function sendFilteredViaBrevo()','async function buildAllComposeContactsFromDb()'),ctx);
 return {ctx,state,template,calls,messages,queries,reads:()=>reads};
}
function contacts(n){return Array.from({length:n},(_,i)=>({id:String(i),email:`contact${i}@example.invalid`,org:`Organisation ${i}`,notes:'Source: HCP Complex Care',status:'lead',group_name:"HCP - Priority children's complex care",care_group:'Lewisham',region:'London',country:'England',town:'Lewisham',department:'icb'}));}
test('197 matching contacts reach one review without queuing any emails',async()=>{
 const h=harness(contacts(197));await h.ctx.sendFilteredViaBrevo();assert.equal(h.calls.length,1);assert.equal(h.calls[0][1].length,197);assert.equal(h.calls[0][2].source,'hcp');assert.equal(h.state.composeReviewLoading,false);
});
test('source, status, HCP audience, commissioning area and location filters all apply',async()=>{
 const base=contacts(1)[0],rows=[base,...[
  {notes:'Source: NHS Jobs AHP'},{status:'unsubscribed'},{status:'bounced'},
  {group_name:''},{care_group:'Bromley'},{department:'other'},
  {region:'South East'},{country:'Scotland'},{town:'Elsewhere'},{last_emailed_at:'2026-11-04'}
 ].map((diff,i)=>({...base,id:`excluded${i}`,email:`excluded${i}@example.invalid`,...diff}))];
 const h=harness(rows);Object.assign(h.state,{composeAreaFilter:'icb',composeHcpCommissioningFilter:'Lewisham',composeRegionFilter:'London',composeCountryFilter:'England',composeTownFilter:'Lewisham',composeUncontactedOnly:true});
 await h.ctx.sendFilteredViaBrevo();assert.deepEqual(Array.from(h.calls[0][1]),['0']);assert.equal(h.queries[0].table,'contacts_with_last_email');
});
test('duplicate mailbox addresses are removed regardless of casing and whitespace',async()=>{
 const rows=contacts(3);rows[1].email=' CONTACT0@EXAMPLE.INVALID ';rows[2].email='invalid';
 const h=harness(rows);await h.ctx.sendFilteredViaBrevo();assert.equal(h.calls[0][1].length,1);
});
test('selected batch size and absolute 500 limit are respected',async()=>{
 for(const [size,expected] of [[250,250],[500,500],[2000,500],[-1,1]]){
  const h=harness(contacts(700));h.state.composeBatchSize=size;await h.ctx.sendFilteredViaBrevo();assert.equal(h.calls[0][1].length,expected);assert.equal(h.queries[0].range[1],expected-1);
 }
});
test('all-source and unassigned database requests are blocked before fetching recipients',async()=>{
 for(const source of ['all','hcp']){const h=harness(contacts(2));h.state.composeSourceFilter=source;h.state.userProfile={role:'user',allowed_sources:['ahp']};await h.ctx.sendFilteredViaBrevo();assert.equal(h.reads(),0);assert.equal(h.calls.length,0);assert.equal(h.messages.length,1);}
});
test('database errors and empty matches cannot open a partial review',async()=>{
 for(const delay of [undefined,()=>Promise.resolve({error:{message:'Connection failed'},data:contacts(1)})]){
  const h=harness([],delay);await h.ctx.sendFilteredViaBrevo();assert.equal(h.calls.length,0);assert.equal(h.state.composeReviewLoading,false);assert.equal(h.messages.length,1);
 }
});
test('changing filters, template, user or view while loading discards stale recipients',async()=>{
 for(const change of [s=>s.composeRegionFilter='Elsewhere',s=>s.composeTemplateId='other',s=>s.user={id:'other'},s=>s.view='database']){
  let release;const h=harness(contacts(2),r=>new Promise(resolve=>release=()=>resolve(r)));const pending=h.ctx.sendFilteredViaBrevo();await new Promise(resolve=>setImmediate(resolve));change(h.state);release();await pending;assert.equal(h.calls.length,0);assert.match(h.messages[0],/changed/);
 }
});
test('double clicking opens only one review',async()=>{
 let release;const h=harness(contacts(197),r=>new Promise(resolve=>release=()=>resolve(r)));const pending=h.ctx.sendFilteredViaBrevo();await new Promise(resolve=>setImmediate(resolve));await h.ctx.sendFilteredViaBrevo();assert.equal(h.reads(),1);release();await pending;assert.equal(h.calls.length,1);
});
test('send-all control is labelled accurately and respects loading and access',()=>{
 const h=harness();Object.assign(h.state,{counts:{lead:197,live:0},regions:[],countries:[],composePreviewCounts:{matching:197}});
 Object.assign(h.ctx,{esc:String});vm.runInContext(section('function renderCompose()','function renderBrevoSend()'),h.ctx);
 let html=h.ctx.renderCompose();assert.match(html,/Review & send all 197 matching contacts/);assert.doesNotMatch(html,/Sending to all matching records is disabled/);
 h.state.composePreviewCounts.matching=700;html=h.ctx.renderCompose();assert.match(html,/Review & send first 250 matching contacts/);
 h.state.composeReviewLoading=true;html=h.ctx.renderCompose();assert.match(html,/id="brevo-filter-send-btn" disabled/);
 h.state.composeReviewLoading=false;h.state.userProfile=null;html=h.ctx.renderCompose();assert.match(html,/id="brevo-filter-send-btn" disabled/);
});
