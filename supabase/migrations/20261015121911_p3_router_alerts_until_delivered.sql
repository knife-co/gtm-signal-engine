-- p3_router_alerts_until_delivered (applied 2026-10-15)
do $m$
declare src text; old text;
begin
  -- 1. "previous tier" only counts runs whose alerts were actually delivered (or had none to deliver)
  src := pg_get_functiondef('public.route_accounts(bigint)'::regprocedure); old := src;
  src := replace(src,
    $a$left join lateral (select d.tier from router_decisions d where d.account_key = r.account_key and d.run_id < p_run_id
                     order by d.run_id desc limit 1) prev on true$a$,
    $b$left join lateral (select d.tier from router_decisions d join router_runs rr on rr.id = d.run_id
                     where d.account_key = r.account_key and d.run_id < p_run_id
                       and (rr.slack_status in ('sent', 'no new alerts') or not d.alert)
                     order by d.run_id desc limit 1) prev on true$b$);
  if src = old then raise exception 'route_accounts pattern not found'; end if;
  execute src;

  -- 2. a Tier A task is created whenever none exists for that account + play in the last 14 days (not only on the alert run)
  src := pg_get_functiondef('public.router_sf_payload(bigint,int)'::regprocedure); old := src;
  src := replace(src, $a$where dec.run_id = p_run_id and dec.tier = 'A' and dec.alert and dec.sf_account_id is not null$a$,
                      $b$where dec.run_id = p_run_id and dec.tier = 'A' and dec.sf_account_id is not null$b$);
  if src = old then raise exception 'router_sf_payload pattern not found'; end if;
  execute src;
end $m$;
