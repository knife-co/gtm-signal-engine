-- p3_ship_core_ops_only (applied 2026-10-18)

-- Ship 18 Oct: after the 50-signal audit, only core-ops hiring signals are delivered (22/22 correct).
-- Broad buckets stay in the data and in Salesforce (band = noise) but no longer drive priority, tasks or alerts.
create table if not exists signal_function_policy (
  job_function text primary key,
  deliver boolean not null,
  why text not null,
  decided_on date not null default current_date
);
alter table signal_function_policy enable row level security;
insert into signal_function_policy (job_function, deliver, why) values
 ('Revenue Operations',   true,  'Audit 17 Oct: 7/7 correct'),
 ('Marketing Operations', true,  'Audit 17 Oct: 8/8 correct'),
 ('Sales Operations',     true,  'Audit 17 Oct: 2/2 correct'),
 ('CRM Administration',   true,  'Audit 17 Oct: 2/2 correct'),
 ('CRM Development',      true,  'Audit 17 Oct: 1/1 correct'),
 ('Marketing Automation', true,  'Audit 17 Oct: 1/1 correct'),
 ('GTM Engineering',      true,  'Audit 17 Oct: 1/1 correct'),
 ('GTM Strategy',         false, 'Audit 17 Oct: 9 of 15 wrong (sellers, finance, support roles with "GTM" in the title)'),
 ('CRM & Lifecycle Marketing', false, 'Audit 17 Oct: 6 of 6 were campaign marketers, not GTM systems owners'),
 ('Demand Generation',    false, 'Audit 17 Oct: 4 of 4 were campaign marketers'),
 ('CRM Consulting',       false, 'Audit 17 Oct: 1 of 1 was an agency consultant serving clients'),
 ('Growth Operations',    false, 'Audit 17 Oct: 1 of 1 was a consumer growth role')
on conflict (job_function) do nothing;

create or replace view signal_clusters with (security_invoker = true) as
WITH s AS (
  SELECT ss.id, ss.signal_type, ss.company_name, ss.company_key, ss.ref, ss.event_at, ss.detected_at, ss.expires_at, ss.age_days,
         ss.job_closed_at, ss.strength, ss.band, ss.who, ss.angle, ss.channel, ss.evidence,
         COALESCE(ss.company_key, 'board:' || (ss.evidence ->> 'ats') || ':' || (ss.evidence ->> 'token')) AS account_key,
         TRIM(BOTH FROM regexp_replace(lower(COALESCE(ss.evidence ->> 'title', ss.evidence ->> 'tool', '')),
              '(\([^)]*\)|,\s*(emea|apac|amer|na|us|uk|latam|remote).*$|\s+-\s+(remote|emea|apac|us|uk).*$|\yr-?\d{4,}\y|[^a-z0-9]+)', ' ', 'g')) AS norm_detail,
         (EXISTS (SELECT 1 FROM signal_noise_rules n
                  WHERE n.enabled AND n.signal_type = ss.signal_type
                    AND COALESCE(ss.evidence ->> 'title', ss.evidence ->> 'tool', '') ~* n.pattern))
         OR (ss.signal_type = 'gtm_hire' AND NOT COALESCE((SELECT p.deliver FROM signal_function_policy p WHERE p.job_function = ss.evidence ->> 'function'), false)) AS is_noise
  FROM signals_scored ss
)
SELECT account_key, company_key, max(company_name) AS company_name, signal_type,
       regexp_replace(norm_detail, '\s+', ' ', 'g') AS norm_detail,
       bool_or(is_noise) AS is_noise, max(strength) AS strength,
       (array_agg(band ORDER BY s.strength DESC, event_at DESC))[1] AS band,
       count(*) AS postings, max(event_at) AS newest_event,
       (array_agg(ref ORDER BY s.strength DESC, event_at DESC))[1] AS lead_ref,
       array_agg(ref ORDER BY s.strength DESC, event_at DESC) AS refs,
       (array_agg(evidence ORDER BY s.strength DESC, event_at DESC))[1] AS lead_evidence
FROM s
GROUP BY account_key, company_key, signal_type, regexp_replace(norm_detail, '\s+', ' ', 'g');
