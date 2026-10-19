-- p3_tech_scan_health_from_scans (applied 2026-10-13)
alter view tech_scan_health rename to tech_scan_health_v1;
-- Count from the saved scans themselves, so a run that died part-way still shows what it saved.
create view tech_scan_health as
select r.id run_id, r.started_at, r.finished_at,
       case when r.finished_at is not null then 'finished'
            when r.started_at < now() - interval '10 minutes' then 'died (CPU or time limit) - saved scans kept'
            else 'running' end as run_status,
       count(s.id) companies_saved,
       count(*) filter (where s.html_status = 'ok') html_ok,
       count(*) filter (where s.html_status = 'blocked') blocked,
       count(*) filter (where s.html_status = 'robots_disallowed') robots_disallowed,
       count(*) filter (where s.html_status in ('error','not_html')) errors,
       count(*) filter (where s.dns_status = 'error') dns_errors,
       coalesce(sum(s.tools_found),0) tools_found,
       r.tool_signals_new
from tech_scan_runs r left join tech_scans s on s.run_id = r.id
group by r.id order by r.id desc;
