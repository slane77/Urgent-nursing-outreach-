'use strict';
(async()=>{
 const form=document.getElementById('interest-form'),message=document.getElementById('message'),submitMessage=document.getElementById('submit-message');
 const token=new URLSearchParams(location.hash.slice(1)).get('invite')||'';
 const api=async body=>{const r=await fetch(window.CONFIG.SUPABASE_URL+'/functions/v1/complex-care-response',{method:'POST',headers:{'Content-Type':'application/json',apikey:window.CONFIG.SUPABASE_ANON_KEY},body:JSON.stringify({token,...body})});const data=await r.json();if(!r.ok)throw Error(data.error||'Unable to save. Please retry.');return data;};
 document.getElementById('skills').innerHTML=Object.entries(CC.skills).map(([k,v])=>`<label><input type="checkbox" name="skills" value="${k}">${v}</label>`).join('');
 const details=document.getElementById('skill-details');
 details.innerHTML=Object.entries(CC.skills).map(([k,v])=>`<fieldset id="detail-${k}" hidden><legend>${CC.escape(v)} (optional)</legend><div class="cc-grid"><label class="cc-field">Last used<select data-skill="${k}" data-field="last_used"><option value="">Not provided</option><option value="within_6_months">Within 6 months</option><option value="6_to_12_months">6 to 12 months ago</option><option value="over_12_months">Over 12 months ago</option></select></label><label class="cc-field">Practice setting<select data-skill="${k}" data-field="setting"><option value="">Not provided</option><option value="home">Home or community</option><option value="hospital">Hospital</option><option value="both">Both</option><option value="other">Other</option></select></label><label class="cc-field">Equipment or devices used<input data-skill="${k}" data-field="equipment" maxlength="200" placeholder="No patient details"></label></div></fieldset>`).join('');
 document.getElementById('skills').onchange=e=>{document.getElementById('detail-'+e.target.value).hidden=!e.target.checked;};
 const privacy=document.getElementById('privacy');
 if(!CC.privacyUrl){message.textContent='This page is being prepared. Please contact your consultant.';return;}privacy.href=CC.privacyUrl;
 if(!/^[a-f0-9]{64}$/.test(token)){message.textContent='Please open the personal invitation link in your email. If it no longer works, ask your consultant for a new one.';return;}
 try{const data=await api({action:'check'});if(data.already_submitted){message.textContent='Thank you — your response has already been received. Contact your consultant if you need to change it.';return;}message.textContent='Your personal invitation is ready.';form.hidden=false;}catch(e){message.textContent=e.message;return;}
 document.getElementById('interest').onchange=e=>{const skip=e.target.value==='not_interested';document.getElementById('questions').hidden=skip;document.querySelectorAll('#questions input,#questions select,#questions textarea').forEach(el=>el.disabled=skip);};
 form.onsubmit=async e=>{
  e.preventDefault();const button=document.getElementById('submit');button.disabled=true;submitMessage.textContent='Saving…';
  const f=new FormData(form),answers=Object.fromEntries(f);answers.skills=f.getAll('skills');answers.shifts=f.getAll('shifts');answers.travel_miles=f.get('travel_miles')?Number(f.get('travel_miles')):null;
  answers.screening_details={population_experience:f.get('population_experience')||'',notice:f.get('notice')||'',transport:f.get('transport')||'',skill_details:{}};
  for(const skill of answers.skills){const detail={};details.querySelectorAll(`[data-skill="${skill}"]`).forEach(el=>detail[el.dataset.field]=el.value);answers.screening_details.skill_details[skill]=detail;}
  for(const key of ['population_experience','notice','transport'])delete answers[key];
  const contact={};for(const k of ['email','phone','town','postcode'])if(String(f.get('new_'+k)||'').trim())contact[k]=String(f.get('new_'+k)).trim();
  for(const k of Object.keys(answers))if(k.startsWith('new_'))delete answers[k];
  try{await api({action:'submit',answers,contact});form.hidden=true;message.textContent=answers.interest==='not_interested'?'Thank you. We’ve recorded that you’re not currently interested in complex care.':'Thank you — your response is saved. Our team will review your experience and preferences, along with any contact updates.';message.scrollIntoView({behavior:'smooth'});}catch(err){submitMessage.textContent=err.message;submitMessage.className='cc-message cc-error';button.disabled=false;}
 };
})();
