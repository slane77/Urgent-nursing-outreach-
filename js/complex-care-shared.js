'use strict';
window.CC={
 skills:{tracheostomy:'Tracheostomy care',invasive_ventilation:'Invasive ventilation',noninvasive_ventilation:'Non-invasive ventilation',suction:'Airway suctioning',peg:'Enteral / PEG feeding',neurological:'Complex neurological care',seizures:'Seizure management',home_care:'Independent home care'},
 interest:{now:'Interested now',later:'Interested later',discuss:'Wants a conversation',not_interested:'Not currently interested'},
 experience:{current:'Currently in complex care',previous:'Previous complex care experience',none:'Interested in transitioning',unknown:'Experience not provided'},
 contact:{phone_email:'Phone or email',phone:'Phone only',email:'Email only',none:'No follow-up requested'},
 escape:s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])),
 // Set to the organisation’s published candidate privacy notice before launch.
 privacyUrl:'https://www.daywebster.com/privacy-policy/',
 async invitation(client,candidateId){
  const token=Array.from(crypto.getRandomValues(new Uint8Array(32)),b=>b.toString(16).padStart(2,'0')).join('');
  const hash=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(token))),b=>b.toString(16).padStart(2,'0')).join('');
  const {error}=await client.from('complex_care_invitations').insert({candidate_id:candidateId,token_hash:hash});
  if(error)throw Error(error.message);
  const url=new URL('complex-care-interest.html',location.href);url.hash='invite='+token;return url.href;
 }
};
