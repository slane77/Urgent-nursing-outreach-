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

// This branch (the Day Webster Compliance Portal) points at the dedicated
// "Numa" Supabase project — SEPARATE from the live outreach project
// (Urgent Staffing Outreach), which is untouched.
window.CONFIG = {
  SUPABASE_URL: 'https://heugpopauuhkrimdfrep.supabase.co',
  SUPABASE_ANON_KEY: 'sb_publishable_9ehpkWFt9wtqVf3DfkMuEA_7ZTK3qd9',

  CHAT_ENABLED: true
};
