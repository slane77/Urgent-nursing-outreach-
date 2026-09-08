select cron.schedule('outreach-mailshot-worker','* * * * *', $cron$
 select net.http_post(
  url:='https://udttpnaenmyxviuiwxqw.supabase.co/functions/v1/mailshot-worker',
  headers:=jsonb_build_object('Content-Type','application/json','x-worker-secret',(select secret from outreach_private.worker_config where id=true)),
  body:='{}'::jsonb,timeout_milliseconds:=120000);
$cron$);
update outreach_private.worker_config set enabled=true where id=true;
