const {test}=require('node:test');
const assert=require('node:assert/strict');
const path=require('node:path');
const {pathToFileURL}=require('node:url');
const mod=p=>import(pathToFileURL(path.join(__dirname,'..',p)));
test('richer answers keep experience separate from preference and discard forged approval',async()=>{
 const {validate}=await mod('supabase/functions/complex-care-response/validation.mjs');
 const b={token:'a'.repeat(64),action:'submit',answers:{interest:'now',contact_preference:'email',experience:'current',population:'children',skills:['tracheostomy'],shifts:['nights'],availability:'now',screening_details:{population_experience:'adults',notice:'same_day',transport:'car',approved:true,skill_details:{tracheostomy:{last_used:'within_6_months',setting:'home',equipment:'Example device',verified:true}}}}};
 const result=validate(b).answers;
 assert.equal(result.population,'children');assert.equal(result.screening_details.population_experience,'adults');
 assert.equal(result.screening_details.approved,undefined);assert.equal(result.screening_details.skill_details.tracheostomy.verified,undefined);
 for(const change of [d=>d.notice='ready_now',d=>d.skill_details.peg={},d=>d.skill_details.tracheostomy.last_used='verified',d=>d.skill_details.tracheostomy.equipment='x'.repeat(201)]){const copy=structuredClone(b);change(copy.answers.screening_details);assert.throws(()=>validate(copy));}
});
test('personal invitation helper excludes holds, wrong sectors and declined or phone only contacts',async()=>{
 const {createComplexCareLink}=await mod('supabase/functions/mailshot-worker/complex-care-link.mjs');
 let inserts=0;let profile=null;
 const admin={from:()=>({select(){return this},eq(){return this},maybeSingle:async()=>({data:profile}),insert:async()=>{inserts++;return {}}})};
 const candidate={id:'synthetic',sector:'nursing_urgent',status:'available',unsubscribed:false};
 for(const c of [{...candidate,unsubscribed:true},{...candidate,status:'do_not_use'},{...candidate,sector:'other'}])assert.equal(await createComplexCareLink(admin,c,'sender'),null);
 for(const p of [{interest:'not_interested',contact_preference:'email'},{interest:'now',contact_preference:'phone'},{interest:'now',contact_preference:'none'}]){profile=p;assert.equal(await createComplexCareLink(admin,candidate,'sender'),null);}
 assert.equal(inserts,0);
});
test('each campaign link is unique and only its hash is persisted; lookup errors fail closed',async()=>{
 const {createComplexCareLink}=await mod('supabase/functions/mailshot-worker/complex-care-link.mjs');
 const inserted=[];let fail=false;
 const admin={from:()=>({select(){return this},eq(){return this},maybeSingle:async()=>fail?{error:{message:'offline'}}:{data:null},insert:async row=>{inserted.push(row);return {}}})};
 const c={id:'synthetic',sector:'nursing_urgent',status:'available'};
 const a=await createComplexCareLink(admin,c,'sender'),b=await createComplexCareLink(admin,c,'sender');
 assert.notEqual(a,b);const token=new URL(a).hash.split('=')[1];assert.match(token,/^[a-f0-9]{64}$/);assert.notEqual(inserted[0].token_hash,token);assert.equal(inserted[0].created_by,'sender');assert.equal(JSON.stringify(inserted).includes(token),false);
 fail=true;await assert.rejects(createComplexCareLink(admin,c,'sender'),/contact preferences/);assert.equal(inserted.length,2);
});
