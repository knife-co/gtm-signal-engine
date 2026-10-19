-- p3_cohort_freeze (applied 2026-10-18)

create table if not exists cohort_study (
  study_id text primary key,
  frozen_at timestamptz not null default now(),
  outcome_window_ends date not null,
  primary_metric text not null,
  rules jsonb not null
);
create table if not exists cohort_members (
  study_id text not null references cohort_study(study_id),
  company_key text not null,
  company_name text,
  arm text not null check (arm in ('signal','cold')),
  stratum text not null,
  open_jobs int, icp_score int, gate_passed boolean,
  lead_signal_ref text,
  tools_at_freeze int,
  in_matched_sample boolean not null default false,
  primary key (study_id, company_key)
);
alter table cohort_study enable row level security;
alter table cohort_members enable row level security;

insert into cohort_study (study_id, outcome_window_ends, primary_metric, rules) values ('p3-vs-p1-2026-10-18', '2026-11-17',
 'Share of companies that start using at least one new GTM tool within 30 days (first seen after the freeze, not in the baseline scan, seen again on a later scan)',
 jsonb_build_object(
  'question', 'Do companies with a live GTM-ops hiring signal go on to buy GTM tools more often than comparable cold P1 companies?',
  'why_this_outcome', 'No outreach is being sent. Tool adoption is real buying behaviour, read from company websites by the Day 2 detector, a different source from the job posts that create the signal.',
  'universe', 'P1 companies (icp_companies) that P3 can watch: a valid Greenhouse/Lever/Ashby board, board name not flagged "different", and at least one successful website scan.',
  'signal_arm', 'At least one gtm_hire signal in a core-ops function (RevOps, Sales Ops, Marketing Ops, Marketing Automation, CRM Admin, CRM Dev, GTM Engineering) posted in the 30 days to 17 Oct. Core-ops signals were 22 of 22 correct in the 17 Oct audit.',
  'cold_arm', 'No gtm_hire signal of any kind in the same 30 days.',
  'excluded', 'Companies with only broad-bucket signals (GTM Strategy, lifecycle, demand gen): 22 of 28 audited were false, so their label is unreliable.',
  'matching', 'Coarsened exact matching on total open jobs (1-9, 10-24, 25-59, 60+). Equal numbers per arm in each band, picked in md5 hash order (anyone can redraw the same sample).',
  'secondary_metric', 'Share of cold companies that post a core-ops role within 30 days (cold turning warm).',
  'analysis', 'As assigned, no switching. Each arm''s rate with Wilson 95% intervals, the difference and a Fisher exact p-value. Read once, on or after 17 Nov 2026.',
  'limits', 'Buying intent, not replies or revenue. Small groups, so only a large difference can show. The detector misses tools hidden behind logins, equally for both arms.'))
on conflict (study_id) do nothing;

with core as (select unnest(array['Revenue Operations','Sales Operations','Marketing Operations','Marketing Automation','CRM Administration','CRM Development','GTM Engineering']) f),
board as (select company_key, max(job_count) open_jobs, bool_or(name_check = 'different') name_bad from ats_boards where status='valid' and company_key is not null group by 1),
sig as (select company_key,
   (array_agg(ref order by event_at desc) filter (where evidence->>'function' in (select f from core)))[1] core_ref,
   count(*) filter (where evidence->>'function' in (select f from core)) core_n,
   count(*) filter (where evidence->>'function' not in (select f from core)) broad_n
  from signals where event_at > '2026-10-17'::timestamptz - interval '30 days' and event_at <= '2026-10-17 23:59+00' group by 1),
u as (select i.company_key, i.company_name, i.icp_score, i.gate_passed, b.open_jobs, sig.core_ref,
        case when coalesce(sig.core_n,0) > 0 then 'signal' when coalesce(sig.broad_n,0) > 0 then 'excluded' else 'cold' end arm,
        case when b.open_jobs < 10 then 'a: 1-9 jobs' when b.open_jobs < 25 then 'b: 10-24 jobs' when b.open_jobs < 60 then 'c: 25-59 jobs' else 'd: 60+ jobs' end stratum,
        (select count(*) from tech_stack ts where ts.company_key = i.company_key and ts.active) tools_at_freeze
      from icp_companies i join board b using (company_key) left join sig using (company_key)
      where not b.name_bad and exists (select 1 from tech_scans t where t.company_key = i.company_key and t.html_status = 'ok'))
insert into cohort_members (study_id, company_key, company_name, arm, stratum, open_jobs, icp_score, gate_passed, lead_signal_ref, tools_at_freeze)
select 'p3-vs-p1-2026-10-18', company_key, company_name, arm, stratum, open_jobs, icp_score, gate_passed, core_ref, tools_at_freeze from u where arm <> 'excluded'
on conflict do nothing;

with ranked as (select company_key, arm, stratum,
   row_number() over (partition by stratum, arm order by md5(company_key || ':p3-vs-p1')) rn
  from cohort_members where study_id = 'p3-vs-p1-2026-10-18'),
caps as (select stratum, least(count(*) filter (where arm='signal'), count(*) filter (where arm='cold')) k from ranked group by 1)
update cohort_members m set in_matched_sample = true
from ranked r join caps c using (stratum)
where m.study_id = 'p3-vs-p1-2026-10-18' and m.company_key = r.company_key and r.rn <= c.k;

create or replace function cohort_members_locked() returns trigger language plpgsql as $$
begin raise exception 'cohort_members is frozen; start a new study_id instead'; end $$;
create or replace trigger cohort_members_lock before update or delete on cohort_members
  for each row execute function cohort_members_locked();

create or replace view cohort_result as
with s as (select * from cohort_study where study_id = 'p3-vs-p1-2026-10-18'),
m as (select cm.* from cohort_members cm, s where cm.study_id = s.study_id and cm.in_matched_sample),
tools as (select distinct ts.company_key from tech_stack ts, s
          where not ts.seen_in_baseline and ts.first_seen > s.frozen_at and ts.first_seen <= s.outcome_window_ends + 1
            and ts.last_seen > ts.first_seen),
warm as (select distinct x.company_key from signals x, s
          where x.signal_type = 'gtm_hire' and x.event_at > s.frozen_at and x.event_at <= s.outcome_window_ends + 1
            and x.evidence->>'function' in ('Revenue Operations','Sales Operations','Marketing Operations','Marketing Automation','CRM Administration','CRM Development','GTM Engineering'))
select m.arm, count(*) companies,
  count(*) filter (where m.company_key in (select company_key from tools)) adopted_new_tool,
  round(100.0 * count(*) filter (where m.company_key in (select company_key from tools)) / count(*), 1) adoption_pct,
  count(*) filter (where m.company_key in (select company_key from warm)) new_core_ops_post,
  (select outcome_window_ends from s) read_on_or_after,
  (current_date >= (select outcome_window_ends from s)) ready
from m group by m.arm;
