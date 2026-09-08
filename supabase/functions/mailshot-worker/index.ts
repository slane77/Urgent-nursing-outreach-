import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { deliverRecipient } from './delivery.ts';
const admin = createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
Deno.serve(async (req: Request) => {
  if(req.method!=='POST') return new Response('Method not allowed',{status:405});
  const secret=req.headers.get('x-worker-secret');
  if(!secret) return new Response('Unauthorised',{status:401});
  const {data:items,error}=await admin.rpc('claim_outreach_mailshot',{p_secret:secret});
  if(error) return new Response('Worker could not claim work',{status:403});
  if(!items?.length) return Response.json({processed:0});
  const jobs = new Map();
  for(const id of new Set(items.map((i:any)=>i.mailshot_id))) {
    const {data:job,error}=await admin.from('outreach_mailshots').select('*').eq('id',id).single();
    if(error) continue;
    const {data: {user}}=await admin.auth.admin.getUserById(job.owner_id);
    jobs.set(id,{job,user});
  }
  let cursor=0, processed=0;
  const started=Date.now();
  await Promise.all(Array.from({length:5},async()=>{
    while(cursor<items.length) {
      if(Date.now()-started>90000) break;
      const item=items[cursor++];
      const entry=jobs.get(item.mailshot_id);
      let status='uncertain',detail='Unable to confirm delivery';
      try {
        if(!entry) throw new Error('Campaign lookup unavailable');
        if(!entry.user) {status='skipped';detail='Sender account no longer exists';}
        else {
          const {job,user}=entry;
          const payload={...job.payload,audience:job.audience,batchId:'queue_'+job.id,
            [job.audience==='candidates'?'candidateIds':'contactIds']:[item.recipient_id]};
          const response=await deliverRecipient(new Request('https://worker.internal/deliver',{method:'POST',body:JSON.stringify(payload)}),user,job.payload.template);
          const result=await response.json();
          const recipient=result.results?.[0];
          if(recipient?.ok) {status='sent';detail='Accepted by Brevo';}
          else if(recipient?.error==='skipped'||recipient?.error==='no access'||response.status===403||response.status===404) {status='skipped';detail=recipient?.error||result.error;}
          else if(recipient?.error?.startsWith('Brevo ')) {status='failed';detail=recipient.error;}
          else if(result.total===0) {status='skipped';detail='Recipient no longer exists';}
          else {detail=result.error||recipient?.error||detail;}
        }
      } catch(e) {detail=String(e);}
      const {error}=await admin.from('outreach_mailshot_items').update({status,detail:String(detail).slice(0,300),finished_at:new Date().toISOString()}).eq('id',item.id).eq('status','processing');
      if(error) console.error('Could not record queue outcome',item.id);
      else processed++;
    }
  }));
  // These rows have not reached the provider and are safe to return to the queue.
  const untouched=items.slice(cursor).map((i:any)=>i.id);
  if(untouched.length) await admin.from('outreach_mailshot_items').update({status:'queued',claimed_at:null}).in('id',untouched).eq('status','processing');
  return Response.json({processed});
});
