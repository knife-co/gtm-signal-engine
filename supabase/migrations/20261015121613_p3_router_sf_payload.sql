-- p3_router_sf_payload (applied 2026-10-15)
alter table sf_account_signal_sync add column if not exists last_priority int;
alter table sf_account_signal_sync add column if not exists last_tier text;
alter table sf_account_signal_sync add column if not exists last_play text;

create table if not exists router_sf_tasks (
  id bigserial primary key,
  run_id bigint references router_runs(id),
  sf_account_id text not null,
  company_key text,
  play_key text,
  sf_task_id text,
  created_at timestamptz not null default now(),
  error text
);
alter table router_sf_tasks enable row level security;

-- What each raw signal SHOULD look like in Salesforce after dedupe and the noise filter.
-- Only the lead posting of a cluster keeps its strength; the others show as "duplicate"; noise shows as "noise".
create or replace view sf_signal_desired as
select s.*, c.account_key,
       case when c.is_noise then 0 when s.ref <> c.lead_ref then 0 else s.strength end as sf_strength,
       case when c.is_noise then 'noise' when s.ref <> c.lead_ref then 'duplicate' else s.band end as sf_band
from signals_scored s
join (select account_key, is_noise, lead_ref, unnest(refs) ref from signal_clusters) c on c.ref = s.ref;

-- Everything the router should write to Salesforce for one run.
create or replace function router_sf_payload(p_run_id bigint, p_max int default 200)
returns jsonb language sql stable as $$
with sig as (
  select d.*, co.sf_account_id
  from sf_signal_desired d
  join icp_companies co on co.company_key = d.company_key
  left join sf_signal_sync x on x.ref = d.ref
  where co.sf_account_id is not null
    and ((d.sf_strength > 0 and (x.ref is null or x.last_strength is distinct from d.sf_strength or x.last_band is distinct from d.sf_band))
      or (d.sf_strength = 0 and x.ref is not null and (x.last_strength <> 0 or x.last_band is distinct from d.sf_band)))
  order by d.sf_strength desc
  limit p_max
),
acc as (
  select co.sf_account_id, co.company_key,
         coalesce(r.signal_score, 0) score,
         coalesce(case when r.top_title is not null then 'GTM hire: ' || r.top_title when r.top_tool is not null then 'Tool added: ' || r.top_tool end, '') top,
         coalesce(r.live_clusters, 0)::int live,
         coalesce(dec.priority, 0) priority, coalesce(dec.tier, 'none') tier, dec.play_key,
         dec.detail->>'play' play_name, dec.detail->>'opener' opener, dec.detail->>'who' who, dec.detail->>'channel' channel
  from icp_companies co
  left join account_routing r on r.company_key = co.company_key
  left join router_decisions dec on dec.run_id = p_run_id and dec.company_key = co.company_key
  left join sf_account_signal_sync y on y.sf_account_id = co.sf_account_id
  where co.sf_account_id is not null
    and (y.sf_account_id is null or y.last_score is distinct from coalesce(r.signal_score, 0)
         or y.last_top is distinct from coalesce(case when r.top_title is not null then 'GTM hire: ' || r.top_title when r.top_tool is not null then 'Tool added: ' || r.top_tool end, '')
         or y.last_live is distinct from coalesce(r.live_clusters, 0)::int
         or y.last_priority is distinct from coalesce(dec.priority, 0)
         or y.last_tier is distinct from coalesce(dec.tier, 'none')
         or y.last_play is distinct from dec.play_key)
),
tasks as (
  select dec.*, (now() + make_interval(hours => coalesce((dec.detail->>'first_step_hours')::int, 24)))::date due
  from router_decisions dec
  where dec.run_id = p_run_id and dec.tier = 'A' and dec.alert and dec.sf_account_id is not null
    and not exists (select 1 from router_sf_tasks t where t.sf_account_id = dec.sf_account_id and t.play_key is not distinct from dec.play_key
                    and t.sf_task_id is not null and t.created_at > now() - interval '14 days')
)
select jsonb_build_object(
  'signals', coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
    'attributes', jsonb_build_object('type', 'Signal__c'),
    'Signal_Key__c', ref,
    'Name', left(case signal_type when 'gtm_hire' then 'GTM Hire' when 'tool_added' then 'Tool Added'
                   when 'funding' then 'Funding' else 'New Exec' end || ': ' ||
                 coalesce(evidence->>'title', evidence->>'tool', company_name), 80),
    'Account__c', sf_account_id,
    'Signal_Type__c', signal_type,
    'Detail__c', left(coalesce(evidence->>'title', evidence->>'tool'), 255),
    'Event_Date__c', to_char(event_at, 'YYYY-MM-DD'),
    'Detected_Date__c', to_char(detected_at, 'YYYY-MM-DD'),
    'Expires_On__c', to_char(expires_at, 'YYYY-MM-DD'),
    'Strength__c', sf_strength,
    'Band__c', sf_band,
    'Strength_Updated__c', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'Who__c', left(who, 255),
    'Angle__c', left(angle, 2000),
    'Channel__c', left(channel, 255),
    'Source_URL__c', left(evidence->>'url', 255)
  )) order by sf_strength desc) from sig), '[]'::jsonb),
  'accounts', coalesce((select jsonb_agg(jsonb_build_object(
      'attributes', jsonb_build_object('type', 'Account'),
      'Id', sf_account_id,
      'Signal_Score__c', score,
      'Top_Signal__c', nullif(left(top, 255), ''),
      'Live_Signals__c', live,
      'Signal_Score_Updated__c', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
      'Priority__c', priority,
      'Priority_Tier__c', tier,
      'Play__c', left(play_name, 100),
      'Play_Opener__c', case when play_key is null then null else left(
          'WHO: ' || coalesce(who, '') || E'\nCHANNEL: ' || coalesce(channel, '') || E'\nOPENER: ' || coalesce(opener, ''), 2000) end,
      'Routed_At__c', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))) from acc), '[]'::jsonb),
  'account_keys', coalesce((select jsonb_agg(jsonb_build_object('sf_account_id', sf_account_id, 'company_key', company_key,
      'score', score, 'top', top, 'live', live, 'priority', priority, 'tier', tier, 'play', play_key)) from acc), '[]'::jsonb),
  'tasks', coalesce((select jsonb_agg(jsonb_build_object(
      'attributes', jsonb_build_object('type', 'Task'),
      'WhatId', sf_account_id,
      'Subject', left('Signal play (Tier A): ' || coalesce(detail->>'play', 'follow up') || ' - ' || company_name, 255),
      'Description', left('Priority ' || priority || ' (ICP ' || icp_score || ' x signal ' || signal_score || ')' ||
          E'\nWhy now: ' || coalesce(detail->>'top_title', detail->>'top_tool', '') ||
          E'\nWho: ' || coalesce(detail->>'who', '') || E'\nChannel: ' || coalesce(detail->>'channel', '') ||
          E'\nOpener: ' || coalesce(detail->>'opener', '') || E'\nSource: ' || coalesce(detail->>'top_url', ''), 32000),
      'ActivityDate', to_char(due, 'YYYY-MM-DD'),
      'Priority', 'High',
      'Status', 'Not Started')) from tasks), '[]'::jsonb),
  'task_keys', coalesce((select jsonb_agg(jsonb_build_object('sf_account_id', sf_account_id, 'company_key', company_key, 'play', play_key)) from tasks), '[]'::jsonb)
);
$$;

