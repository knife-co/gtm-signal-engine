-- p3_tech_scan_error_backoff (applied 2026-10-18)

-- Health check 18 Oct: dead domains were retried every day forever. Now: daily retry for the first 3 errors in a row, then weekly.
create or replace view companies_to_scan as
SELECT c.company_key, c.company_name, c.domain
FROM icp_companies c
LEFT JOIN LATERAL (SELECT s.scanned_at, s.html_status, s.detector_version
                   FROM tech_scans s WHERE s.company_key = c.company_key
                   ORDER BY s.scanned_at DESC LIMIT 1) last ON true
LEFT JOIN LATERAL (SELECT count(*) AS n
                   FROM (SELECT s.html_status FROM tech_scans s WHERE s.company_key = c.company_key
                         ORDER BY s.scanned_at DESC LIMIT 3) r
                   WHERE r.html_status = 'error') errs ON true
WHERE c.domain IS NOT NULL AND (
     last.scanned_at IS NULL
  OR last.detector_version < (SELECT max(detector_version) FROM tech_scans)
  OR (last.html_status = 'ok' AND last.scanned_at < now() - interval '7 days')
  OR (last.html_status = ANY (ARRAY['blocked','robots_disallowed','not_html']) AND last.scanned_at < now() - interval '30 days')
  OR (last.html_status = 'error' AND errs.n < 3 AND last.scanned_at < now() - interval '1 day')
  OR (last.html_status = 'error' AND errs.n >= 3 AND last.scanned_at < now() - interval '7 days'))
ORDER BY last.scanned_at NULLS FIRST, c.icp_score DESC NULLS LAST;
