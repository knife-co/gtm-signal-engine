-- p3_health_security_invoker_views (applied 2026-10-18)

-- Health check 18 Oct: views ran with the owner's rights, so the public anon key could read locked tables through them.
-- security_invoker makes each view use the caller's rights; the Edge Functions use service_role and are unaffected.
do $$
declare v text;
begin
  foreach v in array array['signals_scored','account_signal_score','signal_clusters','account_routing','router_today','sf_signal_desired',
    'company_tech_stack','ats_jobs_to_describe','tech_scan_health_v1','tech_scan_health','gtm_stack_profile','tool_adoption',
    'companies_to_scan','tool_added_signals','jobs_for_me','cohort_result'] loop
    execute format('alter view public.%I set (security_invoker = true)', v);
  end loop;
end $$;

-- Pin search_path on functions flagged by the linter
do $$
declare f record;
begin
  for f in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname = any (array['domain_clean','clean_title','backoff_delay_ms','test_backoff_distribution',
             'employee_band','normalize_linkedin','normalize_phone','signals_set_expiry','ingest_tech_scan_v1','ingest_tech_scan','signal_strength',
             'strength_band','sf_signal_payload','sf_signal_record','tier_rank','route_accounts','router_sf_payload','router_sf_record',
             'router_slack_digest','eligibility','role_fit','seniority_fit','portfolio_angle','title_geo_no','cohort_members_locked'])
  loop
    execute format('alter function %s set search_path = public, extensions', f.sig);
  end loop;
end $$;