-- Record Salesforce's answers (same order as sent).
create or replace function router_sf_record(p_run_id bigint, p_payload jsonb, p_signal_results jsonb, p_account_results jsonb, p_task_results jsonb)
returns jsonb language plpgsql as $$
declare i int; r jsonb; rec jsonb; ok_s int := 0; bad_s int := 0; ok_a int := 0; bad_a int := 0; ok_t int := 0; bad_t int := 0; errs jsonb := '[]'::jsonb;
begin
  for i in 0 .. coalesce(jsonb_array_length(p_payload->'signals'), 0) - 1 loop
    rec := p_payload->'signals'->i; r := p_signal_results->i;
    if coalesce((r->>'success')::boolean, false) then
      ok_s := ok_s + 1;
      insert into sf_signal_sync(ref, sf_id, last_strength, last_band, last_synced_at, last_error)
      values (rec->>'Signal_Key__c', r->>'id', (rec->>'Strength__c')::int, rec->>'Band__c', now(), null)
      on conflict (ref) do update set sf_id = coalesce(excluded.sf_id, sf_signal_sync.sf_id), last_strength = excluded.last_strength,
        last_band = excluded.last_band, last_synced_at = now(), last_error = null;
    else
      bad_s := bad_s + 1; errs := errs || jsonb_build_object('signal', rec->>'Signal_Key__c', 'error', r->'errors');
    end if;
  end loop;
  for i in 0 .. coalesce(jsonb_array_length(p_payload->'account_keys'), 0) - 1 loop
    rec := p_payload->'account_keys'->i; r := p_account_results->i;
    if coalesce((r->>'success')::boolean, false) then
      ok_a := ok_a + 1;
      insert into sf_account_signal_sync(sf_account_id, company_key, last_score, last_top, last_live, last_priority, last_tier, last_play, last_synced_at, last_error)
      values (rec->>'sf_account_id', rec->>'company_key', (rec->>'score')::int, rec->>'top', (rec->>'live')::int,
              (rec->>'priority')::int, rec->>'tier', rec->>'play', now(), null)
      on conflict (sf_account_id) do update set last_score = excluded.last_score, last_top = excluded.last_top, last_live = excluded.last_live,
        last_priority = excluded.last_priority, last_tier = excluded.last_tier, last_play = excluded.last_play, last_synced_at = now(), last_error = null;
    else
      bad_a := bad_a + 1; errs := errs || jsonb_build_object('account', rec->>'sf_account_id', 'error', r->'errors');
    end if;
  end loop;
  for i in 0 .. coalesce(jsonb_array_length(p_payload->'task_keys'), 0) - 1 loop
    rec := p_payload->'task_keys'->i; r := p_task_results->i;
    insert into router_sf_tasks(run_id, sf_account_id, company_key, play_key, sf_task_id, error)
    values (p_run_id, rec->>'sf_account_id', rec->>'company_key', rec->>'play',
            case when coalesce((r->>'success')::boolean, false) then r->>'id' end,
            case when coalesce((r->>'success')::boolean, false) then null else left((r->'errors')::text, 500) end);
    if coalesce((r->>'success')::boolean, false) then ok_t := ok_t + 1;
    else bad_t := bad_t + 1; errs := errs || jsonb_build_object('task', rec->>'sf_account_id', 'error', r->'errors'); end if;
  end loop;
  return jsonb_build_object('signals_sent', coalesce(jsonb_array_length(p_payload->'signals'),0), 'signals_ok', ok_s, 'signals_failed', bad_s,
                            'accounts_sent', coalesce(jsonb_array_length(p_payload->'accounts'),0), 'accounts_ok', ok_a, 'accounts_failed', bad_a,
                            'tasks_sent', coalesce(jsonb_array_length(p_payload->'tasks'),0), 'tasks_ok', ok_t, 'tasks_failed', bad_t, 'errors', errs);
