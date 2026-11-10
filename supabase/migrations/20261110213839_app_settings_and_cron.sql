-- Settings (alert emails, webhook secret) and the scheduled alert jobs
create extension if not exists pg_cron;
create extension if not exists pg_net;

create table public.app_settings (
  id boolean primary key default true check (id),
  shop_name text not null default 'Amalfi Desserts',
  alert_emails text[] not null default '{}',
  resend_api_key text,
  alert_from text not null default 'Amalfi Stock <onboarding@resend.dev>',
  webhook_secret text not null default encode(extensions.gen_random_bytes(24),'hex'),
  cron_secret text not null default encode(extensions.gen_random_bytes(24),'hex'),
  updated_at timestamptz not null default now()
);
insert into public.app_settings default values;
alter table public.app_settings enable row level security;
create policy settings_owner_read on public.app_settings for select to authenticated using ((select private.is_owner()));
create policy settings_owner_upd on public.app_settings for update to authenticated
  using ((select private.is_owner())) with check ((select private.is_owner()));
revoke all on public.app_settings from anon;
grant select, update on public.app_settings to authenticated;

-- every 5 min: email any new low-stock alerts
select cron.schedule('amalfi-send-alerts', '*/5 * * * *', $$
  select net.http_post(
    url := 'https://byoufnhfuicamwqjdrkb.supabase.co/functions/v1/send-alerts',
    headers := jsonb_build_object('Content-Type','application/json',
      'x-cron-secret', (select cron_secret from public.app_settings)),
    body := '{"mode":"alerts"}'::jsonb)
$$);
-- daily summary at 08:00 UTC (8am UK in winter, 9am in summer)
select cron.schedule('amalfi-daily-summary', '0 8 * * *', $$
  select net.http_post(
    url := 'https://byoufnhfuicamwqjdrkb.supabase.co/functions/v1/send-alerts',
    headers := jsonb_build_object('Content-Type','application/json',
      'x-cron-secret', (select cron_secret from public.app_settings)),
    body := '{"mode":"summary"}'::jsonb)
$$);

-- applied separately afterwards
alter publication supabase_realtime add table public.stock_movements, public.alerts;
revoke execute on function public.rls_auto_enable() from public, anon, authenticated;
