-- Daily schedule (pg_cron, times in UTC; Lagos is UTC+1). Replace YOUR_PROJECT_REF and YOUR_ANON_KEY.
-- The anon key only lets the scheduler call the functions (Verify JWT is on); the functions use the
-- service_role key that Supabase injects. Never put the service_role key here.
do $$
declare
  base text := 'https://YOUR_PROJECT_REF.supabase.co/functions/v1/';
  auth text := 'Bearer YOUR_ANON_KEY';
  tpl  text := $t$select net.http_post(url := %L, headers := jsonb_build_object('Content-Type','application/json','Authorization',%L), body := %L::jsonb, timeout_milliseconds := 150000)$t$;
begin
  perform cron.schedule('p3-daily-collect',   '30 5 * * *',  format(tpl, base || 'job-board-collector', auth, '{"mode":"collect","limit":600}'));
  perform cron.schedule('p3-daily-probe',     '45 5 * * *',  format(tpl, base || 'job-board-collector', auth, '{"mode":"probe","limit":400}'));
  perform cron.schedule('p3-daily-tech-scan', '*/5 6 * * *', format(tpl, base || 'tech-stack-detector', auth, '{"limit":40}'));
  perform cron.schedule('p3-jobs-collect',    '20 6 * * *',  format(tpl, base || 'job-feed',            auth, '{"mode":"collect"}'));
  perform cron.schedule('p3-jobs-describe',   '35 6 * * *',  format(tpl, base || 'job-feed',            auth, '{"mode":"describe","limit":120}'));
  perform cron.schedule('p3-jobs-digest',     '45 6 * * *',  format(tpl, base || 'job-feed',            auth, '{"mode":"digest"}'));
  perform cron.schedule('p3-daily-router',    '15 7 * * *',  format(tpl, base || 'signal-router',       auth, '{"mode":"run","trigger":"schedule"}'));
end $$;
