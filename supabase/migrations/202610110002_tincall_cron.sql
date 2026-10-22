-- Project-owned scheduler. Store the URL and bearer in Supabase Vault after deployment.
create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;
create extension if not exists supabase_vault with schema vault;

select cron.schedule('tincall-worker','* * * * *',$job$
  select net.http_post(
    url := endpoint.decrypted_secret || '/worker',
    headers := jsonb_build_object('Content-Type','application/json','Authorization','Bearer ' || credential.decrypted_secret),
    body := '{}'::jsonb,
    timeout_milliseconds := 5000
  )
  from vault.decrypted_secrets endpoint, vault.decrypted_secrets credential
  where endpoint.name='tincall_function_base' and credential.name='tincall_worker_token';
$job$);
