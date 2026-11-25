const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const path=require('node:path');
const app=fs.readFileSync(path.join(__dirname,'../js/app.js'),'utf8');
function section(a,b){return app.slice(app.indexOf(a),app.indexOf(b,app.indexOf(a)));}
function harness(failAt=0){
 const rows=Array.from({length:2301},(_,i)=>({id:String(i)}));let pages=0;
 const state={user:{id:'chris'},view:'database',sourceFilter:'nhs_scotland',selected:new Set(['original']),loadingPage:false};
 const messages=[];
 const ctx=vm.createContext({state,Set,JSON,Number,Error,canSelectDatabasePage:()=>true,applyContactFilters:q=>q,toast:m=>messages.push(m),render(){},sb:{from(){let start,end;return {select(){return this;},order(){return this;},range(a,b){start=a;end=b;return this;},then(resolve){pages++;return Promise.resolve(pages===failAt?{error:{message:'Network unavailable'}}:{data:rows.slice(start,end+1),count:rows.length}).then(resolve);}};}}});
 vm.runInContext(section('async function selectAllMatchingContacts()', 'function contactSendError('),ctx);
 return {ctx,state,messages,pages:()=>pages};
}
test('Select all and header checkbox include 2301 contacts across five pages',async()=>{
 const h=harness();await h.ctx.setDatabasePageSelection(true);
 assert.equal(h.state.selected.size,2301);assert.equal(h.pages(),5);
 h.ctx.setDatabasePageSelection(false);assert.equal(h.state.selected.size,0);
});
test('Selection remains unchanged when a later page fails',async()=>{
 const h=harness(3);await h.ctx.selectAllMatchingContacts();
 assert.deepEqual([...h.state.selected],['original']);assert.match(h.messages[0],/Could not select all/);assert.equal(h.state.selectingAll,false);
});
test('Worker accepts large source-specific campaigns while retaining cancellation and source access',async()=>{
 const guards=await import('../supabase/functions/mailshot-worker/safety.mjs');
 for(const source of ['ahp','nhs_scotland','hse']){
  assert.equal(guards.campaignSafetyError({audience:'contacts',payload:{source}},2301),null);
  assert.equal(guards.hasContactSourceAccess({role:'user',allowed_sources:['ahp','nhs_scotland','hse']},source),true);
 }
 assert.ok(guards.campaignSafetyError({audience:'contacts',payload:{source:'all'}},2301));
 assert.ok(guards.campaignSafetyError({audience:'contacts',payload:{source:'ahp',cancelled:true}},2301));
 assert.equal(guards.hasContactSourceAccess({role:'user',allowed_sources:['ahp']},'nhs_scotland'),false);
});
test('Review rechecks selected records in small requests, deduplicates and excludes inactive addresses',async()=>{
 const rows=Array.from({length:1201},(_,i)=>({id:String(i),email:`test${i}@example.invalid`,status:'lead'}));
 rows[1].status='bounced';rows[2].status='unsubscribed';rows[3].email=rows[0].email.toUpperCase();let reads=0;
 const state={user:{id:'chris'},view:'compose',composeSourceFilter:'nhs_scotland',composeTemplateId:'t'};
 const ctx=vm.createContext({state,Set,String,contactSendError:()=>null,toast(){},renderModal(){},sb:{from:()=>({select(){return this;},async in(key,ids){reads++;assert.ok(ids.length<=100);return {data:rows.filter(c=>ids.includes(c.id))};}})}});
 vm.runInContext(section('async function reviewContactMailshot(', 'async function sendFilteredViaBrevo()'),ctx);
 await ctx.reviewContactMailshot({id:'t'},rows.map(c=>c.id),{source:'nhs_scotland'});
 assert.equal(reads,13);assert.equal(state.modal.ids.length,1198);
});
