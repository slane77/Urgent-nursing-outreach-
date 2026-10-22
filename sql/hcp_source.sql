-- Adds the "Homecare Providers – Complex Care Clients" source (notes tag
-- 'Source: HCP Complex Care') to the dashboard counting functions, so the
-- new tab shows counts and HCP sends are reported as their own bucket.
-- Rewrites the existing function bodies in place by string substitution so
-- nothing else about them changes.
DO $$
DECLARE d text;
BEGIN
  d := pg_get_functiondef('public.dashboard_counts()'::regprocedure);

  d := replace(d,
    E'    (notes ILIKE \'%Source: FOI%\')              AS is_foi,\n',
    E'    (notes ILIKE \'%Source: FOI%\')              AS is_foi,\n    (notes ILIKE \'%Source: HCP Complex Care%\') AS is_hcp,\n');

  d := replace(d,
    E'       notes NOT ILIKE \'%Source: FOI%\'\n    )) AS is_gp',
    E'       notes NOT ILIKE \'%Source: FOI%\' AND\n       notes NOT ILIKE \'%Source: HCP Complex Care%\'\n    )) AS is_gp');

  d := replace(d,
    E'    \'foi\',             count(*) FILTER (WHERE is_foi)\n  ),',
    E'    \'foi\',             count(*) FILTER (WHERE is_foi),\n    \'hcp\',             count(*) FILTER (WHERE is_hcp)\n  ),');

  d := replace(d,
    E'      \'unsubscribed\', count(*) FILTER (WHERE is_foi AND status=\'unsubscribed\'))\n  ),',
    E'      \'unsubscribed\', count(*) FILTER (WHERE is_foi AND status=\'unsubscribed\')),\n    \'hcp\', jsonb_build_object(\n      \'lead\', count(*) FILTER (WHERE is_hcp AND status=\'lead\'),\n      \'live\', count(*) FILTER (WHERE is_hcp AND status=\'live\'),\n      \'unsubscribed\', count(*) FILTER (WHERE is_hcp AND status=\'unsubscribed\'))\n  ),');

  d := replace(d,
    E'      \'foi\',             count(*) FILTER (WHERE bucket = \'foi\')\n    )',
    E'      \'foi\',             count(*) FILTER (WHERE bucket = \'foi\'),\n      \'hcp\',             count(*) FILTER (WHERE bucket = \'hcp\')\n    )');

  d := replace(d,
    E'        WHEN notes ILIKE \'%Source: FOI%\'             THEN \'foi\'\n',
    E'        WHEN notes ILIKE \'%Source: FOI%\'             THEN \'foi\'\n        WHEN notes ILIKE \'%Source: HCP Complex Care%\' THEN \'hcp\'\n');

  IF d NOT LIKE '%is_hcp%' OR d NOT LIKE '%bucket = ''hcp''%' THEN
    RAISE EXCEPTION 'dashboard_counts substitution did not match';
  END IF;
  EXECUTE d;

  d := pg_get_functiondef('public.dashboard_sends_by_source()'::regprocedure);
  d := replace(d,
    E'      when c.notes ilike \'%Source: FOI%\' then \'foi\'\n',
    E'      when c.notes ilike \'%Source: FOI%\' then \'foi\'\n      when c.notes ilike \'%Source: HCP Complex Care%\' then \'hcp\'\n');
  IF d NOT LIKE '%then ''hcp''%' THEN
    RAISE EXCEPTION 'dashboard_sends_by_source substitution did not match';
  END IF;
  EXECUTE d;
END $$;

-- Access: Homecare Providers – Complex Care Clients contacts are visible and
-- editable only to scott.lane@daywebster.com (applied as migration
-- restrict_hcp_complex_care_contacts_to_scott). The contacts_with_last_email view
-- now runs as the caller so row security applies through it too.
-- alter view public.contacts_with_last_email set (security_invoker = true);
-- create policy hcp_complex_care_scott_only on public.contacts as restrictive for all to authenticated
--   using (coalesce(notes,'') not ilike '%Source: HCP Complex Care%' or lower(auth.jwt()->>'email') = 'scott.lane@daywebster.com')
--   with check (coalesce(notes,'') not ilike '%Source: HCP Complex Care%' or lower(auth.jwt()->>'email') = 'scott.lane@daywebster.com');
