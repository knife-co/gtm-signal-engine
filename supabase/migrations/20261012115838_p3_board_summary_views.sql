-- p3_board_summary_views (applied 2026-10-12)
-- One row per valid board, with how many open jobs and how many are GTM-type
create or replace view board_summary with (security_invoker = true) as
  select b.ats, b.token, coalesce(b.board_name, b.company_name) company, b.company_key, b.source, b.name_check,
         count(j.*) filter (where j.closed_at is null) open_jobs,
         count(j.*) filter (where j.closed_at is null and j.job_function <> 'Unmapped') open_gtm_jobs,
         count(j.*) filter (where j.closed_at is null and j.job_function <> 'Unmapped' and j.published_at > now() - interval '30 days') gtm_last_30d,
         max(j.published_at) filter (where j.job_function <> 'Unmapped') newest_gtm_post,
         b.last_checked_at
  from ats_boards b left join ats_jobs j using (ats, token)
  where b.status = 'valid'
  group by b.ats, b.token, b.board_name, b.company_name, b.company_key, b.source, b.name_check, b.last_checked_at;

-- Collector health for the daily report
create or replace view collector_health with (security_invoker = true) as
  select
    (select count(*) from ats_boards where status = 'valid') valid_boards,
    (select count(distinct coalesce(company_key, token)) from ats_boards where status = 'valid') companies_covered,
    (select count(*) from ats_boards where status = 'unchecked') still_to_probe,
    (select count(*) from ats_jobs where closed_at is null) open_jobs,
    (select count(*) from ats_jobs where closed_at is null and job_function <> 'Unmapped') open_gtm_jobs,
    (select count(*) from signals where signal_type = 'gtm_hire' and expires_at > now()) live_gtm_signals,
    (select max(finished_at) from collector_runs where mode = 'collect') last_daily_collect;
