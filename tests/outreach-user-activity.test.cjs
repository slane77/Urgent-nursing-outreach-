const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const path=require('node:path');
const app=fs.readFileSync(path.join(__dirname,'../js/app.js'),'utf8');
const code=app.slice(app.indexOf('let userActivityRequest=0;'),app.indexOf('function renderDashboard()'));
function setup(rpc,overrides={}) {
  const state={user:{id:'test-admin'},userProfile:{role:'admin'},...overrides};
  const ctx=vm.createContext({state,sb:{rpc},render:()=>{},esc:s=>String(s??'').replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;')});
  vm.runInContext(code,ctx);
  return ctx;
}
test('Non-admin users neither request nor render team activity',async()=>{
  const ctx=setup(()=>{throw Error('Unexpected request');},{userProfile:{role:'user'}});
  await ctx.loadUserActivity();
  assert.equal(ctx.renderUserActivity(),'');
  assert.equal(ctx.state.userActivity,null);
});
test('Audience is sent to the protected aggregate endpoint',async()=>{
  let called;
  const ctx=setup(async(name,args)=>{called={name,args};return {data:{rows:[],audience:'candidates'}};},{userActivityAudience:'candidates'});
  await ctx.loadUserActivity();
  assert.equal(called.name,'dashboard_user_activity');
  assert.equal(called.args.p_audience,'candidates');
  assert.equal(ctx.state.userActivity.audience,'candidates');
  assert.equal(ctx.state.userActivityLoading,false);
});
test('Failed and malformed responses show an error instead of invented zero totals',async()=>{
  for(const response of [{error:{message:'Permission denied'}},{data:{}}]){
    const ctx=setup(async()=>response,{userActivity:{rows:[{name:'Old result'}]}});
    await ctx.loadUserActivity();
    assert.equal(ctx.state.userActivity,null);
    assert.match(ctx.renderUserActivity(),/role="alert"/);
    assert.doesNotMatch(ctx.renderUserActivity(),/Old result|<table/);
  }
});
test('An older response cannot replace a newer audience selection',async()=>{
  const pending=[];
  const ctx=setup(()=>new Promise(resolve=>pending.push(resolve)));
  const first=ctx.loadUserActivity();
  ctx.state.userActivityAudience='contacts';
  const second=ctx.loadUserActivity();
  pending[1]({data:{rows:[],audience:'contacts'}});
  await second;
  pending[0]({data:{rows:[],audience:'all'}});
  await first;
  assert.equal(ctx.state.userActivity.audience,'contacts');
});
test('A response for a previous signed-in user is discarded',async()=>{
  let finish;
  const ctx=setup(()=>new Promise(resolve=>finish=resolve));
  const request=ctx.loadUserActivity();
  ctx.state.user={id:'different-user'};
  finish({data:{rows:[{name:'Previous account result'}]}});
  await request;
  assert.equal(ctx.state.userActivity,undefined);
});
test('Names are escaped, duplicate names remain distinct, and zero and unknown activity remain visible',()=>{
  const ctx=setup(()=>{}, {userActivity:{asOf:'2026-11-25T12:00:00Z',rows:[
    {name:'<script>alert(1)</script>',email:'first@example.invalid',today:0,this_week:3,this_month:12,all_time:1234,last_sent_at:null},
    {name:'<script>alert(1)</script>',email:'second@example.invalid',today:0,this_week:0,this_month:0,all_time:0,last_sent_at:null},
    {name:'Unattributed historical sends',unattributed:true,all_time:5}
  ]}});
  const html=ctx.renderUserActivity();
  assert.doesNotMatch(html,/<script>/);
  assert.match(html,/&lt;script&gt;/);
  assert.match(html,/first@example.invalid/);
  assert.match(html,/second@example.invalid/);
  assert.match(html,/<td>0<\/td>/);
  assert.match(html,/1,234/);
  assert.match(html,/No recorded sends/);
  assert.match(html,/activity-unattributed/);
  assert.match(html,/not confirmed delivery/);
});
