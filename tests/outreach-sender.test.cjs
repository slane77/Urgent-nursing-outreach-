const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const {stripTypeScriptTypes}=require('node:module');
const root=path.join(__dirname,'../supabase/functions/mailshot-worker');
function harness(email,body={},options={}) {
  const requests=[],logs=[];
  const contact={id:'recipient',email:'recipient@example.invalid',first_name:'Example',status:options.status||'lead',department:'physiotherapy',notes:'Source: NHS Jobs AHP'};
  const admin={from(table){
    return {select(){return this;},eq(){return this;},update(){return this;},
      single:async()=>({data:table==='outreach_mailshots'?{cancelled:false}:{sender_email:options.profileEmail||email,sender_name:email.toLowerCase()==='chris.shine@daywebster.com'?'Chris Shine':'Other Sender',allowed_sources:['ahp'],role:'user'}}),
      maybeSingle:async()=>({data:{status:options.cancelled?'cancelled':'processing'}}),
      in(){this.rows=table==='contacts'?[contact]:[];return this;},
      insert:async data=>{logs.push(...data);return {};},
      then(resolve,reject){return Promise.resolve({data:table==='contacts'?this.rows:table==='sender_addresses'?[{source:'ahp',sub_source:'physiotherapy',email:'therapies@example.invalid',name:'Therapies'}]:[]}).then(resolve,reject);}
    };
  }};
  const source=fs.readFileSync(path.join(root,'delivery.ts'),'utf8').replace(/^import .*;\r?\n/gm,'').replace('export async function','async function');
  const helpers=['safety.mjs','complex-care-link.mjs'].map(f=>fs.readFileSync(path.join(root,f),'utf8').replaceAll('export ','')).join('\n');
  const ctx=vm.createContext({Request,Response,AbortSignal,TextEncoder,crypto,console,Deno:{env:{get:()=> 'test-only'}},createClient:()=>admin,setTimeout:fn=>fn(),
    fetch:async(url,init)=>{assert.equal(url,'https://api.brevo.com/v3/smtp/email');requests.push(JSON.parse(init.body));return new Response('{}',{status:201});}});
  vm.runInContext(helpers+stripTypeScriptTypes(source),ctx);
  return {requests,logs,run:()=>ctx.deliverRecipient(new Request('https://example.invalid',{method:'POST',body:JSON.stringify({
    audience:'contacts',source:'ahp',contactIds:['recipient'],templateId:'template',batchId:'queue_11111111-1111-4111-8111-111111111111',...body
  })}),{id:'owner',email},{subject:'Hello',body:'From {{SenderName}}'})};
}
for(const body of [{},{subSource:'physiotherapy'},{fromEmail:'therapies@example.invalid',fromName:'Stale team sender'}]) {
  test('Chris uses his personal From and Reply-To '+JSON.stringify(body),async()=>{
    const h=harness('Chris.Shine@daywebster.com',body,{profileEmail:'old-team@example.invalid'});
    const result=await (await h.run()).json();
    assert.equal(result.sent,1,JSON.stringify(result));assert.equal(h.requests.length,1);
    assert.deepEqual(h.requests[0].sender,{email:'chris.shine@daywebster.com',name:'Chris Shine'});
    assert.deepEqual(h.requests[0].replyTo,h.requests[0].sender);
    assert.match(h.requests[0].textContent,/From Chris Shine/);
    assert.equal(h.logs[0].sent_by,'owner');
  });
}
test('Other users keep their AHP specialty sender',async()=>{
  const h=harness('other@example.invalid');const response=await h.run();assert.equal(response.status,200,await response.clone().text());
  assert.equal(h.requests[0].sender.email,'therapies@example.invalid');
  assert.deepEqual(h.requests[0].replyTo,h.requests[0].sender);
});
test('Chris override does not bypass unsubscribe or source validation',async()=>{
  for(const opts of [{status:'unsubscribed'},{}]) {
    const h=harness('chris.shine@daywebster.com',opts.status?{}:{source:'gp_surgery'},opts);
    await h.run();assert.equal(h.requests.length,0);
  }
});
test('Chris override does not bypass cancellation at provider boundary',async()=>{
  const h=harness('chris.shine@daywebster.com',{}, {cancelled:true});await h.run();assert.equal(h.requests.length,0);
});
