'use strict';
(async()=>{
 const client=window.supabase.createClient(CONFIG.SUPABASE_URL,CONFIG.SUPABASE_ANON_KEY),$=id=>document.getElementById(id),esc=CC.escape;
 let offset=0,total=0,sequence=0,activeFilters={},rows=[];
 const fail=e=>{$('message').textContent=e.message||String(e);$('message').className='cc-error';};
 $('skills').innerHTML=Object.entries(CC.skills).map(([k,v])=>`<label><input type="checkbox" name="skill" value="${k}">${v}</label>`).join('');
 const readFilters=()=>({p_search:$('search').value.trim(),p_experience:$('experience').value,p_interest:$('interest').value,p_skills:[...document.querySelectorAll('[name=skill]:checked')].map(x=>x.value),p_all_skills:$('skill-mode').value==='all',p_locations:$('locations').value.split(',').map(s=>s.trim()).filter(Boolean)});
 async function search(){
  const current=++sequence;$('message').className='';$('message').textContent='Searching…';$('prev').disabled=$('next').disabled=true;
  const {data,error}=await client.rpc('search_complex_care',{...activeFilters,p_offset:offset});if(current!==sequence)return;
  if(error){rows=[];$('results').replaceChildren();$('count').textContent='Search unavailable';fail(error);return;}
  rows=data.rows;total=data.total;$('message').textContent='';$('count').textContent=total.toLocaleString()+' matching candidate'+(total===1?'':'s');$('page').textContent=`Page ${offset/50+1}`;$('prev').disabled=offset===0;$('next').disabled=offset+50>=total;
  $('results').innerHTML=rows.map(c=>{
   const p=c.complex_care,experienced=['current','previous'].includes(p?.experience),held=c.unsubscribed||c.status==='do_not_use';
   return `<article class="card cc-result ${experienced?'experienced':''}"><span class="cc-badge ${experienced?'':'cc-muted'}">${esc(p?CC.experience[p.experience]:'No response yet')}</span><h3>${esc([c.first_name,c.last_name].filter(Boolean).join(' ')||'Unnamed candidate')}</h3><p>${esc([c.town,c.county,c.postcode].filter(Boolean).join(' · ')||'Location not recorded')}</p><p>${esc(c.email||'No email')}<br>${esc(c.phone||'No phone')}</p>${held?'<p><span class="cc-badge cc-held">Sending held — review existing restrictions</span></p>':''}${p?`<p><strong>${esc(CC.interest[p.interest])}</strong> · ${esc(CC.contact[p.contact_preference])}</p><div class="cc-checks">${p.skills.map(s=>`<span class="cc-badge cc-muted">${esc(CC.skills[s])}</span>`).join('')||'<span class="muted">No skills reported</span>'}</div><p class="muted">Responded ${esc(p.responded_at.slice(0,10))} · Self-reported, not verified</p><details><summary>Availability and preferences</summary><p>Start: ${esc(p.availability.replaceAll('_',' ')||'Not given')}<br>Shifts: ${esc(p.shifts.join(', ')||'Not given')}<br>Population: ${esc(p.population)}<br>Preferred work areas: ${esc(p.preferred_locations||'Not given')}<br>Travel: ${p.travel_miles===null?'Not given':esc(p.travel_miles)+' miles'}</p><p>${esc(p.notes)}</p></details>`:''}${c.pending_contact?'<p><span class="cc-badge cc-held">Contact update awaiting review</span></p>':''}<div class="cc-actions"><button class="btn secondary" data-invite="${c.id}" ${held?'disabled title="Review sending restrictions in the outreach workspace first"':''}>Create personal invitation</button><button class="btn secondary" data-revoke="${c.id}">Revoke unused links</button></div><div id="link-${c.id}" role="status"></div></article>`;
  }).join('')||'<p>No candidates match these filters.</p>';
 }
 $('filters').onsubmit=e=>{e.preventDefault();offset=0;activeFilters=readFilters();search().catch(fail);};
 $('clear').onclick=()=>{$('filters').reset();offset=0;activeFilters=readFilters();search().catch(fail);};
 $('prev').onclick=()=>{offset=Math.max(0,offset-50);search().catch(fail);};$('next').onclick=()=>{offset+=50;search().catch(fail);};
 $('results').onclick=async e=>{
  const btn=e.target.closest('button');if(!btn)return;
  const id=btn.dataset.invite||btn.dataset.revoke;if(!id)return;btn.disabled=true;
  try{
   if(btn.dataset.invite){const c=rows.find(c=>c.id===id);if(!c||c.unsubscribed||c.status==='do_not_use')throw Error('Review sending restrictions first.');
    const url=await CC.invitation(client,id);const container=$('link-'+id);container.replaceChildren();const label=document.createElement('p');label.textContent='Personal link — expires in 30 days. Nothing has been sent.';const input=document.createElement('input');input.className='cc-link';input.readOnly=true;input.value=url;input.setAttribute('aria-label','Personal invitation link');const copy=document.createElement('button');copy.className='btn secondary';copy.textContent='Copy link';copy.onclick=async()=>{try{await navigator.clipboard.writeText(url);copy.textContent='Copied';}catch{input.focus();input.select();copy.textContent='Select and copy the link above';}};container.append(label,input,copy);
   }else{const {error}=await client.from('complex_care_invitations').update({revoked:true}).eq('candidate_id',id).is('submitted_at',null);if(error)throw error;$('link-'+id).textContent='Unused links revoked.';}
  }catch(err){fail(err);}finally{btn.disabled=false;}
 };
 async function reviews(){
  $('review-panel').hidden=false;$('review-rows').textContent='Loading…';$('review-panel').scrollIntoView({behavior:'smooth'});
  const {data,error}=await client.from('complex_care_responses').select('id,submitted_at,original_contact,proposed_contact,candidates(first_name,last_name)').eq('review_status','pending').order('submitted_at').limit(100);
  if(error){$('review-rows').textContent='Unable to load updates.';throw error;}
  $('review-rows').innerHTML=data.map(r=>`<article class="card"><h3>${esc([r.candidates?.first_name,r.candidates?.last_name].filter(Boolean).join(' '))}</h3><p class="muted">Received ${esc(r.submitted_at.slice(0,10))}</p><div class="cc-table"><table><thead><tr><th>Detail</th><th>At time of response</th><th>Proposed value</th></tr></thead><tbody>${Object.entries(r.proposed_contact).map(([k,v])=>`<tr><td>${esc(k)}</td><td>${esc(r.original_contact[k]||'Not recorded')}</td><td>${esc(v)}</td></tr>`).join('')}</tbody></table></div><label><input type="checkbox" id="confirm-${r.id}"> I have checked these changes with the nurse.</label><div class="cc-actions"><button class="btn" data-review="${r.id}" data-accept="true">Accept changes</button><button class="btn secondary" data-review="${r.id}" data-accept="false">Keep existing details</button></div></article>`).join('')||'<p>No contact updates awaiting review.</p>';
  if(data.length===100)$('review-rows').insertAdjacentHTML('beforeend','<p>Showing the oldest 100 updates. Review these, then refresh for the next set.</p>');
 }
 $('reviews').onclick=()=>reviews().catch(fail);$('close-reviews').onclick=()=>{$('review-panel').hidden=true;};
 $('review-rows').onclick=async e=>{const btn=e.target.closest('[data-review]');if(!btn)return;const accept=btn.dataset.accept==='true';if(accept&&!$('confirm-'+btn.dataset.review).checked){fail(Error('Check the changes with the nurse and tick the confirmation first.'));return;}btn.disabled=true;try{const {error}=await client.rpc('review_complex_care_contact',{p_response:btn.dataset.review,p_accept:accept});if(error)throw error;await reviews();await search();}catch(err){fail(err);btn.disabled=false;}};
 client.auth.onAuthStateChange((event,session)=>{if(event==='SIGNED_OUT'||!session){sequence++;rows=[];$('results').replaceChildren();$('review-rows').replaceChildren();$('workspace').hidden=true;$('signin').hidden=false;}});
 try{const {data:{session},error}=await client.auth.getSession();if(error)throw error;if(!session){$('message').textContent='';$('signin').hidden=false;return;}
  const {data:allowed,error:accessError}=await client.rpc('can_access_candidate_sector',{s:'nursing_urgent'});if(accessError)throw accessError;if(!allowed)throw Error('Your account does not have access to Urgent Nursing candidates.');$('workspace').hidden=false;activeFilters=readFilters();await search();
 }catch(e){fail(e);}
})();