end $$;

-- Slack digest content for one run (built in SQL so it is easy to read and change)
create or replace function router_slack_digest(p_run_id bigint) returns jsonb language sql stable as $$
with d as (select * from router_decisions where run_id = p_run_id),
r as (select * from router_runs where id = p_run_id),
newA as (select * from d where alert and tier in ('A','B') order by priority desc limit 10),
rev as (select * from d where alert and tier = 'review' order by signal_score desc limit 10)
select jsonb_build_object(
  'alerts', (select count(*) from d where alert),
  'text', 'Signal Router: ' || (select count(*) from d where tier='A') || ' Tier A, ' || (select count(*) from d where tier='B') || ' Tier B, '
          || (select count(*) from d where alert) || ' new',
  'blocks', jsonb_build_array(
     jsonb_build_object('type','header','text', jsonb_build_object('type','plain_text','text',
        'Signal Router · ' || to_char(now() at time zone 'Africa/Lagos', 'Dy DD Mon'))),
     jsonb_build_object('type','section','text', jsonb_build_object('type','mrkdwn','text',
        '*Tier A:* ' || (select count(*) from d where tier='A') || '   *Tier B:* ' || (select count(*) from d where tier='B') ||
        '   *Tier C:* ' || (select count(*) from d where tier='C') || '   *Needs ICP check:* ' || (select count(*) from d where tier='review') ||
        E'\n_Sources:_ ' || coalesce((select source_health->>'summary' from r), 'n/a')))
  )
  || coalesce((select jsonb_agg(jsonb_build_object('type','section','text', jsonb_build_object('type','mrkdwn','text',
        ':rotating_light: *' || company_name || '* · Tier ' || tier || ' · priority ' || priority ||
        ' (ICP ' || icp_score || ' × signal ' || signal_score || ')' ||
        E'\n*Why now:* ' || coalesce(detail->>'top_title', detail->>'top_tool', '-') ||
        E'\n*Play:* ' || coalesce(detail->>'play', '-') || ' → ' || coalesce(detail->>'who', '') || ' via ' || coalesce(detail->>'channel', '') ||
        E'\n> ' || left(coalesce(detail->>'opener', ''), 280) ||
        case when sf_account_id is not null then E'\n_Salesforce task created_' else E'\n_Not in Salesforce yet_' end))) from newA), '[]'::jsonb)
  || case when exists (select 1 from rev) then jsonb_build_array(jsonb_build_object('type','section','text', jsonb_build_object('type','mrkdwn','text',
        ':mag: *Strong signal, no ICP score yet (check fit):* ' ||
        (select string_agg(company_name || ' (' || coalesce(detail->>'top_title', detail->>'top_tool', '') || ')', ', ') from rev)))) else '[]'::jsonb end
  || case when (select count(*) from d where alert) = 0 then jsonb_build_array(jsonb_build_object('type','context','elements',
        jsonb_build_array(jsonb_build_object('type','mrkdwn','text','No new accounts entered Tier A/B today.')))) else '[]'::jsonb end
);
$$;

-- Keep the old n8n payload in step with the router (so both agree on duplicates / noise if both ever run)
create or replace function sf_signal_payload(p_max int default 200)
returns jsonb language sql stable as $$
  select jsonb_build_object('signals', p->'signals', 'accounts', '[]'::jsonb, 'account_keys', '[]'::jsonb)
  from (select router_sf_payload(coalesce((select max(id) from router_runs), 0), p_max) p) x
$$;
