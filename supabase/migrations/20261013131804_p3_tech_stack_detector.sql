-- p3_tech_stack_detector (applied 2026-10-13)
-- P3 Day 2: tech-stack detector (technographics)
create table if not exists tech_signatures (
  id serial primary key,
  tool text not null,
  category text not null,
  method text not null check (method in ('html','header','dns_mx','dns_txt','dns_cname')),
  pattern text not null,
  confidence text not null default 'high' check (confidence in ('high','medium')),
  gtm_relevant boolean not null default false,
  note text,
  enabled boolean not null default true,
  unique (tool, method, pattern)
);

create table if not exists tech_scan_runs (
  id bigserial primary key,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  companies_checked int default 0,
  html_ok int default 0,
  blocked int default 0,
  robots_disallowed int default 0,
  errors int default 0,
  tools_found int default 0,
  tool_signals_new int default 0,
  notes jsonb
);

create table if not exists tech_scans (
  id bigserial primary key,
  run_id bigint references tech_scan_runs(id),
  company_key text not null references icp_companies(company_key),
  domain text not null,
  scanned_at timestamptz not null default now(),
  html_status text not null check (html_status in ('ok','blocked','robots_disallowed','error','not_html')),
  dns_status text not null check (dns_status in ('ok','error')),
  http_status int,
  final_url text,
  redirected_off_domain boolean default false,
  html_bytes int,
  is_baseline boolean not null,
  tools_found int default 0,
  error text
);
create index if not exists tech_scans_company_idx on tech_scans(company_key, scanned_at desc);

create table if not exists tech_stack (
  company_key text not null references icp_companies(company_key),
  tool text not null,
  category text not null,
  first_seen timestamptz not null default now(),
  last_seen timestamptz not null default now(),
  active boolean not null default true,
  seen_in_baseline boolean not null,
  methods text[] not null default '{}',
  evidence jsonb,
  primary key (company_key, tool)
);

create or replace view companies_to_scan as
select c.company_key, c.company_name, c.domain
from icp_companies c
left join lateral (
  select s.scanned_at, s.html_status from tech_scans s
  where s.company_key = c.company_key order by s.scanned_at desc limit 1
) last on true
where c.domain is not null
  and (last.scanned_at is null
       or (last.html_status = 'ok' and last.scanned_at < now() - interval '7 days')
       or (last.html_status in ('blocked','robots_disallowed','not_html') and last.scanned_at < now() - interval '30 days')
       or (last.html_status = 'error' and last.scanned_at < now() - interval '1 day'))
order by last.scanned_at nulls first, c.icp_score desc nulls last;

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
  select max(scanned_at) into v_prev_scan from tech_scans
   where company_key = p_company_key and html_status = 'ok';
  v_baseline := v_prev_scan is null;
  select company_name into v_name from icp_companies where company_key = p_company_key;

  for v_det in
    select d->>'tool' tool, d->>'category' category,
           array_agg(distinct d->>'method') methods,
           jsonb_agg(jsonb_build_object('method', d->>'method', 'evidence', d->>'evidence')) ev
    from jsonb_array_elements(coalesce(p_detections,'[]'::jsonb)) d
    group by 1,2
  loop
    v_tools := v_tools + 1;
    v_existing := null;
    select true into v_existing from tech_stack where company_key = p_company_key and tool = v_det.tool;

    insert into tech_stack(company_key, tool, category, seen_in_baseline, methods, evidence)
    values (p_company_key, v_det.tool, v_det.category, v_baseline, v_det.methods, v_det.ev)
    on conflict (company_key, tool) do update
      set last_seen = now(), active = true, methods = excluded.methods, evidence = excluded.evidence;

    if not v_baseline and v_existing is null and p_html_status = 'ok'
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

create or replace view company_tech_stack as
select c.company_name, c.domain, t.category, t.tool, t.methods, t.first_seen, t.last_seen, t.seen_in_baseline
from tech_stack t join icp_companies c using (company_key)
where t.active
order by c.company_name, t.category, t.tool;

create or replace view tool_adoption as
select t.tool, t.category, count(*) companies,
       round(100.0 * count(*) / nullif((select count(distinct company_key) from tech_scans where html_status='ok'),0), 1) pct_of_scanned
from tech_stack t where t.active
group by 1,2 order by companies desc;

create or replace view tech_scan_health as
select r.id run_id, r.started_at, r.finished_at, r.companies_checked, r.html_ok, r.blocked,
       r.robots_disallowed, r.errors, r.tools_found, r.tool_signals_new
from tech_scan_runs r order by r.id desc;

alter table tech_signatures enable row level security;
alter table tech_scan_runs enable row level security;
alter table tech_scans enable row level security;
alter table tech_stack enable row level security;
