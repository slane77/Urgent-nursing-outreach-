export const STOPPED_MAILSHOTS = new Set(['93c3ea54-e62d-4705-b95d-3e47e7f8c060']);
export const CANCEL_DETAIL = 'Cancellation requested before dispatch';
export const MAX_RECIPIENTS = 500;
export const SOURCE_TAGS = {
  children_homes:'Ofsted Register', agency:'Source: Agency Outreach',
  ahp:'Source: NHS Jobs AHP', nhs_scotland:'Source: NHS Scotland', hse:'Source: HSE',
  private_theatre:'Source: Theatres', care_home:'Source: Care Home',
  bms:'Source: BMS Outreach', sterile:'Source: Sterile Services',
  nhs_staffbank:'Source: NHS Staff Bank', camhs:'Source: CAMHS',
  anp:'Source: ANP', enp:'Source: ENP', foi:'Source: FOI'
};

export function campaignSafetyError(job, total) {
  if (job.payload?.cancelled || STOPPED_MAILSHOTS.has(job.id)) return 'Stopped at account owner request';
  if (!Number.isInteger(total) || total < 1 || total > MAX_RECIPIENTS)
    return 'Campaign blocked: maximum 500 recipients; create a smaller reviewed selection';
  if (job.audience === 'contacts') {
    const source=job.payload?.source;
    if (source !== 'gp_surgery' && !Object.hasOwn(SOURCE_TAGS,source))
      return 'Campaign blocked: choose one specific contact source; all-source sending is disabled';
    if (/^GP Surgery\b/i.test(job.template_name || '') && source !== 'gp_surgery')
      return 'Campaign blocked: GP Surgery templates can only target GP Surgeries';
  }
  return null;
}

export function matchesContactSource(contact, source, subSource) {
  const notes=String(contact.notes || '').toLowerCase();
  // Legacy GP records predate source tags. Any other tagged source is excluded.
  if(source==='gp_surgery') {
    if(notes.includes('ofsted register')) return false;
    const tags=[...notes.matchAll(/source:\s*([^|;\n\r]+)/g)].map(m=>m[1].trim());
    return tags.every(t=>t.startsWith('gp surgery'));
  }
  const tag=SOURCE_TAGS[source];
  if(!tag || !notes.includes(tag.toLowerCase())) return false;
  return !subSource || subSource==='all' || String(contact.department || '')===subSource;
}

// Re-read at the provider boundary: a previously claimed item may have been cancelled.
export async function mayDispatch(admin, body, recipientId) {
  const match=/^queue_([a-f0-9-]{36})$/i.exec(body.batchId || '');
  if(!match || STOPPED_MAILSHOTS.has(match[1])) return false;
  const {data:job,error:jobError}=await admin.from('outreach_mailshots').select('cancelled:payload->>cancelled').eq('id',match[1]).single();
  if(jobError || !job || job.cancelled==='true' || job.cancelled===true) return false;
  const {data,error}=await admin.from('outreach_mailshot_items').select('status,detail')
    .eq('mailshot_id',match[1]).eq('recipient_id',recipientId).maybeSingle();
  return !error && data?.status==='processing' && data.detail!==CANCEL_DETAIL;
}

export function hasContactSourceAccess(profile, source) {
  if(!profile || (source!=='gp_surgery' && !Object.hasOwn(SOURCE_TAGS,source))) return false;
  return profile.role==='admin' || (Array.isArray(profile.allowed_sources) && profile.allowed_sources.includes(source));
}
