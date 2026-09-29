# Complex care radius search

Adds a town/postcode lookup, explicit centre selection and 1–100 mile slider to the existing combined skills/experience search. Distances are straight-line miles, sorted nearest first. Town geocoding is marked approximate. Candidates without coordinates are excluded only when radius is active and the excluded count is shown. Turning the radius off restores them.

The new `search_complex_care_radius` RPC is SECURITY INVOKER, restricted to authenticated users, and respects existing candidate sector RLS. The original RPC is unchanged. `tests/complex-care-radius.sql` checks radius boundaries, nearest-first ordering, missing coordinates, combined skills and sector isolation in a rolled-back transaction. Place lookup tests cover postcode and ambiguous town results.

Place lookup uses the same Postcodes.io provider already used by the app's postcode radius search. Only the user-entered search centre is looked up by this page. Bulk enrichment of stored candidate postcodes has NOT run: automatic approval review requires specific approval for sending those postcodes to Postcodes.io. At implementation, 133 of the 1,760 ITU COMPLEX CARE records have coordinates; 839 unmapped records contain a postcode (815 distinct values). No coordinates are guessed.

This release does not change the skills catalogue or introduce bulk invitation sending. Individual personal links remain available for candidates who are not held from sending. General mailshots do not yet automatically insert personal complex-care invitation links. No emails are sent by this release.
