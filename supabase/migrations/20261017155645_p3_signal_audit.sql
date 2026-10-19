-- p3_signal_audit (applied 2026-10-17)

-- Manual audit of delivered signals. Rules are written before the sample is drawn.
create table if not exists signal_audit_rules (
  check_key text primary key,
  question text not null,
  fail_means text not null
);
insert into signal_audit_rules values
 ('real',    'Does the posting exist (or existed) as a real opening on the company''s own job board?', 'Template, placeholder, talent pool, evergreen "general application", or the board says it never existed.'),
 ('role',    'Is it a GTM operations / systems / strategy hire: someone who will own or change how the company sells or markets (RevOps, Sales Ops, Marketing Ops, GTM Engineering, CRM admin/dev, marketing automation, GTM strategy, demand gen ops)?', 'Pure seller (AE/SDR), recruiter, finance, legal, engineering, support, or a role that only mentions GTM in passing.'),
 ('company', 'Is the signal attached to the right company?', 'Board belongs to a different company, an agency hiring for a client, or a recruiter.'),
 ('date',    'Was it posted inside the 30-day window the signal claims?', 'The posting is older than the window (a repost or an old job).')
on conflict (check_key) do nothing;

create table if not exists signal_audit (
  audit_id text not null,             -- e.g. 2026-10-17
  sample_rank int not null,
  account_key text, company_name text, lead_ref text not null,
  title text, url text,
  fetched_status int, fetched_title text, fetched_location text, fetched_posted date, fetched_excerpt text,
  check_real boolean, check_role boolean, check_company boolean, check_date boolean,
  verdict text check (verdict in ('true_positive','false_positive')),
  fail_reason text,
  auditor text, audited_at timestamptz,
  owner_verdict text check (owner_verdict in ('true_positive','false_positive')),  -- for Omiwade's own second look
  owner_note text,
  primary key (audit_id, sample_rank)
);
alter table signal_audit_rules enable row level security;
alter table signal_audit enable row level security;

-- Draw the sample: 50 delivered (non-noise) signal clusters, order fixed by a hash so anyone can redraw the same 50.
insert into signal_audit (audit_id, sample_rank, account_key, company_name, lead_ref, title, url)
select '2026-10-17', row_number() over (order by md5(lead_ref || ':audit-2026-10-17')), account_key, company_name, lead_ref,
       lead_evidence->>'title', lead_evidence->>'url'
from signal_clusters
where not is_noise and newest_event <= '2026-10-17 05:30+00'
order by md5(lead_ref || ':audit-2026-10-17')
limit 50
on conflict do nothing;
