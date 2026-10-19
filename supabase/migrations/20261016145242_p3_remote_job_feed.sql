-- p3_remote_job_feed (applied 2026-10-16)

-- Sources and their politeness limits
create table if not exists job_feed_sources (
  source text primary key,
  display_name text not null,
  home_url text not null,
  min_interval interval not null,
  enabled boolean not null default true,
  last_called_at timestamptz,
  last_status text,
  terms_note text
);
insert into job_feed_sources (source, display_name, home_url, min_interval, terms_note) values
 ('remotive','Remotive','https://remotive.com', interval '20 hours','Max 4 calls/day, >2/min blocked, jobs delayed 24h. Link back + name Remotive. Do not resubmit jobs elsewhere.'),
 ('remoteok','Remote OK','https://remoteok.com', interval '20 hours','Link back to Remote OK job URL and name it as source.'),
 ('jobicy','Jobicy','https://jobicy.com', interval '20 hours','No more than hourly. Keep Jobicy canonical URL and name as source.'),
 ('himalayas','Himalayas','https://himalayas.app', interval '20 hours','Max 20 per page, 429 when over limit, data refreshes daily. Link back + attribute.'),
 ('weworkremotely','We Work Remotely','https://weworkremotely.com', interval '20 hours','RSS feed; link back to WWR listing.')
on conflict (source) do nothing;

create table if not exists job_feed_runs (
  id bigserial primary key,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  mode text,
  stats jsonb
);

-- Jobs from worldwide-remote boards (GTM roles only; no full descriptions stored)
create table if not exists remote_jobs (
  source text not null references job_feed_sources(source),
  source_id text not null,
  company text,
  title text not null,
  url text not null,
  location_text text,
  allowed_countries text[],
  timezone_offsets numeric[],
  published_at timestamptz,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  closed_at timestamptz,
  job_function text,
  seniority text,
  desc_verdict text check (desc_verdict in ('yes','no')),
  desc_evidence text,
  primary key (source, source_id)
);

-- Description checks for ATS jobs (Greenhouse / Lever / Ashby) whose location alone is unclear
create table if not exists job_description_checks (
  ats text not null,
  token text not null,
  job_id text not null,
  checked_at timestamptz not null default now(),
  http_status int,
  desc_verdict text check (desc_verdict in ('yes','no')),
  desc_evidence text,
  primary key (ats, token, job_id)
);

-- Location rule: specific place other than Nigeria/Africa = no; worldwide = yes; bare "Remote" = maybe
create or replace function geo_verdict(p_text text, p_countries text[] default null)
returns table (verdict text, reason text)
language plpgsql immutable set search_path = public as $$
declare t text; rest text; cs text;
begin
  if p_countries is not null then
    if cardinality(p_countries) = 0 then return query select 'yes', 'Board says no country restriction'; return; end if;
    cs := lower(array_to_string(p_countries, ', '));
    if cs ~ '(nigeria|africa|worldwide|anywhere)' then return query select 'yes', 'Allowed countries include Nigeria/Africa'; return; end if;
    return query select 'no', 'Limited to ' || left(array_to_string(p_countries, ', '), 80); return;
  end if;
  t := lower(coalesce(p_text, ''));
  if t ~ '(nigeria|lagos|abuja|\mafrica)' then return query select 'yes', 'Location names Nigeria/Africa'; return; end if;
  if t ~ '(emea|europe, middle east)' then return query select 'maybe', 'EMEA: usually only countries where they have an entity'; return; end if;
  if t ~ '(\mcet\M|\mcest\M|gmt|utc ?\+ ?[0-2]\M|utc ?[-−] ?[0-3]\M|european time ?zones?)' and t !~ '(\musa?\M|united states|canada|\muk\M|united kingdom|americas)' then
    return query select 'maybe', 'Timezone requirement close to Lagos (UTC+1)'; return;
  end if;
  rest := regexp_replace(t, '(anywhere in the world|anywhere|worldwide|world wide|globally|global|fully remote|100% remote|remote first|remote-first|remote|work from home|wfh|distributed|flexible|location|hybrid|\(|\)|/|,|;|\||-|–|\mor\M|\mand\M|\min\M|\mthe\M|\d+%)', ' ', 'g');
  rest := btrim(regexp_replace(rest, '\s+', ' ', 'g'));
  if rest = '' then
    if t ~ '(anywhere|worldwide|world wide|global)' then return query select 'yes', 'Posted as worldwide / anywhere'; return; end if;
    if t ~ 'remote' then return query select 'maybe', 'Says "Remote" with no country: check the description'; return; end if;
    return query select 'maybe', 'No location given'; return;
  end if;
  return query select 'no', 'Limited to ' || left(rest, 80);
