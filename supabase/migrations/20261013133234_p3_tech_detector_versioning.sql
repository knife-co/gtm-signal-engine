-- p3_tech_detector_versioning (applied 2026-10-13)
-- 1. Know WHEN each signature was added, so adding a new signature never looks like every company "adding" that tool.
alter table tech_signatures add column if not exists created_at timestamptz not null default now();
-- 2. Know WHICH version of the detector made each scan. Scans are only compared with scans from the same version.
alter table tech_scans add column if not exists detector_version int not null default 1;
alter table tech_scans add column if not exists gtm_containers text[];

-- keep the v1 function for history, under a new name (non-destructive)
alter function ingest_tech_scan(bigint, text, text, text, text, int, text, boolean, int, jsonb, text) rename to ingest_tech_scan_v1;

create or replace function ingest_tech_scan(
  p_run_id bigint, p_company_key text, p_domain text,
  p_html_status text, p_dns_status text, p_http_status int, p_final_url text,
  p_redirected_off_domain boolean, p_html_bytes int,
  p_detections jsonb, p_error text, p_detector_version int, p_gtm_containers text[] default null
) returns jsonb language plpgsql as $$
declare
  v_baseline boolean;
  v_det record;
  v_new_signals int := 0;
  v_tools int := 0;
  v_existing boolean;
  v_name text;
  v_prev_scan timestamptz;
  v_sig_since timestamptz;
begin
  -- Baseline = no earlier successful homepage scan BY THIS DETECTOR VERSION.
  select max(scanned_at) into v_prev_scan from tech_scans
   where company_key = p_company_key and html_status = 'ok' and detector_version = p_detector_version;
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
    -- "existing" = seen before by this same detector version
    select true into v_existing from tech_stack
     where company_key = p_company_key and tool = v_det.tool and last_seen >= coalesce(v_prev_scan, 'infinity');
    -- when did we first have an enabled, GTM-relevant signature for this tool?
    select min(created_at) into v_sig_since from tech_signatures where tool = v_det.tool and gtm_relevant and enabled;

    insert into tech_stack(company_key, tool, category, seen_in_baseline, methods, evidence)
    values (p_company_key, v_det.tool, v_det.category, v_baseline, v_det.methods, v_det.ev)
    on conflict (company_key, tool) do update
      set last_seen = now(), active = true, methods = excluded.methods, evidence = excluded.evidence;

    -- tool_added only when ALL are true:
    --  * we had a clean earlier scan from the same detector version (not a baseline)
    --  * that scan did not see this tool
    --  * we could already detect this tool at the time of that earlier scan (signature older than it)
    --  * the homepage read worked and the site did not redirect to another company
    --  * the tool is one a GTM team cares about
    if not v_baseline and v_existing is null and p_html_status = 'ok'
       and not coalesce(p_redirected_off_domain, false)
       and v_sig_since is not null and v_sig_since < v_prev_scan then
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
                                 'final_url', p_final_url, 'detector_version', p_detector_version))
      on conflict (signal_type, ref) do nothing;
      if found then v_new_signals := v_new_signals + 1; end if;
    end if;
  end loop;

  -- Only trust "tool is gone" when both lookups worked AND we read the company's own site.
  if p_html_status = 'ok' and p_dns_status = 'ok' and not coalesce(p_redirected_off_domain, false) then
    update tech_stack t set active = false
     where t.company_key = p_company_key and t.active
       and not exists (select 1 from jsonb_array_elements(coalesce(p_detections,'[]'::jsonb)) d
                       where d->>'tool' = t.tool);
  end if;

  insert into tech_scans(run_id, company_key, domain, html_status, dns_status, http_status, final_url,
                         redirected_off_domain, html_bytes, is_baseline, tools_found, error, detector_version, gtm_containers)
  values (p_run_id, p_company_key, p_domain, p_html_status, p_dns_status, p_http_status, p_final_url,
          coalesce(p_redirected_off_domain,false), p_html_bytes,
          v_baseline and p_html_status = 'ok', v_tools, p_error, p_detector_version, p_gtm_containers);

  return jsonb_build_object('tools', v_tools, 'new_signals', v_new_signals, 'baseline', v_baseline);
end $$;

-- 3. A new detector version makes every company due again (so all get a clean baseline under the new rules).
create or replace view companies_to_scan as
select c.company_key, c.company_name, c.domain
from icp_companies c
left join lateral (
  select s.scanned_at, s.html_status, s.detector_version from tech_scans s
  where s.company_key = c.company_key order by s.scanned_at desc limit 1
) last on true
where c.domain is not null
  and (last.scanned_at is null
       or last.detector_version < (select max(detector_version) from tech_scans)
       or (last.html_status = 'ok' and last.scanned_at < now() - interval '7 days')
       or (last.html_status in ('blocked','robots_disallowed','not_html') and last.scanned_at < now() - interval '30 days')
       or (last.html_status = 'error' and last.scanned_at < now() - interval '1 day'))
order by last.scanned_at nulls first, c.icp_score desc nulls last;

-- 4. Tighter RB2B signature (the loose one matched "rb2b" inside a random string). Old one kept but disabled.
insert into tech_signatures(tool, category, method, pattern, confidence, gtm_relevant, note)
values ('RB2B','intent_abm','html','b2bjsstore|reb2b\.js|rb2b\.com|RB2B_KEY','high',true,'RB2B person-level visitor ID (tightened 13 Oct)')
on conflict (tool, method, pattern) do nothing;
update tech_signatures set enabled = false, note = note || ' [disabled 13 Oct: matched random strings]'
 where tool = 'RB2B' and pattern = 'b2bjsstore|rb2b';
