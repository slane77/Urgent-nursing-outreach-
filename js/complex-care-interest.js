'use strict';
(async()=>{
 const form=document.getElementById('interest-form'),message=document.getElementById('message'),submitMessage=document.getElementById('submit-message');
 const token=new URLSearchParams(location.hash.slice(1)).get('invite')||'';
 const api=async body=>{const r=await fetch(window.CONFIG.SUPABASE_URL+'/functions/v1/complex-care-response',{method:'POST',headers:{'Content-Type':'application/json',apikey:window.CONFIG.SUPABASE_ANON_KEY},body:JSON.stringify({token,...body})});const data=await r.json();if(!r.ok)throw Error(data.error||'Unable to save. Please retry.');return data;};
 document.getElementById('skills').innerHTML=Object.entries(CC.skills).map(([k,v])=>`<label><input type="checkbox" name="skills" value="${k}">${v}</label>`).join('');
 const privacy=document.getElementById('privacy');
 if(!CC.privacyUrl){message.textContent='This page is being prepared. Please contact your consultant.';return;}privacy.href=CC.privacyUrl;
 if(!/^[a-f0-9]{64}$/.test(token)){message.textContent='Please open the personal invitation link in your email. If it no longer works, ask your consultant for a new one.';return;}
 try{const data=await api({action:'check'});if(data.already_submitted){message.textContent='Thank you — your response has already been received. Contact your consultant if you need to change it.';return;}message.textContent='Your personal invitation is ready.';form.hidden=false;}catch(e){message.textContent=e.message;return;}
 document.getElementById('interest').onchange=e=>{const skip=e.target.value==='not_interested';document.getElementById('questions').hidden=skip;document.querySelectorAll('#questions input,#questions select,#questions textarea').forEach(el=>el.disabled=skip);};
 form.onsubmit=async e=>{
  e.preventDefault();const button=document.getElementById('submit');button.disabled=true;submitMessage.textContent='Saving…';
  const f=new FormData(form),answers=Object.fromEntries(f);answers.skills=f.getAll('skills');answers.shifts=f.getAll('shifts');answers.travel_miles=f.get('travel_miles')?Number(f.get('travel_miles')):null;
  const contact={};for(const k of ['email','phone','town','postcode'])if(String(f.get('new_'+k)||'').trim())contact[k]=String(f.get('new_'+k)).trim();
  for(const k of Object.keys(answers))if(k.startsWith('new_'))delete answers[k];
  try{await api({action:'submit',answers,contact});form.hidden=true;message.textContent=answers.interest==='not_interested'?'Thank you. We’ve recorded that you’re not currently interested in complex care.':'Thank you — your response is saved. Our team will review your experience and preferences, along with any contact updates.';message.scrollIntoView({behavior:'smooth'});}catch(err){submitMessage.textContent=err.message;submitMessage.className='cc-message cc-error';button.disabled=false;}
 };
})();
