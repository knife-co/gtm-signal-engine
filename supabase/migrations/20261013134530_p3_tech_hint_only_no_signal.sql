-- p3_tech_hint_only_no_signal (applied 2026-10-13)
update tech_signatures set enabled = false, note = note || ' [disabled 13 Oct: also matched Zoho maillist-manage.com]'
 where tool = 'Mailchimp' and method = 'html' and pattern = 'chimpstatic\.com|list-manage\.com';

do $m$
declare src text; old_src text;
begin
  src := pg_get_functiondef('public.ingest_tech_scan(bigint,text,text,text,text,int,text,boolean,int,jsonb,text,int,text[])'::regprocedure);
  old_src := src;
  src := replace(src,
    $a$       and v_sig_since is not null and v_sig_since < v_prev_scan then$a$,
    $b$       and v_sig_since is not null and v_sig_since < v_prev_scan
       -- a page only *hinting* it will load a script (dns-prefetch / preconnect) is too weak to alert on
       and exists (select 1 from jsonb_array_elements(v_det.ev) e
                   where not ((e->>'evidence') ~* '(dns-prefetch|preconnect|rel=.?prefetch)')) then$b$);
  if src = old_src then raise exception 'pattern not found, nothing changed'; end if;
  execute src;
end $m$;
