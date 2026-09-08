const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { stripTypeScriptTypes } = require('node:module');
const path = require('node:path');
const root = path.join(__dirname, '..');
const app = fs.readFileSync(path.join(root, 'js/app.js'), 'utf8');

function appFunction(start, end, globals) {
  const context = vm.createContext(globals);
  vm.runInContext(app.slice(app.indexOf(start), app.indexOf(end, app.indexOf(start))), context);
  return context;
}

test('recipient pagination aborts rather than offering a partial send', async () => {
  let pages = 0;
  const q = {
    select() { return this; }, neq() { return this; }, eq() { return this; },
    not() { return this; }, order() { return this; },
    range() { return Promise.resolve(++pages === 1
      ? { data: Array.from({ length: 1000 }, (_, i) => ({ id: String(i), email: 'test@example.invalid' })) }
      : { error: { message: 'simulated network failure' } }); },
  };
  const ctx = appFunction('async function buildCandidateSendIds()', 'async function startCandidateSend()', {
    sb: { from: () => q }, candApplyFilters: x => x,
  });
  await assert.rejects(ctx.buildCandidateSendIds(), /complete recipient list/);
});

test('dashboard uses the signed-in session and surfaces API errors', async () => {
  let request;
  const ctx = appFunction('async function callCM(', 'async function loadDashboard()', {
    CM_API: 'https://example.invalid',
    sb: { auth: { getSession: async () => ({ data: { session: { access_token: 'synthetic-session' } } }) } },
    fetch: async (url, options) => { request = options; return { ok: false, json: async () => ({ error: 'Access denied' }) }; },
  });
  await assert.rejects(ctx.callCM('dashboard'), /Access denied/);
  assert.equal(request.headers.Authorization, 'Bearer synthetic-session');
});

test('dashboard does not call the API when signed out', async () => {
  const ctx = appFunction('async function callCM(', 'async function loadDashboard()', {
    sb: { auth: { getSession: async () => ({ data: { session: null } }) } },
    fetch: () => assert.fail('Must not request without a session'),
  });
  await assert.rejects(ctx.callCM('dashboard'), /sign in again/);
});

function contactManager(user, profile) {
  let handler, privilegedClients = 0;
  let source = fs.readFileSync(path.join(root, 'supabase/functions/contact-manager/index.ts'), 'utf8');
  source = source.replace(/^import .*;\n/m, '');
  const q = { select() { return this; }, eq() { return this; }, single: async () => ({ data: profile }) };
  const ctx = vm.createContext({
    Request, Response, Date, console,
    Deno: { env: { get: key => key }, serve: fn => { handler = fn; } },
    createClient: (url, key) => {
      if (key === 'SUPABASE_SERVICE_ROLE_KEY') privilegedClients++;
      return { auth: { getUser: async () => ({ data: { user } }) }, from: () => q };
    },
  });
  vm.runInContext(stripTypeScriptTypes(source), ctx);
  return { run: handler, privileged: () => privilegedClients };
}

test('contact manager rejects missing and public-key-only sessions before privileged access', async () => {
  for (const headers of [{}, { Authorization: 'Bearer public-anon-key' }]) {
    const cm = contactManager(null, null);
    const res = await cm.run(new Request('https://example.invalid', { method: 'POST', headers, body: '{}' }));
    assert.equal(res.status, 401);
    assert.equal(cm.privileged(), 0);
  }
});

test('contact manager rejects authenticated accounts without a profile', async () => {
  const cm = contactManager({ id: 'synthetic-user' }, null);
  const res = await cm.run(new Request('https://example.invalid', { method: 'POST', headers: { Authorization: 'Bearer session' }, body: '{}' }));
  assert.equal(res.status, 403);
  assert.equal(cm.privileged(), 0);
});

test('contact manager accepts a consultant session and preserves CORS preflight', async () => {
  const cm = contactManager({ id: 'synthetic-user' }, { user_id: 'synthetic-user' });
  const preflight = await cm.run(new Request('https://example.invalid', { method: 'OPTIONS' }));
  assert.equal(preflight.status, 200);
  assert.equal(cm.privileged(), 0);
  const res = await cm.run(new Request('https://example.invalid', { method: 'POST', headers: { Authorization: 'Bearer session' }, body: '{"action":"unknown"}' }));
  assert.equal(res.status, 400);
  assert.equal(cm.privileged(), 1);
});

