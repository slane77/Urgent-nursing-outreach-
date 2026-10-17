'use strict';
window.CCTime={
 // Resolve UK wall clock time explicitly, independent of the consultant's device zone.
 iso(value,zone='Europe/London'){
  if(!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/.test(value))throw Error('Enter a complete date and time.');
  const base=Date.parse(value+'Z');if(!Number.isFinite(base)||new Date(base).toISOString().slice(0,16)!==value)throw Error('Invalid date and time.');
  if(zone==='UTC')return new Date(base).toISOString();
  const fmt=new Intl.DateTimeFormat('sv-SE',{timeZone:'Europe/London',year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',hourCycle:'h23'});
  const matches=[base,base-3600000].filter(t=>fmt.format(new Date(t)).replace(' ','T')===value);
  if(matches.length!==1)throw Error('This UK time is missing or occurs twice at the clock change. Select UTC and enter the intended UTC time.');
  return new Date(matches[0]).toISOString();
 },
 format(value){return new Intl.DateTimeFormat('en-GB',{timeZone:'Europe/London',day:'2-digit',month:'short',year:'numeric',hour:'2-digit',minute:'2-digit',timeZoneName:'short'}).format(new Date(value));},
 today(){return new Intl.DateTimeFormat('sv-SE',{timeZone:'Europe/London'}).format(new Date());}
};
