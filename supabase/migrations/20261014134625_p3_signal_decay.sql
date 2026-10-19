-- p3_signal_decay (applied 2026-10-14)
-- P3 Day 3: signal decay. A signal is worth most when it is fresh and fades over time.
-- Curve per signal type: full strength for fresh_days, then halves every half_life_days, then 0 after window_days.
create table if not exists signal_decay_policy (
  signal_type text primary key,
  fresh_days numeric not null,      -- full strength (100) for this many days
  half_life_days numeric not null,  -- after the fresh period, strength halves every N days
  window_days int not null,         -- hard stop: 0 after this many days (matches signals.window_days)
  type_weight numeric not null,     -- how much this kind of signal counts in the account score (0-1)
  why text
);
alter table signal_decay_policy enable row level security;

insert into signal_decay_policy values
 ('gtm_hire', 3, 7, 30, 1.0, 'Job posts get most attention in the first two weeks; after a month the role is usually filled or the post is "evergreen".'),
 ('funding',  5, 8, 30, 0.8, 'Funding news is "new" for a few weeks; every vendor reaches out in the first month.'),
 ('tool_added', 7, 30, 90, 0.6, 'Rolling out a tool takes a quarter; the integration pain lasts longer than the news.'),
 ('new_exec', 14, 30, 90, 0.8, 'New leaders review what they inherited in their first 90 days.')
on conflict (signal_type) do update set fresh_days = excluded.fresh_days, half_life_days = excluded.half_life_days,
  window_days = excluded.window_days, type_weight = excluded.type_weight, why = excluded.why;

-- strength 0..100 for a signal of this type, this old, at this moment
create or replace function signal_strength(p_type text, p_event_at timestamptz, p_at timestamptz default now())
returns int language sql stable as $$
  select case
    when p_event_at is null or p.signal_type is null then 0
    when p_event_at > p_at then 100                                         -- future-dated: treat as brand new
    when extract(epoch from p_at - p_event_at)/86400 >= p.window_days then 0 -- past the window: cold
    when extract(epoch from p_at - p_event_at)/86400 <= p.fresh_days then 100
    else round(100 * power(0.5, (extract(epoch from p_at - p_event_at)/86400 - p.fresh_days) / p.half_life_days))::int
  end
  from (select 1) one left join signal_decay_policy p on p.signal_type = p_type
$$;

create or replace function strength_band(p_strength int) returns text language sql immutable as $$
  select case when p_strength >= 70 then 'hot' when p_strength >= 40 then 'warm'
              when p_strength >= 10 then 'cooling' else 'cold' end
$$;

-- every signal with its strength today. A hiring signal whose job has been taken down is 0 ("closed").
create or replace view signals_scored as
select s.id, s.signal_type, s.company_name, s.company_key, s.ref, s.event_at, s.detected_at, s.expires_at,
       round(extract(epoch from now() - s.event_at)/86400, 1) as age_days,
       j.closed_at as job_closed_at,
       case when j.closed_at is not null then 0 else signal_strength(s.signal_type, s.event_at) end as strength,
       case when j.closed_at is not null then 'closed'
            else strength_band(signal_strength(s.signal_type, s.event_at)) end as band,
       s.who, s.angle, s.channel, s.evidence
from signals s
left join ats_jobs j on s.signal_type = 'gtm_hire' and s.ref = j.ats || ':' || j.token || ':' || j.job_id;

-- one score per company: the strongest signal of each kind, then kinds combined like independent chances
-- score = 100 * (1 - product over kinds of (1 - weight * strength/100))
create or replace view account_signal_score as
with best as (
  select company_key, signal_type, max(strength) strength
  from signals_scored where company_key is not null and strength > 0
  group by 1,2
), top as (
  select distinct on (company_key) company_key, signal_type, strength, evidence->>'title' title, evidence->>'tool' tool, event_at
  from signals_scored where company_key is not null and strength > 0
  order by company_key, strength desc, event_at desc
)
select b.company_key, c.company_name, c.sf_account_id,
       round(100 * (1 - exp(sum(ln(greatest(1 - p.type_weight * b.strength / 100.0, 0.000001))))))::int as signal_score,
       count(*) as signal_kinds,
       (select count(*) from signals_scored x where x.company_key = b.company_key and x.strength > 0) as live_signals,
       max(t.signal_type) || ': ' || coalesce(max(t.title), max(t.tool), '') || ' (' || max(t.strength) || ')' as top_signal
from best b
join signal_decay_policy p using (signal_type)
join icp_companies c using (company_key)
join top t using (company_key)
group by b.company_key, c.company_name, c.sf_account_id
order by signal_score desc;