test('session refresh and repeated sign-in do not restart an active workspace', async () => {
  let callback, boots=0;
  const tasks=[];
  const ctx=appFunction('let authBootUserId =', 'async function signIn(', {
    state:{user:null}, console,
    sb:{auth:{getSession:async()=>({data:{session:{user:{id:'joe'}}}}),onAuthStateChange:fn=>{callback=fn;}}},
    window:{addEventListener(){}},setTimeout:fn=>tasks.push(fn),
    bootApp:()=>boots++,render(){},toast(){},refreshMailshots(){},clearTimeout(){},mailshotRows:[],mailshotPoll:null,
  });
  await ctx.initAuth();
  callback('TOKEN_REFRESHED',{user:{id:'joe'}});
  callback('SIGNED_IN',{user:{id:'joe'}});
  assert.equal(tasks.length,0);
  callback('SIGNED_IN',{user:{id:'different'}});
  assert.equal(boots,0,'boot must run outside auth callback');
  tasks.shift()();
  assert.equal(boots,1);
});

test('queue retry reuses request ID after a lost response', async()=>{
  let attempts=0; const ids=[];
  const ctx=appFunction('let mailshotRows =', 'async function refreshMailshots()', {
    state:{user:{id:'joe'}},crypto:{randomUUID:()=> 'request-'+(++attempts)},toast(){},refreshMailshots:async()=>{},
    sb:{rpc:async(name,args)=>{ids.push(args.p_id);return ids.length===1?{error:{message:'connection lost'}}:{data:args.p_id};}},
  });
  await ctx.queueMailshot('contacts',{id:'template'},['recipient'],{});
  await ctx.queueMailshot('contacts',{id:'template'},['recipient'],{});
  assert.equal(ids[0],ids[1]);
});

function deliveryHarness(candidate, providerStatus=201) {
  let calls=0;const logs=[];
  const admin={from(table){return {
    select(){return this;},eq(){return this;},
    single:async()=>({data:{sender_email:'sender@example.invalid',sender_name:'Test',role:'user',candidate_sectors:['test']}}),
    in:async()=>({data:table==='candidates'?[candidate]:[]}),
    insert:async rows=>{logs.push(...rows);return {};},
    update(){return this;}
  };}};
  let source=fs.readFileSync(path.join(root,'supabase/functions/mailshot-worker/delivery.ts'),'utf8').replace(/^import .*;\n/m,'').replace('export async function','async function');
  const ctx=vm.createContext({createClient:()=>admin,Deno:{env:{get:()=> 'synthetic'}},Request,Response,AbortSignal,console,setTimeout:fn=>fn(),fetch:async()=>{calls++;return new Response('{}',{status:providerStatus});}});
  vm.runInContext(stripTypeScriptTypes(source),ctx);
  return {run:()=>ctx.deliverRecipient(new Request('https://example.invalid',{method:'POST',body:JSON.stringify({audience:'candidates',candidateIds:['candidate'],templateId:'template'})}),{id:'user',email:'sender@example.invalid'},{subject:'Hi {{FirstName}}',body:'Example'}),calls:()=>calls,logs};
}

test('queued delivery rechecks unsubscribe and candidate sector before contacting provider',async()=>{
  for(const candidate of [{id:'candidate',sector:'test',unsubscribed:true,email:'test@example.invalid'},{id:'candidate',sector:'other',email:'test@example.invalid'},{id:'candidate',sector:'test',status:'do_not_use',email:'test@example.invalid'}]) {
    const h=deliveryHarness(candidate);const r=await (await h.run()).json();
    assert.equal(h.calls(),0);assert.equal(r.sent,0);
  }
});
test('queued delivery records successful acceptance and does not call provider rejection a bounce',async()=>{
  const candidate={id:'candidate',sector:'test',email:'test@example.invalid'};
  const ok=deliveryHarness(candidate);assert.equal((await (await ok.run()).json()).sent,1);assert.equal(ok.logs[0].status,'sent');
  const rejected=deliveryHarness(candidate,429);assert.equal((await (await rejected.run()).json()).sent,0);assert.equal(rejected.logs.length,0);
});
