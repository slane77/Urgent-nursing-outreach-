export const hasComplexCareLink = text => /\{\{ComplexCareLink\}\}|«ComplexCareLink»/.test(text || '');

// Called only after the worker checks sender access and existing sending holds.
// No raw invitation token is persisted or returned in the delivery log.
export async function createComplexCareLink(admin, candidate, senderId) {
 if(candidate.sector!=='nursing_urgent'||candidate.status==='do_not_use'||candidate.unsubscribed) return null;
 const {data:profile,error}=await admin.from('candidate_complex_care').select('interest,contact_preference').eq('candidate_id',candidate.id).maybeSingle();
 if(error)throw Error('Unable to check complex care contact preferences');
 if(profile&&(profile.interest==='not_interested'||!['email','phone_email'].includes(profile.contact_preference)))return null;
 const token=Array.from(crypto.getRandomValues(new Uint8Array(32)),b=>b.toString(16).padStart(2,'0')).join('');
 const token_hash=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(token))),b=>b.toString(16).padStart(2,'0')).join('');
 const {error:insertError}=await admin.from('complex_care_invitations').insert({candidate_id:candidate.id,created_by:senderId,token_hash});
 if(insertError)throw Error('Unable to create personal questionnaire link');
 return 'https://urgent-nursing-outreach.vercel.app/complex-care-interest.html#invite='+token;
}
