-- p3_router_core (applied 2026-10-15)
-- ===== 1. Noise filter: signals that look like GTM but aren't (kept in signals, ignored by the router) =====
create table if not exists signal_noise_rules (
  id serial primary key,
  signal_type text not null,
  pattern text not null,           -- case-insensitive regex on the title / tool
  reason text not null,
  enabled boolean not null default true,
  unique (signal_type, pattern)
);
alter table signal_noise_rules enable row level security;
insert into signal_noise_rules(signal_type, pattern, reason) values
 ('gtm_hire', '(recruit|talent acqu|talent partner|sourcer|people partner|hr business partner|talent community)', 'Recruiting / HR job for the GTM team, not a GTM operations role'),
 ('gtm_hire', '(intern\y|internship|working student)', 'Internship: no budget or system ownership behind it')
on conflict do nothing;

-- ===== 2. Dedupe: one "cluster" per account + signal type + normalised detail =====
-- The same role posted in 3 cities = 1 cluster. Account = P1 company, or the job board itself if not in P1.
create or replace view signal_clusters as
with s as (
  select ss.*,
    coalesce(ss.company_key, 'board:' || (ss.evidence->>'ats') || ':' || (ss.evidence->>'token')) as account_key,
    trim(regexp_replace(lower(coalesce(ss.evidence->>'title', ss.evidence->>'tool', '')),
         '(\([^)]*\)|,\s*(emea|apac|amer|na|us|uk|latam|remote).*$|\s+-\s+(remote|emea|apac|us|uk).*$|\yr-?\d{4,}\y|[^a-z0-9]+)', ' ', 'g')) as norm_detail,
    exists (select 1 from signal_noise_rules n where n.enabled and n.signal_type = ss.signal_type
            and coalesce(ss.evidence->>'title', ss.evidence->>'tool', '') ~* n.pattern) as is_noise
  from signals_scored ss
)
select account_key, company_key, max(company_name) company_name, signal_type,
       regexp_replace(norm_detail, '\s+', ' ', 'g') norm_detail,
       bool_or(is_noise) is_noise,
       max(strength) strength,
       (array_agg(band order by strength desc, event_at desc))[1] band,
       count(*) postings,
       max(event_at) newest_event,
       (array_agg(ref order by strength desc, event_at desc))[1] lead_ref,
       array_agg(ref order by strength desc, event_at desc) refs,
       (array_agg(evidence order by strength desc, event_at desc))[1] lead_evidence
from s
group by account_key, company_key, signal_type, regexp_replace(norm_detail, '\s+', ' ', 'g');

-- ===== 3. Plays: what to do for each kind of situation (first matching rule wins) =====
create table if not exists router_plays (
  play_key text primary key,
  rule_order int not null,
  name text not null,
  needs_types text[] not null,          -- all of these signal types must be live (strength >= min_strength)
  hire_functions text[],                -- if set, the strongest hiring signal must be one of these functions
  min_strength int not null default 10,
  who text not null,
  channel text not null,
  opener text not null,                 -- {company} {title} {tool} are filled in
  first_step_hours int not null         -- how fast to act on a tier A account
);
alter table router_plays enable row level security;
insert into router_plays values
 ('stack_hire_tool', 10, 'New tool + new ops hire', array['gtm_hire','tool_added'], null, 10,
  'Hiring manager for the role (RevOps / Ops lead)', 'Email with one integration idea, then LinkedIn',
  'Saw {company} is hiring a {title} and {tool} just showed up on your site. The new hire will probably inherit the job of connecting it to the CRM; happy to share how I''d approach that.', 24),
 ('funding_scale', 20, 'Scaling after funding', array['funding','gtm_hire'], null, 10,
  'VP Growth / Head of Sales', 'Email first, LinkedIn follow-up',
  'Congrats on the raise. Teams usually double their GTM headcount after a round, and you are already hiring a {title}. The routing and reporting that worked before tends to break at that size.', 24),
 ('new_exec_audit', 30, 'New leader, first 90 days', array['new_exec'], null, 10,
  'The new executive', 'LinkedIn message, then email',
  'Congrats on the new role at {company}. In the first 90 days most revenue leaders want a clear picture of pipeline and CRM health before changing anything. I can put together a one-page audit.', 48),
 ('systems_hire', 40, 'Hiring to fix the systems', array['gtm_hire'],
  array['Revenue Operations','Sales Operations','Marketing Operations','Marketing Automation','CRM Administration','CRM Development','CRM Consulting','GTM Engineering','Growth Operations'], 10,
  'Hiring manager for the role (Head of RevOps / Ops)', 'LinkedIn connection + short email',
  'Saw {company} is hiring a {title}. That usually means the CRM and tooling have grown faster than the rules around them. I build pipelines that keep account data clean before it reaches Salesforce; happy to share what I learned.', 24),
 ('gtm_build_hire', 50, 'Building the GTM team', array['gtm_hire'], null, 10,
  'Head of GTM / VP Sales (the role''s manager)', 'LinkedIn connection + short email',
  'Saw {company} is hiring a {title}. A growing GTM team usually means new territories, routing and reporting to set up. Worth a short chat about what to automate before the team grows?', 48),
 ('tool_integration', 60, 'New tool to integrate', array['tool_added'], null, 10,
  'RevOps lead or whoever owns the GTM tools', 'Email with one specific integration idea',
  'Noticed {tool} is new on {company}''s site. The hardest part of a rollout is usually getting it and the CRM to agree. Have you decided which system wins when they conflict?', 72)
