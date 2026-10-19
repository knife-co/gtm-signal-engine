-- p3_router_review_lane (applied 2026-10-15)
alter table router_settings add column if not exists review_min_signal int not null default 70;

-- Unscored accounts (not in P1's list) with a strong signal go to a "review" lane: a human decides if they fit the ICP.
-- Accounts that FAILED the ICP gate are never routed: the gate is the gatekeeper.
create or replace function route_accounts(p_run_id bigint) returns jsonb language plpgsql as $$
declare st router_settings;
begin
  select * into st from router_settings where id = 1;
  insert into router_decisions(run_id, account_key, company_key, company_name, sf_account_id, icp_score, signal_score,
                               priority, tier, play_key, prev_tier, change, alert, detail)
  select p_run_id, r.account_key, r.company_key, r.company_name, r.sf_account_id, r.icp_score, r.signal_score, r.priority,
         t.tier, r.play_key, prev.tier,
         case when prev.tier is null then 'new'
              when tier_rank(t.tier) > tier_rank(prev.tier) then 'up'
              when tier_rank(t.tier) < tier_rank(prev.tier) then 'down' else 'same' end,
         (t.tier = any(st.alert_tiers) and (prev.tier is null or tier_rank(t.tier) > tier_rank(prev.tier)))
           or (t.tier = 'review' and prev.tier is distinct from 'review'),
         jsonb_build_object('play', r.play_name, 'who', r.who, 'channel', r.channel, 'opener', r.opener,
                            'top_title', r.top_title, 'top_function', r.top_function, 'top_url', r.top_url, 'top_tool', r.top_tool,
                            'types_live', r.types_live, 'type_strength', r.type_strength,
                            'live_clusters', r.live_clusters, 'live_postings', r.live_postings,
                            'first_step_hours', r.first_step_hours, 'domain', r.domain, 'eligibility', r.eligibility)
  from account_routing r
  cross join lateral (select case
        when r.eligibility = 'unscored' then 'review'
        when r.priority >= st.tier_a then 'A' when r.priority >= st.tier_b then 'B'
        when r.priority >= st.tier_c then 'C' else 'none' end tier) t
  left join lateral (select d.tier from router_decisions d where d.account_key = r.account_key and d.run_id < p_run_id
                     order by d.run_id desc limit 1) prev on true
  where r.eligibility = 'eligible'
     or (r.eligibility = 'unscored' and r.signal_score >= st.review_min_signal)
  on conflict (run_id, account_key) do nothing;

  -- accounts that were tiered last run but no longer qualify: record the drop so Salesforce gets cleared
  insert into router_decisions(run_id, account_key, company_key, company_name, sf_account_id, icp_score, signal_score,
                               priority, tier, play_key, prev_tier, change, alert, detail)
  select p_run_id, last.account_key, last.company_key, last.company_name, last.sf_account_id, last.icp_score, 0, 0,
         'none', null, last.tier, 'down', false, jsonb_build_object('note', 'no longer has a live signal that qualifies')
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
  return (select to_jsonb(r) from router_runs r where id = p_run_id);
end $$;

-- Today's ranked list, ready to read
create or replace view router_today as
select d.tier, d.priority, d.company_name, d.icp_score, d.signal_score, d.play_key, d.change, d.alert,
       d.detail->>'top_title' top_signal, d.detail->>'who' who, d.detail->>'channel' channel, d.detail->>'opener' opener,
       d.sf_account_id, d.run_id
from router_decisions d
where d.run_id = (select max(id) from router_runs where finished_at is not null or id = (select max(id) from router_runs))
order by case d.tier when 'A' then 1 when 'B' then 2 when 'review' then 3 when 'C' then 4 else 5 end, d.priority desc, d.signal_score desc;
