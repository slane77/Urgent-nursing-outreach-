import { createClient } from 'jsr:@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const SUPABASE_ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!;

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Content-Type': 'application/json',
};

const SOURCE_TAG: Record<string, string> = {
  agency:          'Source: Agency Outreach',
  pharmacy:        'Source: Pharmacy Outreach',
  bms:             'Source: BMS Outreach',
  sterile:         'Source: Sterile Services',
  private_theatre: 'Source: Theatres',
  nhs_staffbank:   'Source: NHS Staff Bank',
  nhs_theatre:     'Source: NHS Theatre',
  camhs:           'Source: CAMHS',
  ahp:             'Source: NHS Jobs AHP',
  nhs_scotland:    'Source: NHS Scotland',
  anp:             'Source: ANP',
  enp:             'Source: ENP',
  care_home:       'Source: Care Home',
};

function applySourceFilter(q: any, source: string) {
  if (source === 'children_homes') return q.ilike('notes', '%Ofsted Register%');
  if (source === 'gp_surgery') {
    return q
      .not('notes', 'ilike', '%Ofsted Register%')
      .not('notes', 'ilike', '%Source: Agency%')
      .not('notes', 'ilike', '%Source: Pharmacy%')
      .not('notes', 'ilike', '%Source: BMS%')
      .not('notes', 'ilike', '%Source: Sterile%')
      .not('notes', 'ilike', '%Source: Private Theatre%')
      .not('notes', 'ilike', '%Source: Theatres%')
      .not('notes', 'ilike', '%Source: NHS Staff Bank%')
      .not('notes', 'ilike', '%Source: NHS Theatre%')
      .not('notes', 'ilike', '%Source: CAMHS%')
      .not('notes', 'ilike', '%Source: NHS Jobs AHP%')
      .not('notes', 'ilike', '%Source: NHS Scotland%')
      .not('notes', 'ilike', '%Source: Care Home%')
      .not('notes', 'ilike', '%Source: ANP%')
      .not('notes', 'ilike', '%Source: ENP%');
  }
  const tag = SOURCE_TAG[source];
  if (tag) return q.ilike('notes', `%${tag}%`);
  return q;
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: CORS });
  if (req.method !== 'POST') return new Response(JSON.stringify({ error: 'Method not allowed' }), { status: 405, headers: CORS });

  // Gateway verification alone also accepts the legacy public anon JWT.
  // Resolve an actual signed-in user before constructing a privileged client.
  const authorization = req.headers.get('Authorization');
  if (!authorization) return new Response(JSON.stringify({ error: 'Not authenticated' }), { status: 401, headers: CORS });
  const userClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: authorization } },
  });
  const { data: { user }, error: authError } = await userClient.auth.getUser();
  if (authError || !user) return new Response(JSON.stringify({ error: 'Not authenticated' }), { status: 401, headers: CORS });
  const { data: profile, error: profileError } = await userClient.from('user_profiles').select('user_id').eq('user_id', user.id).single();
  if (profileError || !profile) return new Response(JSON.stringify({ error: 'An authorised user profile is required' }), { status: 403, headers: CORS });

  const sb = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY);
  const body = await req.json().catch(() => ({}));
  const { action } = body;

  try {

    // ── DASHBOARD STATS ─────────────────────────────────────────────
    if (action === 'dashboard') {
      const today = new Date().toISOString().split('T')[0];
      const dayStart = new Date(); dayStart.setHours(0, 0, 0, 0);
      const weekAgo = new Date(Date.now() - 7*24*60*60*1000).toISOString();
      const monthAgo = new Date(Date.now() - 30*24*60*60*1000).toISOString();

      const [
        allContacts,
        emailable,
        followUpsDue,
        sentToday,
        sentThisWeek,
        sentThisMonth,
        newToday,
        stageNew,
        stageContacted,
        stageResponded,
        stageMeeting,
        stageLive,
        recentSends,
        sendsBySource,
      ] = await Promise.all([
        sb.from('contacts').select('id', { count: 'exact', head: true }),
        sb.from('contacts').select('id', { count: 'exact', head: true })
          .not('email', 'ilike', '%@pending%').neq('email', ''),
        sb.from('contacts').select('id', { count: 'exact', head: true })
          .lte('follow_up_date', today).not('follow_up_date', 'is', null)
          .in('status', ['lead']),
        sb.from('email_sends').select('id', { count: 'exact', head: true })
          .gte('sent_at', dayStart.toISOString()).eq('status', 'sent'),
        sb.from('email_sends').select('id', { count: 'exact', head: true })
          .gte('sent_at', weekAgo).eq('status', 'sent'),
        sb.from('email_sends').select('id', { count: 'exact', head: true })
          .gte('sent_at', monthAgo).eq('status', 'sent'),
        sb.from('contacts').select('id', { count: 'exact', head: true })
          .gte('created_at', dayStart.toISOString()),
        sb.from('contacts').select('id', { count: 'exact', head: true }).eq('stage', 'new'),
        sb.from('contacts').select('id', { count: 'exact', head: true }).eq('stage', 'contacted'),
        sb.from('contacts').select('id', { count: 'exact', head: true }).eq('stage', 'responded'),
        sb.from('contacts').select('id', { count: 'exact', head: true }).eq('stage', 'meeting'),
        sb.from('contacts').select('id', { count: 'exact', head: true }).eq('stage', 'live'),
        // Recent sends with contact info
        sb.from('email_sends')
          .select('sent_at, status, contacts(org, first_name, last_name, email)')
          .eq('status', 'sent')
          .order('sent_at', { ascending: false })
          .limit(8),
        // Emails sent by source (today / 7 days / 30 days), computed in one SQL pass
        sb.rpc('dashboard_sends_by_source'),
      ]);

      return new Response(JSON.stringify({
        totals: {
          all:       allContacts.count || 0,
          emailable: emailable.count   || 0,
          followUpsDue: followUpsDue.count || 0,
          sentToday:     sentToday.count     || 0,
          sentThisWeek:  sentThisWeek.count  || 0,
          sentThisMonth: sentThisMonth.count || 0,
          newToday:      newToday.count      || 0,
        },
        pipeline: {
          new:       stageNew.count       || 0,
          contacted: stageContacted.count || 0,
          responded: stageResponded.count || 0,
          meeting:   stageMeeting.count   || 0,
          live:      stageLive.count      || 0,
        },
        sendsBySource: sendsBySource.data || {},
        recentSends: recentSends.data || [],
      }), { headers: CORS });
    }

    // ── COUNTS ──────────────────────────────────────────────────
    if (action === 'counts') {
      const [all, ch, gp, ahp] = await Promise.all([
        sb.from('contacts').select('id', { count: 'exact', head: true }),
        sb.from('contacts').select('id', { count: 'exact', head: true }).ilike('notes', '%Ofsted Register%'),
        applySourceFilter(sb.from('contacts').select('id', { count: 'exact', head: true }), 'gp_surgery'),
        sb.from('contacts').select('id', { count: 'exact', head: true }).ilike('notes', '%Source: NHS Jobs AHP%'),
      ]);
      return new Response(JSON.stringify({
        all:            all.count  ?? 0,
        children_homes: ch.count   ?? 0,
        gp_surgery:     gp.count   ?? 0,
        ahp:            ahp.count  ?? 0,
        agency: 0, pharmacy: 0, bms: 0, sterile: 0,
        private_theatre: 0, nhs_staffbank: 0, nhs_theatre: 0, camhs: 0,
      }), { headers: CORS });
    }

    // ── QUERY ───────────────────────────────────────────────────
    if (action === 'query') {
      const { source = 'all', status = 'all', stage = 'all', search = '', region = '', page = 1, limit = 50 } = body;
      const offset = (page - 1) * limit;

      let q = sb.from('contacts_with_last_email')
        .select('id,org,first_name,last_name,job_title,email,region,status,stage,follow_up_date,contact_notes,notes,last_emailed_at,email_pending,created_at', { count: 'exact' });

      // Source filter
      q = applySourceFilter(q, source);

      // Status filter
      if (status !== 'all') q = (q as any).eq('status', status);

      // Stage filter  
      if (stage === 'followup') {
        const today = new Date().toISOString().split('T')[0];
        q = (q as any).lte('follow_up_date', today).not('follow_up_date', 'is', null);
      } else if (stage !== 'all') {
        q = (q as any).eq('stage', stage);
      }

      if (search) {
        const esc = search.replace(/[%_]/g, '\\$&');
        q = (q as any).or(`org.ilike.%${esc}%,email.ilike.%${esc}%,first_name.ilike.%${esc}%,last_name.ilike.%${esc}%`);
      }
      if (region) q = (q as any).ilike('region', `%${region}%`);

      const { data, error, count } = await (q as any)
        .order('created_at', { ascending: false })
        .range(offset, offset + limit - 1);

      if (error) throw error;
      return new Response(JSON.stringify({ contacts: data, total: count, page, limit }), { headers: CORS });
    }

    // ── BULK UNSUBSCRIBE ───────────────────────────────────────────
    if (action === 'bulk_unsubscribe') {
      const { ids } = body;
      if (!ids?.length) throw new Error('No IDs');
      const { error } = await sb.from('contacts')
        .update({ status: 'unsubscribed', stage: 'opted_out' }).in('id', ids);
      if (error) throw error;
      return new Response(JSON.stringify({ success: true, updated: ids.length }), { headers: CORS });
    }

    // ── BULK DELETE ────────────────────────────────────────────────
    if (action === 'bulk_delete') {
      const { ids } = body;
      if (!ids?.length) throw new Error('No IDs');
      const { error } = await sb.from('contacts').delete().in('id', ids);
      if (error) throw error;
      return new Response(JSON.stringify({ success: true, deleted: ids.length }), { headers: CORS });
    }

    // ── BULK RESTORE ──────────────────────────────────────────────
    if (action === 'bulk_restore') {
      const { ids } = body;
      if (!ids?.length) throw new Error('No IDs');
      const { error } = await sb.from('contacts')
        .update({ status: 'lead', stage: 'new' }).in('id', ids);
      if (error) throw error;
      return new Response(JSON.stringify({ success: true, restored: ids.length }), { headers: CORS });
    }

    // ── BULK STAGE UPDATE ───────────────────────────────────────
    if (action === 'bulk_stage') {
      const { ids, stage: newStage } = body;
      if (!ids?.length || !newStage) throw new Error('ids and stage required');
      const { error } = await sb.from('contacts').update({ stage: newStage }).in('id', ids);
      if (error) throw error;
      return new Response(JSON.stringify({ success: true, updated: ids.length }), { headers: CORS });
    }

    return new Response(JSON.stringify({ error: 'Unknown action' }), { status: 400, headers: CORS });

  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    return new Response(JSON.stringify({ error: msg }), { status: 500, headers: CORS });
  }
});