on conflict (play_key) do update set rule_order = excluded.rule_order, name = excluded.name, needs_types = excluded.needs_types,
  hire_functions = excluded.hire_functions, min_strength = excluded.min_strength, who = excluded.who, channel = excluded.channel,
  opener = excluded.opener, first_step_hours = excluded.first_step_hours;

-- ===== 4. Priority settings (one row, easy to tune) =====
create table if not exists router_settings (
  id int primary key default 1 check (id = 1),
  icp_weight numeric not null default 0.4,     -- priority = 100 * icp^0.4 * signal^0.6 (both as fractions)
  signal_weight numeric not null default 0.6,
  tier_a int not null default 70,
  tier_b int not null default 50,
  tier_c int not null default 25,
  alert_tiers text[] not null default array['A','B']
);
alter table router_settings enable row level security;
insert into router_settings default values on conflict do nothing;

-- ===== 5. One row per account: ICP fit + live signals -> priority, tier, play =====
create or replace view account_routing as
with live as (
  select * from signal_clusters where not is_noise and strength > 0
),
best_type as (
  select account_key, signal_type, max(strength) strength from live group by 1,2
),
sig as (
  select b.account_key,
         round(100 * (1 - exp(sum(ln(greatest(1 - p.type_weight * b.strength / 100.0, 0.000001))))))::int signal_score,
         array_agg(b.signal_type order by b.strength desc) types_live,
         jsonb_object_agg(b.signal_type, b.strength) type_strength
  from best_type b join signal_decay_policy p using (signal_type)
  group by b.account_key
),
top_hire as (
  select distinct on (account_key) account_key, lead_evidence->>'title' title, lead_evidence->>'function' fn,
         lead_evidence->>'url' url, strength, postings
  from live where signal_type = 'gtm_hire' order by account_key, strength desc, newest_event desc
),
top_tool as (
  select distinct on (account_key) account_key, lead_evidence->>'tool' tool, strength
  from live where signal_type = 'tool_added' order by account_key, strength desc
),
acct as (
  select l.account_key, max(l.company_key) company_key, max(l.company_name) company_name,
         count(*) live_clusters, sum(l.postings) live_postings
  from live l group by l.account_key
),
st as (select * from router_settings where id = 1)
select a.account_key, a.company_key, coalesce(c.company_name, a.company_name) company_name, c.domain, c.sf_account_id,
       case when c.company_key is null then 'unscored' when not coalesce(c.gate_passed, false) then 'failed_icp_gate' else 'eligible' end as eligibility,
       coalesce(c.icp_score, 0) icp_score, s.signal_score, s.types_live, s.type_strength,
       a.live_clusters, a.live_postings,
       case when c.gate_passed then
         round(100 * power(greatest(c.icp_score,0) / 100.0, st.icp_weight) * power(s.signal_score / 100.0, st.signal_weight))::int
       else 0 end as priority,
       th.title top_title, th.fn top_function, th.url top_url, tt.tool top_tool,
       pl.play_key, pl.name play_name, pl.who, pl.channel, pl.first_step_hours,
       replace(replace(replace(pl.opener, '{company}', coalesce(c.company_name, a.company_name)),
               '{title}', coalesce(th.title, 'GTM role')), '{tool}', coalesce(tt.tool, 'a new tool')) as opener
from acct a
join sig s using (account_key)
cross join st
left join icp_companies c on c.company_key = a.company_key
left join top_hire th using (account_key)
left join top_tool tt using (account_key)
left join lateral (
  select p.* from router_plays p
  where (select bool_and(coalesce((s.type_strength->>t)::int, 0) >= p.min_strength) from unnest(p.needs_types) t)
    and (p.hire_functions is null or th.fn = any(p.hire_functions))
  order by p.rule_order limit 1
) pl on true;

