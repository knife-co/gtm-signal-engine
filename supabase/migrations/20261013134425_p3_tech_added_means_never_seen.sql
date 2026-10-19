-- p3_tech_added_means_never_seen (applied 2026-10-13)
do $m$
declare src text; old_src text;
begin
  src := pg_get_functiondef('public.ingest_tech_scan(bigint,text,text,text,text,int,text,boolean,int,jsonb,text,int,text[])'::regprocedure);
  old_src := src;
  src := replace(src,
    $a$    -- "existing" = seen before by this same detector version
    select true into v_existing from tech_stack
     where company_key = p_company_key and tool = v_det.tool and last_seen >= coalesce(v_prev_scan, 'infinity');$a$,
    $b$    -- "existing" = this company has EVER had this tool recorded (even if it was missing last scan).
    -- Tools can flicker between scans (cookie banners, A/B tests), so "missing last time" is not proof of new.
    select true into v_existing from tech_stack
     where company_key = p_company_key and tool = v_det.tool;$b$);
  if src = old_src then raise exception 'pattern not found, nothing changed'; end if;
  execute src;
end $m$;
