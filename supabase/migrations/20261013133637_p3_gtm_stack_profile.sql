-- p3_gtm_stack_profile (applied 2026-10-13)
-- One row per company: the GTM-relevant parts of its stack, ready to use in outreach.
create or replace view gtm_stack_profile as
with s as (
  select t.company_key, t.tool, t.category from tech_stack t where t.active
),
last_scan as (
  select distinct on (company_key) company_key, html_status, scanned_at, detector_version
  from tech_scans order by company_key, scanned_at desc
)
select c.company_name, c.domain, c.icp_score, l.html_status last_scan_status, l.scanned_at last_scanned,
  string_agg(s.tool, ', ' order by s.tool) filter (where s.category in ('crm','marketing_automation','email_marketing')) crm_and_marketing,
  string_agg(s.tool, ', ' order by s.tool) filter (where s.category in ('chat','scheduling')) chat_and_scheduling,
  string_agg(s.tool, ', ' order by s.tool) filter (where s.category in ('intent_abm','personalization','demo')) intent_and_abm,
  string_agg(s.tool, ', ' order by s.tool) filter (where s.category in ('cdp','product_analytics','web_analytics')) data_and_analytics,
  string_agg(s.tool, ', ' order by s.tool) filter (where s.category in ('email_provider')) email_provider,
  count(*) filter (where s.tool in (select tool from tech_signatures where gtm_relevant)) gtm_tool_count,
  -- a simple talking point: both HubSpot and Salesforce present = two systems that must agree
  bool_or(s.tool = 'HubSpot') and bool_or(s.tool = 'Salesforce') as hubspot_and_salesforce
from icp_companies c
join last_scan l using (company_key)
left join s using (company_key)
group by c.company_name, c.domain, c.icp_score, l.html_status, l.scanned_at
order by gtm_tool_count desc, c.icp_score desc nulls last;
