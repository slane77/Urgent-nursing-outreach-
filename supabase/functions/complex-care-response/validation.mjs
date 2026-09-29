export const SKILLS = ['tracheostomy','invasive_ventilation','noninvasive_ventilation','suction','peg','neurological','seizures','home_care'];
export function validate(body) {
 if (!body || typeof body !== 'object' || !/^[a-f0-9]{64}$/.test(body.token || '')) throw Error('This invitation link is invalid.');
 if (!['check','submit'].includes(body.action)) throw Error('Invalid action.');
 if (body.action === 'check') return {token:body.token,action:'check'};
 const a=body.answers;
 if (!a || typeof a!=='object') throw Error('Please complete the questions.');
 const choice=(key,values)=> { if (!values.includes(a[key])) throw Error('Please select '+key.replaceAll('_',' ')+'.'); return a[key]; };
 const short=(key,max=200)=> { const s=a[key]??''; if(typeof s!=='string'||s.length>max) throw Error('Please shorten '+key.replaceAll('_',' ')+'.'); return s.trim(); };
 const list=(key,values)=> { if(!Array.isArray(a[key])||a[key].length>values.length||a[key].some(v=>!values.includes(v))) throw Error('Invalid '+key+'.'); return [...new Set(a[key])]; };
 const interest=choice('interest',['now','later','discuss','not_interested']);
 const contact_preference=interest==='not_interested'?'none':choice('contact_preference',['phone_email','phone','email']);
 let answers={interest,contact_preference,experience:'unknown',population:'unknown',skills:[],shifts:[],availability:'',preferred_locations:'',travel_miles:null,notes:''};
 if (interest!=='not_interested') {
  answers={...answers,experience:choice('experience',['current','previous','none']),population:choice('population',['adults','children','both','unsure']),
   skills:list('skills',SKILLS),shifts:list('shifts',['days','nights','weekends']),
   availability:choice('availability',['now','within_month','later','exploring']),preferred_locations:short('preferred_locations'),notes:short('notes',1000)};
  if(a.travel_miles!==null && a.travel_miles!==undefined && a.travel_miles!=='') {
   if(typeof a.travel_miles!=='number'||!Number.isInteger(a.travel_miles)||a.travel_miles<0||a.travel_miles>500) throw Error('Travel distance must be 0–500 miles.');
   answers.travel_miles=a.travel_miles;
  }
 }
 const input=body.contact??{},contact={};
 if(typeof input!=='object'||Array.isArray(input)||Object.keys(input).some(k=>!['email','phone','town','postcode'].includes(k))) throw Error('Invalid contact update.');
 for(const [key,value] of Object.entries(input)) {
  if(typeof value!=='string'||value.length>254) throw Error('Invalid contact update.');
  const v=value.trim(); if(!v) continue;
  if(key==='email'&&!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(v)) throw Error('Please check the updated email address.');
  if(key==='phone'&&!/^\+?[\d ()-]{7,30}$/.test(v)) throw Error('Please check the updated phone number.');
  if(key==='postcode'&&!/^(GIR 0AA|[A-Z]{1,2}\d[A-Z\d]? ?\d[A-Z]{2})$/i.test(v)) throw Error('Please enter a full UK postcode.');
  if(key==='town'&&v.length>100) throw Error('Please shorten the town.');
  contact[key]=key==='email'?v.toLowerCase():key==='postcode'?v.toUpperCase().replace(/\s/g,'').replace(/(.{3})$/,' $1'):v;
 }
 return {token:body.token,action:'submit',answers,contact};
}
