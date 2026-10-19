const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const app = fs.readFileSync(require('node:path').join(__dirname, '../js/app.js'), 'utf8');
function section(start, end) { return app.slice(app.indexOf(start), app.indexOf(end, app.indexOf(start))); }
function context(globals) { return vm.createContext({ console, ...globals }); }
const dataCode = section('function londonDayStart(', 'async function loadTemplates()');
function dataHarness(rows, delayed) {
  const state = { subTab:'lead', dbStage:'all', sourceFilter:'all', page:1, pageSize:50, sortKey:'org', sortDir:'asc', selected:new Set() };
  const queries = [];
  const sb = { from(table) {
    const filters=[],orders=[]; let range=[0,49];
    const q = { select(){return this;}, eq(k,v){filters.push(r=>r[k]===v);return this;},
      gte(k,v){filters.push(r=>r[k]>=v);return this;},
      ilike(k,v){const token=v.replaceAll('%','').toLowerCase();filters.push(r=>(r[k]||'').toLowerCase().includes(token));return this;},
      order(k,o){orders.push([k,o]);return this;},range(a,b){range=[a,b];return this;},
      then(resolve,reject){queries.push({table,range,orders}); const filtered=rows.filter(r=>filters.every(f=>f(r)));
        filtered.sort((a,b)=>{for(const [k,o] of orders){if(a[k]!==b[k])return (a[k]<b[k]?-1:1)*(o.ascending?1:-1);}return 0;});
        const result={data:filtered.slice(range[0],range[1]+1),count:filtered.length};
        return delayed ? delayed(result).then(resolve,reject) : Promise.resolve(result).then(resolve,reject);
      }
    }; return q;
  }};
  const ctx=context({state,sb,loadSourceStatusCounts:async()=>{},render(){},toast(){throw Error('Unexpected query failure');}});
  vm.runInContext(dataCode,ctx);
  return {ctx,state,queries};
}
test('London reporting day agrees across GMT, BST, and DST transition days',()=>{
  const ctx=context({});vm.runInContext(section('function londonDayStart(', '// Dashboard drilldowns'),ctx);
  for(const [now,start] of [
    ['2026-01-10T12:00:00Z','2026-01-10T00:00:00.000Z'],
    ['2026-10-19T12:00:00Z','2026-10-18T23:00:00.000Z'],
    ['2026-03-29T12:00:00Z','2026-03-29T00:00:00.000Z'],
    ['2026-10-25T12:00:00Z','2026-10-24T23:00:00.000Z'],
    ['2026-07-10T23:30:00Z','2026-07-10T23:00:00.000Z']
  ]) assert.equal(ctx.londonDayStart(new Date(now)),start);
});
function intakeRows() {
  const stamp=new Date().toISOString();
  return Array.from({length:178},(_,i)=>({id:String(i).padStart(4,'0'),created_at:stamp,notes:'Source: NHS Jobs AHP | Specialty: physiotherapy',
    status:i<161?'lead':'unsubscribed',stage:i<134||i>=161?'new':'contacted'}));
}
test('New today includes all 178 AHP imports over four pages without changing their statuses',async()=>{
  const rows=intakeRows();
  rows.push({id:'old',created_at:'2020-01-01T00:00:00Z',notes:'Source: NHS Jobs AHP',status:'lead',stage:'new'});
  rows.push({id:'other',created_at:new Date().toISOString(),notes:'Source: NHS Scotland',status:'lead',stage:'new'});
  const {ctx,state}=dataHarness(rows);await ctx.openDatabaseView('added_today','ahp');
  assert.equal(state.totalRows,178);
  const ids=[];
  for(let p=1;p<=4;p++){state.page=p;await ctx.loadContactsPage();ids.push(...state.currentRows.map(r=>r.id));}
  assert.equal(ids.length,178);assert.equal(new Set(ids).size,178);
  assert.equal(rows.filter(r=>r.status==='unsubscribed').length,17);
  assert.equal(rows.filter(r=>r.stage==='contacted').length,27);
});
test('Uncontacted remains a lead-stage filter and excludes contacted and unsubscribed imports',async()=>{
  const {ctx,state}=dataHarness(intakeRows());await ctx.openDatabaseView('new','ahp');
  assert.equal(state.totalRows,134);assert.equal(state.subTab,'lead');
  assert.ok(state.currentRows.every(r=>r.stage==='new'&&r.status==='lead'));
});
test('Fresh drilldowns clear stale country, specialty, search and pagination state',async()=>{
  const {ctx,state}=dataHarness(intakeRows());
  Object.assign(state,{page:99,search:'wrong',countryFilter:'Ireland',regionFilter:'wrong',ahpSpecialtyFilter:'wrong',subTab:'unsubscribed'});
  await ctx.openDatabaseView('added_today','ahp');
  assert.equal(state.page,1);assert.equal(state.countryFilter,'');assert.equal(state.regionFilter,'');
  assert.equal(state.ahpSpecialtyFilter,'all');assert.equal(state.search,'');assert.equal(state.totalRows,178);
  assert.equal(state.sortKey,'created_at');assert.equal(state.sortDir,'desc');
});
test('A slow earlier query cannot overwrite a newer filter result',async()=>{
  const pending=[];const {ctx,state}=dataHarness(intakeRows(), result=>new Promise(resolve=>pending.push(()=>resolve(result))));
  const first=ctx.loadContactsPage();await new Promise(resolve=>setImmediate(resolve));
  state.dbStage='new';state.sourceFilter='ahp';const second=ctx.loadContactsPage();await new Promise(resolve=>setImmediate(resolve));
  pending[1]();await second;assert.equal(state.totalRows,134);
  pending[0]();await first;assert.equal(state.totalRows,134);
});
test('Mailshot activity is fixed open and preserves every progress metric and cancel action',()=>{
  const ctx=context({mailshotError:false,mailshotRows:[{id:'job',template_name:'Template',audience:'contacts',created_at:'2026-10-19',total:100,sent:60,queued:10,processing:5,failed:4,skipped:3,uncertain:2,cancelled:16}],esc:String});
  vm.runInContext(section('function renderMailshotPanel()', "document.addEventListener('click',async e=>"),ctx);
  const html=ctx.renderMailshotPanel();
  assert.match(html,/<section/);assert.doesNotMatch(html,/<details|<summary/);
  for(const value of ['60 sent','15 waiting','4 failed','3 skipped','2 need delivery review','16 cancelled','data-cancel-mailshot="job"','<progress'])assert.ok(html.includes(value),value);
});
test('Only dashboard contains the mailshot panel',()=>{
  const state={view:'dashboard',user:{email:'test'},counts:{lead:1,live:0,unsubscribed:0}};
  const ctx=context({state,esc:String,candidateAccess:()=>false,renderMailshotPanel:()=> 'activity',renderDashboard:()=> 'dashboard',renderDatabase:()=> 'database'});
  vm.runInContext(section('function renderAppShell()', 'function extractSpecialty('),ctx);
  assert.match(ctx.renderAppShell(),/id="mailshot-panel"/);
  state.view='database';assert.doesNotMatch(ctx.renderAppShell(),/mailshot-panel|activity/);
});
test('Intake shows status instead of selecting mixed statuses for bulk outreach',()=>{
  const {ctx,state}=dataHarness(intakeRows());
  Object.assign(state,{dbStage:'added_today',subTab:'all',sourceFilter:'ahp',sourceCounts:{ahp:178},newTodayCounts:{ahp:178},sourceStatusCounts:{lead:161,live:0,unsubscribed:17},counts:{},regions:[],countries:[],currentRows:intakeRows(),totalRows:178});
  Object.assign(ctx,{esc:String,extractSpecialty:()=> 'physiotherapy'});
  vm.runInContext(section('function renderDatabase()', 'function renderTemplates()'),ctx);
  const html=ctx.renderDatabase();
  assert.match(html,/data-new-source="ahp"/);assert.match(html,/data-dstage="added_today"/);
  assert.match(html,/unsubscribed \/ new/);assert.match(html,/lead \/ contacted/);
  assert.doesNotMatch(html,/class="row-cb"|id="select-all-cb"|data-bulk=/);
});