-- ===== 6. Router runs and decisions (history: every day's ranking is kept) =====
create table if not exists router_runs (
  id bigserial primary key,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  trigger text,
  source_health jsonb,
  accounts_routed int, tier_a int, tier_b int, tier_c int,
  alerts int, slack_status text,
  sf_result jsonb,
  errors jsonb
);
create table if not exists router_decisions (
  run_id bigint not null references router_runs(id),
  account_key text not null,
  company_key text,
  company_name text,
  sf_account_id text,
  icp_score int, signal_score int, priority int,
  tier text not null,                  -- A / B / C / none
  play_key text,
  prev_tier text,
  change text not null,                -- new / up / down / same
  alert boolean not null default false,
  detail jsonb,
  decided_at timestamptz not null default now(),
  primary key (run_id, account_key)
);
create index if not exists router_decisions_acct_idx on router_decisions(account_key, run_id desc);
alter table router_runs enable row level security;
alter table router_decisions enable row level security;

create or replace function tier_rank(t text) returns int language sql immutable as $$
  select case t when 'A' then 3 when 'B' then 2 when 'C' then 1 else 0 end $$;

-- Route every eligible account for one run. Writes decisions, compares with the previous run, flags alerts.
create or replace function route_accounts(p_run_id bigint) returns jsonb language plpgsql as $$
declare st router_settings; n int;
begin
  select * into st from router_settings where id = 1;
  insert into router_decisions(run_id, account_key, company_key, company_name, sf_account_id, icp_score, signal_score,
                               priority, tier, play_key, prev_tier, change, alert, detail)
  select p_run_id, r.account_key, r.company_key, r.company_name, r.sf_account_id, r.icp_score, r.signal_score, r.priority,
         t.tier, r.play_key, prev.tier,
         case when prev.tier is null then 'new'
              when tier_rank(t.tier) > tier_rank(prev.tier) then 'up'
              when tier_rank(t.tier) < tier_rank(prev.tier) then 'down' else 'same' end,
         -- alert only when an account ENTERS an alert tier (new or moved up), never for the same news twice
         t.tier = any(st.alert_tiers) and (prev.tier is null or tier_rank(t.tier) > tier_rank(prev.tier)),
         jsonb_build_object('play', r.play_name, 'who', r.who, 'channel', r.channel, 'opener', r.opener,
                            'top_title', r.top_title, 'top_function', r.top_function, 'top_url', r.top_url, 'top_tool', r.top_tool,
                            'types_live', r.types_live, 'type_strength', r.type_strength,
                            'live_clusters', r.live_clusters, 'live_postings', r.live_postings,
                            'first_step_hours', r.first_step_hours, 'domain', r.domain)
  from account_routing r
  cross join lateral (select case when r.priority >= st.tier_a then 'A' when r.priority >= st.tier_b then 'B'
                                  when r.priority >= st.tier_c then 'C' else 'none' end tier) t
  left join lateral (select d.tier from router_decisions d where d.account_key = r.account_key and d.run_id < p_run_id
                     order by d.run_id desc limit 1) prev on true
  where r.eligibility = 'eligible'
  on conflict (run_id, account_key) do nothing;

  -- accounts that had a tier last run but have no live signal now: record the drop so Salesforce gets cleared
  insert into router_decisions(run_id, account_key, company_key, company_name, sf_account_id, icp_score, signal_score,
                               priority, tier, play_key, prev_tier, change, alert, detail)
  select p_run_id, last.account_key, last.company_key, last.company_name, last.sf_account_id, last.icp_score, 0, 0,
         'none', null, last.tier, case when last.tier = 'none' then 'same' else 'down' end, false,
         jsonb_build_object('note', 'no live signals any more')
  from (select distinct on (account_key) * from router_decisions where run_id < p_run_id order by account_key, run_id desc) last
  where last.tier <> 'none'
    and not exists (select 1 from router_decisions d where d.run_id = p_run_id and d.account_key = last.account_key)
  on conflict (run_id, account_key) do nothing;

  update router_runs set
    accounts_routed = (select count(*) from router_decisions where run_id = p_run_id),
    tier_a = (select count(*) from router_decisions where run_id = p_run_id and tier = 'A'),
    tier_b = (select count(*) from router_decisions where run_id = p_run_id and tier = 'B'),
    tier_c = (select count(*) from router_decisions where run_id = p_run_id and tier = 'C'),
    alerts = (select count(*) from router_decisions where run_id = p_run_id and alert)
  where id = p_run_id;
  select count(*) into n from router_decisions where run_id = p_run_id;
  return (select to_jsonb(r) from router_runs r where id = p_run_id);
end $$;