end $$;

-- Combine location rule with what the description says
create or replace function eligibility(p_geo text, p_desc text)
returns text language sql immutable as $$
  select case
    when p_geo = 'no' then case when p_desc = 'yes' then 'maybe' else 'no' end
    when p_geo = 'yes' then case when p_desc = 'no' then 'maybe' else 'yes' end
    else case when p_desc = 'yes' then 'yes' when p_desc = 'no' then 'no' else 'maybe' end
  end $$;

-- Ingest a batch from one board. Only GTM roles are kept.
create or replace function ingest_remote_jobs(p_source text, p_jobs jsonb, p_full_list boolean default false)
returns jsonb language plpgsql set search_path = public as $$
declare j jsonb; nt record; n_seen int := 0; n_kept int := 0; n_new int := 0; n_closed int := 0; is_new boolean;
begin
  for j in select * from jsonb_array_elements(coalesce(p_jobs, '[]')) loop
    n_seen := n_seen + 1;
    select * into nt from normalize_title(j->>'title');
    continue when nt.job_function = 'Unmapped';
    insert into remote_jobs as r (source, source_id, company, title, url, location_text, allowed_countries, timezone_offsets,
                                  published_at, job_function, seniority, desc_verdict, desc_evidence)
    values (p_source, j->>'id', j->>'company', j->>'title', j->>'url', j->>'location',
            case when j ? 'countries' and jsonb_typeof(j->'countries') = 'array' then array(select jsonb_array_elements_text(j->'countries')) end,
            case when jsonb_typeof(j->'tz') = 'array' then array(select (x)::numeric from jsonb_array_elements_text(j->'tz') x) end,
            (j->>'published_at')::timestamptz, nt.job_function, nt.seniority, j->>'desc_verdict', j->>'desc_evidence')
    on conflict (source, source_id) do update set company = excluded.company, title = excluded.title, url = excluded.url,
      location_text = excluded.location_text, allowed_countries = excluded.allowed_countries, timezone_offsets = excluded.timezone_offsets,
      published_at = coalesce(excluded.published_at, r.published_at), job_function = excluded.job_function, seniority = excluded.seniority,
      desc_verdict = excluded.desc_verdict, desc_evidence = excluded.desc_evidence, last_seen_at = now(), closed_at = null
    returning (xmax = 0) into is_new;
    n_kept := n_kept + 1; if is_new then n_new := n_new + 1; end if;
  end loop;
  -- A job counts as closed when the board stops listing it for 3 days (search-based sources do not return the full list every day)
  with c as (update remote_jobs set closed_at = now()
             where source = p_source and closed_at is null
               and (case when p_full_list then source_id not in (select x->>'id' from jsonb_array_elements(coalesce(p_jobs,'[]')) x)
                         else last_seen_at < now() - interval '3 days' end)
             returning 1)
  select count(*) into n_closed from c;
  update job_feed_sources set last_called_at = now(), last_status = 'ok ' || n_seen || ' seen' where source = p_source;
  return jsonb_build_object('source', p_source, 'seen', n_seen, 'kept', n_kept, 'new', n_new, 'closed', n_closed);
end $$;

-- Which ATS jobs still need their description read (location unclear, GTM role, open)
create or replace view ats_jobs_to_describe as
select j.ats, j.token, j.job_id
from ats_jobs j
cross join lateral geo_verdict(j.location) g
left join job_description_checks d using (ats, token, job_id)
where j.closed_at is null and j.job_function <> 'Unmapped' and g.verdict = 'maybe'
  and (d.checked_at is null or d.checked_at < now() - interval '14 days')
order by j.published_at desc nulls last;

alter table job_feed_sources enable row level security;
alter table job_feed_runs enable row level security;
alter table remote_jobs enable row level security;
alter table job_description_checks enable row level security;
