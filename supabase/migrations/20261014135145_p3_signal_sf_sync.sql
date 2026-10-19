-- p3_signal_sf_sync (applied 2026-10-14)
-- What we last sent to Salesforce, so each run only sends what changed.
create table if not exists sf_signal_sync (
  ref text primary key,
  sf_id text,
  last_strength int,
  last_band text,
  last_synced_at timestamptz,
  last_error text
);
create table if not exists sf_account_signal_sync (
  sf_account_id text primary key,
  company_key text,
  last_score int,
  last_top text,
  last_live int,
  last_synced_at timestamptz,
  last_error text
);
create table if not exists sf_signal_sync_runs (
  id bigserial primary key,
  run_label text,
  started_at timestamptz default now(),
  signals_sent int, signals_ok int, signals_failed int,
  accounts_sent int, accounts_ok int, accounts_failed int,
  errors jsonb
);
alter table sf_signal_sync enable row level security;
alter table sf_account_signal_sync enable row level security;
alter table sf_signal_sync_runs enable row level security;

-- Build everything n8n should send. Rules:
--  * only signals for companies that are already Salesforce Accounts (the ICP gate stays the gatekeeper)
--  * a signal is sent if it is live and new or changed; or if it was sent before and has since gone cold / closed (so Salesforce shows that)
--  * dead signals that were never sent are not sent at all
create or replace function sf_signal_payload(p_max int default 200)
returns jsonb language sql stable as $$
with sig as (
  select s.*, c.sf_account_id, x.last_strength, x.last_band, x.ref is not null as sent_before
  from signals_scored s
  join icp_companies c using (company_key)
  left join sf_signal_sync x on x.ref = s.ref
  where c.sf_account_id is not null
    and ((s.strength > 0 and (x.ref is null or x.last_strength is distinct from s.strength or x.last_band is distinct from s.band))
      or (s.strength = 0 and x.ref is not null and (x.last_strength <> 0 or x.last_band is distinct from s.band)))
  order by s.strength desc
  limit p_max
),
recs as (
  select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
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
    'Strength__c', strength,
    'Band__c', band,
    'Strength_Updated__c', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'Who__c', left(who, 255),
    'Angle__c', left(angle, 2000),
    'Channel__c', left(channel, 255),
    'Source_URL__c', left(evidence->>'url', 255)
  )) order by strength desc) arr
  from sig
),
acc as (
  -- every Salesforce account, scored (0 if no live signals), sent only when the score, top signal or count changed
  select c.sf_account_id, c.company_key,
         coalesce(a.signal_score, 0) score, coalesce(a.top_signal, '') top, coalesce(a.live_signals, 0)::int live
  from icp_companies c
  left join account_signal_score a using (company_key)
  left join sf_account_signal_sync y on y.sf_account_id = c.sf_account_id
  where c.sf_account_id is not null
    and (y.sf_account_id is null or y.last_score is distinct from coalesce(a.signal_score, 0)
         or y.last_top is distinct from coalesce(a.top_signal, '') or y.last_live is distinct from coalesce(a.live_signals, 0)::int)
)
select jsonb_build_object(
  'signals', coalesce((select arr from recs), '[]'::jsonb),
  'accounts', coalesce((select jsonb_agg(jsonb_build_object(
      'attributes', jsonb_build_object('type', 'Account'),
      'Id', sf_account_id,
      'Signal_Score__c', score,
      'Top_Signal__c', nullif(left(top, 255), ''),
      'Live_Signals__c', live,
      'Signal_Score_Updated__c', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))) from acc), '[]'::jsonb),
  'account_keys', coalesce((select jsonb_agg(jsonb_build_object('sf_account_id', sf_account_id, 'company_key', company_key,
      'score', score, 'top', top, 'live', live)) from acc), '[]'::jsonb)
);
$$;

-- Record what Salesforce said. Results come back in the same order as the records sent.
create or replace function sf_signal_record(p_run_label text, p_payload jsonb, p_signal_results jsonb, p_account_results jsonb)
returns jsonb language plpgsql as $$
declare i int; r jsonb; rec jsonb; ok_s int := 0; bad_s int := 0; ok_a int := 0; bad_a int := 0; errs jsonb := '[]'::jsonb;
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
      bad_s := bad_s + 1; errs := errs || jsonb_build_object('ref', rec->>'Signal_Key__c', 'error', r->'errors');
      insert into sf_signal_sync(ref, last_error) values (rec->>'Signal_Key__c', left((r->'errors')::text, 500))
      on conflict (ref) do update set last_error = excluded.last_error;
    end if;
  end loop;
  for i in 0 .. coalesce(jsonb_array_length(p_payload->'account_keys'), 0) - 1 loop
    rec := p_payload->'account_keys'->i; r := p_account_results->i;
    if coalesce((r->>'success')::boolean, false) then
      ok_a := ok_a + 1;
      insert into sf_account_signal_sync(sf_account_id, company_key, last_score, last_top, last_live, last_synced_at, last_error)
      values (rec->>'sf_account_id', rec->>'company_key', (rec->>'score')::int, rec->>'top', (rec->>'live')::int, now(), null)
      on conflict (sf_account_id) do update set last_score = excluded.last_score, last_top = excluded.last_top,
        last_live = excluded.last_live, last_synced_at = now(), last_error = null;
    else
      bad_a := bad_a + 1; errs := errs || jsonb_build_object('account', rec->>'sf_account_id', 'error', r->'errors');
    end if;
  end loop;
  insert into sf_signal_sync_runs(run_label, signals_sent, signals_ok, signals_failed, accounts_sent, accounts_ok, accounts_failed, errors)
  values (p_run_label, coalesce(jsonb_array_length(p_payload->'signals'),0), ok_s, bad_s,
          coalesce(jsonb_array_length(p_payload->'accounts'),0), ok_a, bad_a, errs);
  return jsonb_build_object('signals_ok', ok_s, 'signals_failed', bad_s, 'accounts_ok', ok_a, 'accounts_failed', bad_a, 'errors', errs);
end $$;
