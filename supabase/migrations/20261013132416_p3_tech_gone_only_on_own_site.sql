-- p3_tech_gone_only_on_own_site (applied 2026-10-13)
do $m$
declare src text;
begin
  src := pg_get_functiondef('public.ingest_tech_scan'::regproc);
  src := replace(src,
    'if p_html_status = ''ok'' and p_dns_status = ''ok'' then',
    'if p_html_status = ''ok'' and p_dns_status = ''ok'' and not coalesce(p_redirected_off_domain, false) then');
  src := replace(src, '-- Only trust "tool is gone" when both the homepage and DNS lookups worked.',
    '-- Only trust "tool is gone" when both lookups worked AND we read the company''s own site (not a redirect elsewhere).');
  execute src;
end $m$;
