-- p3_jobs_for_me (applied 2026-10-16)

-- New noise rules (apply to router signals AND to the jobs list)
insert into signal_noise_rules (signal_type, pattern, reason, enabled)
select 'gtm_hire', p, r, true from (values
  ('(external template|make a copy|\mtemplate\M|do not apply|general application|talent pool|future opportunit)', 'Placeholder / template posting, not a real opening'),
  ('(strategic finance|\mfp&a\M|finance (lead|manager|partner|director)|accounting|\mtax\M|counsel|\mlegal\M)', 'Finance or legal role that only mentions GTM'),
  ('(education|teacher|curriculum|instructional)', 'Education role that only mentions GTM')
) v(p, r)
where not exists (select 1 from signal_noise_rules n where n.pattern = v.p);

create table if not exists jobs_notified (
  job_key text primary key,
  notified_at timestamptz not null default now()
);
alter table jobs_notified enable row level security;

create or replace function role_fit(p_function text) returns numeric language sql immutable as $$
  select case p_function
    when 'GTM Engineering' then 1.0 when 'Revenue Operations' then 0.95 when 'Sales Operations' then 0.9
    when 'Marketing Operations' then 0.9 when 'Marketing Automation' then 0.85 when 'CRM Administration' then 0.85
    when 'CRM Development' then 0.8 when 'CRM Consulting' then 0.8 when 'GTM Strategy' then 0.6
    when 'Demand Generation' then 0.5 when 'CRM & Lifecycle Marketing' then 0.5 else 0.4 end $$;

create or replace function seniority_fit(p_seniority text) returns numeric language sql immutable as $$
  select case p_seniority when 'Junior' then 0.9 when 'Mid' then 1.0 when 'Senior' then 0.75 when 'Lead' then 0.55
    when 'Manager' then 0.5 when 'Director' then 0.2 when 'Executive' then 0.1 else 0.7 end $$;

create or replace function portfolio_angle(p_function text) returns text language sql immutable as $$
  select case
    when p_function = 'GTM Engineering' then 'Lead with P3: a signal engine (job posts, tech stack, decay, routing) that writes to Salesforce and Slack every morning with no laptop.'
    when p_function in ('Revenue Operations','Sales Operations') then 'Lead with the P3 router + P2 enrichment: one priority number from ICP fit and live signals, synced to Salesforce Accounts and Tasks.'
    when p_function in ('CRM Administration','CRM Development','CRM Consulting') then 'Lead with the Salesforce build: custom Signal object, upsert by external ID, JWT integration login, field-level security.'
    when p_function in ('Marketing Operations','Marketing Automation','Demand Generation','CRM & Lifecycle Marketing') then 'Lead with P1 ICP scoring + P3 signal plays: who to target, when, and with which message.'
    else 'Lead with P1 ICP definition + P3 priority tiers: how you decide which accounts get attention first.' end $$;

create or replace view jobs_for_me as
with base as (
  select 'board:'||r.source||':'||r.source_id as job_key, s.display_name as source, r.company, r.title, r.url,
         coalesce(r.location_text, case when r.allowed_countries is not null then
           case when cardinality(r.allowed_countries) = 0 then 'Worldwide' else array_to_string(r.allowed_countries, ', ') end end) as location,
         r.job_function, r.seniority, coalesce(r.published_at, r.first_seen_at) as posted_at, r.first_seen_at,
         g.verdict as geo, g.reason as geo_reason, r.desc_verdict, r.desc_evidence, 2 as source_rank
  from remote_jobs r join job_feed_sources s using (source)
  cross join lateral geo_verdict(r.location_text, r.allowed_countries) g
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

-- Slack digest: new "yes" jobs not yet sent. Marked as sent only after Slack confirms (jobs_mark_notified).
create or replace function jobs_slack_digest(p_force boolean default false)
returns jsonb language plpgsql stable set search_path = public as $$
declare rows jsonb; lines text;
begin
  select jsonb_agg(x order by x.fit desc) into rows from (
    select job_key, fit, title, company, source, url, why_eligible from jobs_for_me j
    where eligible = 'yes' and fit >= 25 and (p_force or not exists (select 1 from jobs_notified n where n.job_key = j.job_key))
    order by fit desc limit 8) x;
  if rows is null then return jsonb_build_object('keys', '[]'::jsonb); end if;
  select string_agg(format('• *<%s|%s>* at %s  (fit %s, via %s)%s', r->>'url', replace(r->>'title','|','-'), r->>'company', r->>'fit', r->>'source',
           E'\n      _' || left(r->>'why_eligible', 140) || '_'), E'\n')
    into lines from jsonb_array_elements(rows) r;
  return jsonb_build_object(
    'keys', (select jsonb_agg(r->>'job_key') from jsonb_array_elements(rows) r),
    'text', format('%s new job(s) you can apply for from Lagos', jsonb_array_length(rows)),
    'blocks', jsonb_build_array(
      jsonb_build_object('type','header','text', jsonb_build_object('type','plain_text','text', 'Jobs for you: ' || jsonb_array_length(rows) || ' new, open to Nigeria')),
      jsonb_build_object('type','section','text', jsonb_build_object('type','mrkdwn','text', left(lines, 2900))),
      jsonb_build_object('type','context','elements', jsonb_build_array(jsonb_build_object('type','mrkdwn',
        'text','Ranked by role fit × seniority × freshness × eligibility. Links go to the original board.')))));
end $$;

create or replace function jobs_mark_notified(p_keys jsonb) returns int language sql set search_path = public as $$
  with i as (insert into jobs_notified (job_key) select jsonb_array_elements_text(p_keys) on conflict do nothing returning 1)
  select count(*)::int from i $$;
