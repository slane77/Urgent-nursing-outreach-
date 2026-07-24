// ============================================================================
//  Urgent Nursing Outreach Manager — Configuration
// ============================================================================
//
//  Replace the two YOUR_*_HERE values below with your actual Supabase project
//  details. Find them at: Supabase Dashboard → Project Settings → API
//
//    SUPABASE_URL       = "Project URL"           (e.g. https://abcdefg.supabase.co)
//    SUPABASE_ANON_KEY  = "anon public" key       (long string starting with "eyJ...")
//
//  IMPORTANT:
//  - Both values are SAFE to commit to a public GitHub repo. The database is
//    protected by Row Level Security policies, not by key secrecy.
//  - NEVER paste the "service_role" key here. That one bypasses all security
//    and would expose all your data publicly. Only use anon/public.
//
// ============================================================================

window.CONFIG = {
  SUPABASE_URL: 'https://udttpnaenmyxviuiwxqw.supabase.co',
  SUPABASE_ANON_KEY: 'sb_publishable_fDVJY1ZTiBWcTE9cTD7GBw_A6VYda5x',

  // Public "Prefer to chat?" registration agent. Disabled until the chat-intake
  // function is built (its backend does not yet exist). Flip to true once the
  // chat-intake function is deployed and the ANTHROPIC_API_KEY secret is set.
  CHAT_ENABLED: false
};
