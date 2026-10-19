-- p3_jobs_for_me_v2 (applied 2026-10-16)

update signal_noise_rules
set pattern = '(external template|make a copy|\mtemplate\M|do not apply|general application|talent pool|\mpool\M|future opportunit|don.?t see what you|open application|general interest)'
where pattern = '(external template|make a copy|\mtemplate\M|do not apply|general application|talent pool|future opportunit)';

create or replace view jobs_for_me as
with base as (
  select 'board:'||r.source||':'||r.source_id as job_key, s.display_name as source, r.company, r.title, r.url,
         coalesce(r.location_text, case when r.allowed_countries is not null then
           case when cardinality(r.allowed_countries) = 0 then 'Worldwide' else array_to_string(r.allowed_countries, ', ') end end) as location,
         r.job_function, r.seniority, coalesce(r.published_at, r.first_seen_at) as posted_at, r.first_seen_at,
         -- Worldwide on paper but working hours that exclude Lagos (UTC+1, so 0..2 is workable) = maybe
         case when g.verdict = 'yes' and r.timezone_offsets is not null and not (r.timezone_offsets && array[0,1,2]::numeric[]) then 'maybe' else g.verdict end as geo,
         case when g.verdict = 'yes' and r.timezone_offsets is not null and not (r.timezone_offsets && array[0,1,2]::numeric[])
              then format('Worldwide, but working hours set to UTC%s to UTC%s', min_tz, max_tz) else g.reason end as geo_reason,
         r.desc_verdict, r.desc_evidence, 2 as source_rank
  from remote_jobs r join job_feed_sources s using (source)
  cross join lateral geo_verdict(r.location_text, r.allowed_countries) g
  cross join lateral (select min(x) min_tz, max(x) max_tz from unnest(r.timezone_offsets) x) tz
  where r.closed_at is null
  union all
  select 'ats:'||j.ats||':'||j.token||':'||j.job_id, initcap(j.ats), coalesce(b.board_name, b.company_name, j.token), j.title, j.url,
         j.location, j.job_function, j.seniority, coalesce(j.published_at, j.first_seen_at), j.first_seen_at,
         g.verdict, g.reason, d.desc_verdict, d.desc_evidence, 1
  from ats_jobs j join ats_boards b using (ats, token)
  cross join lateral geo_verdict(j.location) g
  left join job_description_checks d using (ats, token, job_id)
  where j.closed_at is null and j.job_function <> 'Unmapped'
), scored as (
  select b.*, eligibility(geo, desc_verdict) as eligible,
    case when desc_verdict is not null then coalesce(desc_evidence, geo_reason) else geo_reason end as why_eligible,
    greatest(0.1, case when now() - posted_at <= interval '7 days' then 1.0
      else power(0.5, (extract(epoch from now() - posted_at)/86400 - 7) / 14) end) as freshness
  from base b
  where not exists (select 1 from signal_noise_rules n where n.enabled and n.signal_type = 'gtm_hire' and b.title ~* n.pattern)
    and posted_at > now() - interval '60 days'
), ranked as (
  select s.*, round(100 * role_fit(job_function) * seniority_fit(seniority) * freshness
                    * case eligible when 'yes' then 1.0 when 'maybe' then 0.55 else 0 end)::int as fit,
         row_number() over (partition by normalize_company_name(company), clean_title(title) order by source_rank, posted_at desc) as dup_rank
  from scored s where eligible <> 'no'
)
select job_key, fit, eligible, why_eligible, title, company, source, url, location, job_function, seniority,
       posted_at::date as posted_on, (now() - first_seen_at < interval '1 day') as is_new, portfolio_angle(job_function) as portfolio_angle
from ranked where dup_rank = 1
order by fit desc, posted_at desc;
