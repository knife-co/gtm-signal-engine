-- p3_tech_no_signal_when_redirected (applied 2026-10-13)
create or replace function ingest_tech_scan(
  p_run_id bigint, p_company_key text, p_domain text,
  p_html_status text, p_dns_status text, p_http_status int, p_final_url text,
  p_redirected_off_domain boolean, p_html_bytes int,
  p_detections jsonb,
  p_error text default null
) returns jsonb language plpgsql as $$
declare
  v_baseline boolean;
  v_det record;
  v_new_signals int := 0;
  v_tools int := 0;
  v_existing boolean;
  v_name text;
  v_prev_scan timestamptz;
begin
  -- Baseline = no earlier successful homepage scan. On a baseline every tool is "already there".
  select max(scanned_at) into v_prev_scan from tech_scans
   where company_key = p_company_key and html_status = 'ok';
  v_baseline := v_prev_scan is null;
  select company_name into v_name from icp_companies where company_key = p_company_key;

  for v_det in
    select d->>'tool' tool, min(d->>'category') category,
           array_agg(distinct d->>'method') methods,
           jsonb_agg(jsonb_build_object('method', d->>'method', 'evidence', d->>'evidence')) ev
    from jsonb_array_elements(coalesce(p_detections,'[]'::jsonb)) d
    group by 1
  loop
    v_tools := v_tools + 1;
    v_existing := null;
    select true into v_existing from tech_stack where company_key = p_company_key and tool = v_det.tool;

    insert into tech_stack(company_key, tool, category, seen_in_baseline, methods, evidence)
    values (p_company_key, v_det.tool, v_det.category, v_baseline, v_det.methods, v_det.ev)
    on conflict (company_key, tool) do update
      set last_seen = now(), active = true, methods = excluded.methods, evidence = excluded.evidence;

    -- tool_added only when: we had a clean baseline before, this tool was never seen, the homepage read worked,
    -- the site did NOT redirect to another company's domain, and the tool is one a GTM team would care about.
    if not v_baseline and v_existing is null and p_html_status = 'ok'
       and not coalesce(p_redirected_off_domain, false)
       and exists (select 1 from tech_signatures where tool = v_det.tool and gtm_relevant) then
      insert into signals(signal_type, company_name, company_key, domain, ref, detected_at, event_at,
                          window_days, who, angle, channel, evidence)
      values ('tool_added', v_name, p_company_key, p_domain,
              'tool_added:' || p_company_key || ':' || lower(v_det.tool),
              now(), now(), 90,
              'RevOps lead or whoever owns the GTM tools',
              'Integration: ' || v_det.tool || ' (' || v_det.category || ') is new on the site. It has to be connected to the CRM, cleaned and adopted.',
              'Email with one specific integration idea',
              jsonb_build_object('tool', v_det.tool, 'category', v_det.category, 'methods', v_det.methods,
                                 'evidence', v_det.ev, 'not_seen_at', v_prev_scan, 'seen_at', now(),
                                 'final_url', p_final_url))
      on conflict (signal_type, ref) do nothing;
      if found then v_new_signals := v_new_signals + 1; end if;
    end if;
  end loop;

  -- Only trust "tool is gone" when both the homepage and DNS lookups worked.
  if p_html_status = 'ok' and p_dns_status = 'ok' then
    update tech_stack t set active = false
     where t.company_key = p_company_key and t.active
       and not exists (select 1 from jsonb_array_elements(coalesce(p_detections,'[]'::jsonb)) d
                       where d->>'tool' = t.tool);
  end if;

  insert into tech_scans(run_id, company_key, domain, html_status, dns_status, http_status, final_url,
                         redirected_off_domain, html_bytes, is_baseline, tools_found, error)
  values (p_run_id, p_company_key, p_domain, p_html_status, p_dns_status, p_http_status, p_final_url,
          coalesce(p_redirected_off_domain,false), p_html_bytes,
          v_baseline and p_html_status = 'ok', v_tools, p_error);

  return jsonb_build_object('tools', v_tools, 'new_signals', v_new_signals, 'baseline', v_baseline);
end $$;
