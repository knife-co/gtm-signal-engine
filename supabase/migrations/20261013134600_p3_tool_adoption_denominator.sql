-- p3_tool_adoption_denominator (applied 2026-10-13)
-- DNS works even when a homepage blocks us, so the share is out of ALL scanned companies, not just homepage-ok ones.
create or replace view tool_adoption as
select t.tool, t.category, count(*) companies,
       round(100.0 * count(*) / nullif((select count(distinct company_key) from tech_scans),0), 1) pct_of_scanned
from tech_stack t where t.active
group by 1,2 order by companies desc;
