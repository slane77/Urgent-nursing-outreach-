import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.57.4';
import { validate } from './validation.mjs';
const headers={'Access-Control-Allow-Origin':'*','Access-Control-Allow-Headers':'authorization, apikey, content-type, x-client-info','Access-Control-Allow-Methods':'POST, OPTIONS','Content-Type':'application/json','Cache-Control':'no-store'};
const reply=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers});
// Custom authentication: possession of a 256-bit, hashed, expiring, single-use invitation.
// No candidate identifiers or stored personal information are returned to the browser.
Deno.serve(async(req:Request)=>{
 if(req.method==='OPTIONS') return new Response(null,{headers});
 if(req.method!=='POST') return reply({error:'Method not allowed'},405);
 try {
  // Bound the stream as Content-Length can be absent or forged.
  const reader=req.body?.getReader(); if(!reader) return reply({error:'Missing response'},400);
  const chunks=[]; let size=0;
  while(true){const {done,value}=await reader.read();if(done)break;size+=value.length;if(size>12000){await reader.cancel();return reply({error:'Response too large'},413);}chunks.push(value);}
  const bytes=new Uint8Array(size);let pos=0;for(const chunk of chunks){bytes.set(chunk,pos);pos+=chunk.length;}
  let data;try {data=validate(JSON.parse(new TextDecoder().decode(bytes)));} catch(e){return reply({error:e instanceof Error?e.message:'Invalid response'},400);}
  const digest=await crypto.subtle.digest('SHA-256',new TextEncoder().encode(data.token));
  const hash=Array.from(new Uint8Array(digest),b=>b.toString(16).padStart(2,'0')).join('');
  const admin=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,{auth:{persistSession:false,autoRefreshToken:false}});
  if(data.action==='check') {
   const {data:inv,error}=await admin.from('complex_care_invitations').select('expires_at,revoked,submitted_at').eq('token_hash',hash).maybeSingle();
   if(error) return reply({error:'Unable to check the invitation. Please try again.'},503);
   if(!inv||inv.revoked||new Date(inv.expires_at).getTime()<=Date.now())return reply({error:'This link has expired or is unavailable. Please ask your consultant for a new link.'},410);
   return reply({ok:true,already_submitted:!!inv.submitted_at});
  }
  const {data:result,error}=await admin.rpc('submit_complex_care',{p_hash:hash,p_answers:data.answers,p_contact:data.contact});
  if(error) return reply({error:'We could not save your response. Your link may have expired; please retry or contact your consultant.'},400);
  return reply(result);
 } catch {return reply({error:'Service temporarily unavailable. Please try again.'},503);}
});
