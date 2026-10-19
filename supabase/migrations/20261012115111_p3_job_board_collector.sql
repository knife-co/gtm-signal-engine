-- p3_job_board_collector (applied 2026-10-12)
create table if not exists ats_boards (
  ats text not null check (ats in ('greenhouse','lever','ashby')),
  token text not null,
  company_name text,
  company_key text references icp_companies(company_key),
  board_name text,
  name_check text,
  source text not null,
  status text not null default 'unchecked' check (status in ('unchecked','valid','not_found','error')),
  job_count int, gtm_job_count int,
  last_checked_at timestamptz, last_error text,
  created_at timestamptz not null default now(),
  primary key (ats, token));
alter table ats_boards enable row level security;

create table if not exists ats_jobs (
  ats text not null, token text not null, job_id text not null,
  title text, department text, location text, is_remote boolean, url text,
  published_at timestamptz,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  closed_at timestamptz,
  job_function text, seniority text,
  raw jsonb,
  primary key (ats, token, job_id),
  foreign key (ats, token) references ats_boards(ats, token));
alter table ats_jobs enable row level security;
create index if not exists ats_jobs_open_idx on ats_jobs (job_function) where closed_at is null;

create table if not exists signals (
  id bigserial primary key,
  signal_type text not null check (signal_type in ('gtm_hire','funding','tool_added','new_exec')),
  company_name text, company_key text references icp_companies(company_key), domain text,
  ref text not null,
  detected_at timestamptz not null default now(),
  event_at timestamptz,
  window_days int not null,
  expires_at timestamptz,
  who text, angle text, channel text,
  evidence jsonb,
  unique (signal_type, ref));
alter table signals enable row level security;

create or replace function signals_set_expiry() returns trigger language plpgsql as $$
begin
  new.expires_at := coalesce(new.event_at, new.detected_at, now()) + make_interval(days => new.window_days);
  return new;
end $$;
create trigger trg_signals_expiry before insert or update of event_at, window_days on signals
  for each row execute function signals_set_expiry();

create table if not exists collector_runs (
  id bigserial primary key, mode text not null, started_at timestamptz not null default now(), finished_at timestamptz,
  boards_checked int, boards_valid int, boards_not_found int, boards_error int,
  jobs_seen int, jobs_new int, jobs_closed int, gtm_signals_new int, notes jsonb);
alter table collector_runs enable row level security;

create or replace view boards_to_probe with (security_invoker = true) as
  select ats, token, company_name from ats_boards
  where status = 'unchecked' or (status in ('not_found','error') and last_checked_at < now() - interval '30 days')
  order by (status = 'unchecked') desc, last_checked_at nulls first, token, ats;

create or replace view boards_to_collect with (security_invoker = true) as
  select ats, token, company_name from ats_boards where status = 'valid' order by last_checked_at nulls first;

create or replace function ingest_board(p_ats text, p_token text, p_jobs jsonb, p_board_name text default null)
returns jsonb language plpgsql set search_path = public, extensions as $$
declare n_seen int := 0; n_new int := 0; n_closed int := 0; n_sig int := 0; b ats_boards; j jsonb; nt record; is_new boolean;
begin
  select * into b from ats_boards where ats = p_ats and token = p_token;
  for j in select * from jsonb_array_elements(coalesce(p_jobs, '[]')) loop
    select * into nt from normalize_title(j->>'title');
    insert into ats_jobs as t (ats, token, job_id, title, department, location, is_remote, url, published_at, job_function, seniority, raw)
    values (p_ats, p_token, j->>'id', j->>'title', j->>'department', j->>'location', (j->>'is_remote')::boolean, j->>'url',
            (j->>'published_at')::timestamptz, nt.job_function, nt.seniority, j->'raw')
    on conflict (ats, token, job_id) do update set title = excluded.title, department = excluded.department,
      location = excluded.location, is_remote = excluded.is_remote, url = excluded.url, published_at = excluded.published_at,
      job_function = excluded.job_function, seniority = excluded.seniority, last_seen_at = now(), closed_at = null
    returning (xmax = 0) into is_new;
    n_seen := n_seen + 1; if is_new then n_new := n_new + 1; end if;

    if nt.job_function <> 'Unmapped' and coalesce((j->>'published_at')::timestamptz, now()) > now() - interval '30 days' then
      insert into signals (signal_type, company_name, company_key, ref, event_at, window_days, who, angle, channel, evidence)
      values ('gtm_hire', coalesce(b.board_name, b.company_name, p_token), b.company_key, p_ats||':'||p_token||':'||(j->>'id'),
              coalesce((j->>'published_at')::timestamptz, now()), 30,
              'Hiring manager for the role (usually Head of RevOps / Sales Ops / Marketing Ops)',
              'Reference the pain the role is hired to fix: ' || (j->>'title'),
              'LinkedIn connection + short email',
              jsonb_build_object('title', j->>'title', 'url', j->>'url', 'function', nt.job_function,
                                 'seniority', nt.seniority, 'location', j->>'location', 'ats', p_ats, 'token', p_token))
      on conflict (signal_type, ref) do nothing;
      if found then n_sig := n_sig + 1; end if;
    end if;
  end loop;

  with c as (update ats_jobs set closed_at = now()
             where ats = p_ats and token = p_token and closed_at is null
               and job_id not in (select x->>'id' from jsonb_array_elements(coalesce(p_jobs,'[]')) x)
             returning 1)
  select count(*) into n_closed from c;

  update ats_boards set status = 'valid', last_checked_at = now(), last_error = null, job_count = n_seen,
    board_name = coalesce(p_board_name, board_name),
    name_check = case when coalesce(p_board_name, board_name) is null then 'not available'
                      else name_verdict(normalize_company_name(company_name), normalize_company_name(coalesce(p_board_name, board_name))) end,
    gtm_job_count = (select count(*) from ats_jobs where ats = p_ats and token = p_token and closed_at is null and job_function <> 'Unmapped')
  where ats = p_ats and token = p_token;
  return jsonb_build_object('seen', n_seen, 'new', n_new, 'closed', n_closed, 'signals', n_sig);
end $$;

create or replace function mark_board(p_ats text, p_token text, p_status text, p_error text default null)
returns void language sql set search_path = public as $$
  update ats_boards set status = p_status, last_checked_at = now(), last_error = left(p_error, 300)
  where ats = p_ats and token = p_token;
$$;

create or replace view gtm_hiring_signals with (security_invoker = true) as
  select s.company_name, s.company_key, s.evidence->>'title' as title, s.evidence->>'function' as job_function,
         s.evidence->>'seniority' as seniority, s.evidence->>'location' as location, s.event_at as posted_at,
         s.expires_at, s.who, s.angle, s.channel, s.evidence->>'url' as url
  from signals s where s.signal_type = 'gtm_hire' and s.expires_at > now()
  order by s.event_at desc;
