const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const path=require('node:path');
const app=fs.readFileSync(path.join(__dirname,'../js/app.js'),'utf8');
function section(a,b){return app.slice(app.indexOf(a),app.indexOf(b,app.indexOf(a)));}
test('Import workspace keeps every scraper and CSV workflow available',()=>{
 const state={};const ctx=vm.createContext({state,icon:()=>'',esc:s=>String(s??''),renderCsvUploadCard:()=>'<input type="file" />'});
 vm.runInContext(section('function renderImport()','//  DASHBOARD'),ctx);
 for(const source of ['nhs','scotland','ireland','csv']){
  state.importWorkspace=source;const html=ctx.renderImport();
  assert.ok(html.includes('data-import-active="'+source+'"'));
  for(const id of ['run-scrape-btn','run-scrape-all-btn','run-scrape-every-btn','run-scot-btn','run-scot-all-btn','run-hse-btn','agency-upload-btn','review-imported-leads'])assert.ok(html.includes('id="'+id+'"'),id);
 }
});
test('Running imports remain visible in the source navigation and retain their result',()=>{
 const state={importWorkspace:'csv',scotRunning:true,importResult:{success:true,inserted:3,found:4,skipped_dup:1}};
 const ctx=vm.createContext({state,icon:()=>'',esc:s=>String(s??''),renderCsvUploadCard:()=>''});
 vm.runInContext(section('function renderImport()','//  DASHBOARD'),ctx);
 assert.match(ctx.renderImport(),/NHS Scotland · Running/);
 assert.match(ctx.renderImport(),/>3<\/div><div class="import-stat-lbl">Added/);
});
test('Shared navigation is keyboard-operable and retains existing workspace routes',()=>{
 const state={view:'import',user:{email:'test@example.invalid'},counts:{lead:0,live:0,unsubscribed:0}};
 const ctx=vm.createContext({state,esc:s=>s,candidateAccess:()=>false,renderImport:()=>'<p>Imports</p>'});
 vm.runInContext(section('function renderAppShell()','function extractSpecialty('),ctx);
 const html=ctx.renderAppShell();
 for(const route of ['dashboard','database','templates','compose','responses','settings','import'])assert.ok(html.includes('data-view="'+route+'"'));
 assert.match(html,/<button class="tab active" data-view="import" aria-current="page"/);
 assert.doesNotMatch(html,/data-view="candidates"/);
});
