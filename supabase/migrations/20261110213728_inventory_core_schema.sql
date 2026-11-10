-- Amalfi Desserts stock tracker: core schema (already applied to the live project)
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create type public.staff_role as enum ('owner','staff');

create table public.staff (
  user_id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  name text,
  role public.staff_role not null default 'staff',
  created_at timestamptz not null default now()
);

create table public.staff_invites (
  email text primary key,
  role public.staff_role not null default 'staff',
  created_at timestamptz not null default now()
);

create or replace function private.is_staff() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.staff where user_id = (select auth.uid()));
$$;
create or replace function private.is_owner() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.staff where user_id = (select auth.uid()) and role = 'owner');
$$;
grant usage on schema private to authenticated;
grant execute on function private.is_staff(), private.is_owner() to authenticated;

-- First account to sign up becomes owner; everyone else needs an invite.
create or replace function private.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
declare inv public.staff_role;
begin
  if not exists (select 1 from public.staff) then
    insert into public.staff(user_id,email,role) values (new.id, lower(new.email), 'owner');
  else
    select role into inv from public.staff_invites where email = lower(new.email);
    if found then
      insert into public.staff(user_id,email,role) values (new.id, lower(new.email), inv);
      delete from public.staff_invites where email = lower(new.email);
    end if;
  end if;
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function private.handle_new_user();

create table public.stock_items (
  id bigint generated always as identity primary key,
  name text not null unique,
  unit text not null default 'slice',
  pack_name text,
  units_per_pack numeric not null default 1 check (units_per_pack > 0),
  low_level numeric not null default 0 check (low_level >= 0),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.menu_items (
  id bigint generated always as identity primary key,
  name text not null unique,
  aliases text[] not null default '{}',
  active boolean not null default true
);

create table public.menu_recipes (
  menu_item_id bigint not null references public.menu_items(id) on delete cascade,
  stock_item_id bigint not null references public.stock_items(id) on delete restrict,
  qty numeric not null check (qty > 0),
  primary key (menu_item_id, stock_item_id)
);
create index on public.menu_recipes(stock_item_id);

create type public.order_channel as enum ('deliveroo','ubereats','justeat','in_store','other');

create table public.orders (
  id bigint generated always as identity primary key,
  channel public.order_channel not null,
  external_id text not null,
  placed_at timestamptz not null default now(),
  raw jsonb,
  created_at timestamptz not null default now(),
  unique (channel, external_id)
);

create table public.order_lines (
  id bigint generated always as identity primary key,
  order_id bigint not null references public.orders(id) on delete cascade,
  item_name text not null,
  qty numeric not null check (qty > 0),
  menu_item_id bigint references public.menu_items(id),
  matched boolean not null default false
);
create index on public.order_lines(order_id);
create index on public.order_lines(menu_item_id);

create type public.movement_reason as enum ('opening','purchase','sale','used','waste','adjustment');

-- Every stock change is a row here; current stock = sum of changes.
create table public.stock_movements (
  id bigint generated always as identity primary key,
  stock_item_id bigint not null references public.stock_items(id) on delete cascade,
  change numeric not null check (change <> 0),
  reason public.movement_reason not null,
  order_id bigint references public.orders(id) on delete set null,
  note text,
  created_by uuid references auth.users(id) default auth.uid(),
  created_at timestamptz not null default now()
);
create index on public.stock_movements(stock_item_id);
create index on public.stock_movements(order_id);
create index on public.stock_movements(created_by);

create table public.alerts (
  id bigint generated always as identity primary key,
  stock_item_id bigint not null references public.stock_items(id) on delete cascade,
  level_at_alert numeric not null,
  kind text not null check (kind in ('low','out')),
  created_at timestamptz not null default now(),
  sent_at timestamptz,
  resolved_at timestamptz
);
create unique index alerts_one_open_per_item on public.alerts(stock_item_id) where resolved_at is null;
create index on public.alerts(stock_item_id);

create view public.stock_levels with (security_invoker = true) as
select s.id, s.name, s.unit, s.pack_name, s.units_per_pack, s.low_level, s.active,
       coalesce(sum(m.change),0) as on_hand,
       coalesce(sum(m.change) filter (where m.change > 0),0) as total_in,
       coalesce(-sum(m.change) filter (where m.change < 0),0) as total_out,
       case when coalesce(sum(m.change),0) <= 0 then 'out'
            when coalesce(sum(m.change),0) <= s.low_level then 'low'
            else 'ok' end as status
from public.stock_items s
left join public.stock_movements m on m.stock_item_id = s.id
group by s.id;

-- Opens an alert when an item drops to its low level, closes it when restocked.
create or replace function private.check_low_stock() returns trigger
language plpgsql security definer set search_path = '' as $$
declare lvl numeric; low numeric;
begin
  select coalesce(sum(change),0) into lvl from public.stock_movements where stock_item_id = new.stock_item_id;
  select low_level into low from public.stock_items where id = new.stock_item_id;
  if lvl <= low then
    insert into public.alerts(stock_item_id, level_at_alert, kind)
    values (new.stock_item_id, lvl, case when lvl <= 0 then 'out' else 'low' end)
    on conflict (stock_item_id) where resolved_at is null
    do update set kind = excluded.kind, level_at_alert = excluded.level_at_alert,
      sent_at = case when public.alerts.kind <> excluded.kind then null else public.alerts.sent_at end;
  else
    update public.alerts set resolved_at = now()
    where stock_item_id = new.stock_item_id and resolved_at is null;
  end if;
  return new;
end $$;
create trigger stock_movement_low_check after insert on public.stock_movements
  for each row execute function private.check_low_stock();

-- Records an order and takes stock off using the recipes. Same order twice = ignored.
create or replace function public.record_order(
  p_channel public.order_channel, p_external_id text, p_lines jsonb,
  p_placed_at timestamptz default now(), p_raw jsonb default null)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare oid bigint; ln jsonb; mid bigint; q numeric; unmatched text[] := '{}';
begin
  insert into public.orders(channel, external_id, placed_at, raw)
  values (p_channel, p_external_id, coalesce(p_placed_at, now()), p_raw)
  on conflict (channel, external_id) do nothing
  returning id into oid;
  if oid is null then
    return jsonb_build_object('status','duplicate','external_id',p_external_id);
  end if;
  for ln in select * from jsonb_array_elements(p_lines) loop
    q := coalesce((ln->>'qty')::numeric, 1);
    select id into mid from public.menu_items
     where active and (lower(name) = lower(trim(ln->>'name'))
        or lower(trim(ln->>'name')) = any (select lower(a) from unnest(aliases) a))
     limit 1;
    insert into public.order_lines(order_id, item_name, qty, menu_item_id, matched)
    values (oid, trim(ln->>'name'), q, mid, mid is not null);
    if mid is null then
      unmatched := unmatched || trim(ln->>'name');
    else
      insert into public.stock_movements(stock_item_id, change, reason, order_id, note)
      select r.stock_item_id, -(r.qty * q), 'sale', oid, p_channel::text || ' ' || p_external_id
      from public.menu_recipes r where r.menu_item_id = mid;
    end if;
  end loop;
  return jsonb_build_object('status','ok','order_id',oid,'unmatched',to_jsonb(unmatched));
end $$;

alter table public.staff enable row level security;
alter table public.staff_invites enable row level security;
alter table public.stock_items enable row level security;
alter table public.menu_items enable row level security;
alter table public.menu_recipes enable row level security;
alter table public.orders enable row level security;
alter table public.order_lines enable row level security;
alter table public.stock_movements enable row level security;
alter table public.alerts enable row level security;

create policy staff_read on public.staff for select to authenticated using ((select private.is_staff()));
create policy staff_owner_update on public.staff for update to authenticated
  using ((select private.is_owner())) with check ((select private.is_owner()));
create policy staff_owner_delete on public.staff for delete to authenticated
  using ((select private.is_owner()) and user_id <> (select auth.uid()));
create policy invites_owner_all on public.staff_invites for all to authenticated
  using ((select private.is_owner())) with check ((select private.is_owner()));

create policy items_read on public.stock_items for select to authenticated using ((select private.is_staff()));
create policy items_owner_ins on public.stock_items for insert to authenticated with check ((select private.is_owner()));
create policy items_owner_upd on public.stock_items for update to authenticated using ((select private.is_owner())) with check ((select private.is_owner()));
create policy items_owner_del on public.stock_items for delete to authenticated using ((select private.is_owner()));

create policy menu_read on public.menu_items for select to authenticated using ((select private.is_staff()));
create policy menu_owner_ins on public.menu_items for insert to authenticated with check ((select private.is_owner()));
create policy menu_owner_upd on public.menu_items for update to authenticated using ((select private.is_owner())) with check ((select private.is_owner()));
create policy menu_owner_del on public.menu_items for delete to authenticated using ((select private.is_owner()));

create policy recipe_read on public.menu_recipes for select to authenticated using ((select private.is_staff()));
create policy recipe_owner_ins on public.menu_recipes for insert to authenticated with check ((select private.is_owner()));
create policy recipe_owner_upd on public.menu_recipes for update to authenticated using ((select private.is_owner())) with check ((select private.is_owner()));
create policy recipe_owner_del on public.menu_recipes for delete to authenticated using ((select private.is_owner()));

create policy orders_read on public.orders for select to authenticated using ((select private.is_staff()));
create policy orders_ins on public.orders for insert to authenticated with check ((select private.is_staff()));
create policy lines_read on public.order_lines for select to authenticated using ((select private.is_staff()));
create policy lines_ins on public.order_lines for insert to authenticated with check ((select private.is_staff()));
create policy moves_read on public.stock_movements for select to authenticated using ((select private.is_staff()));
create policy moves_ins on public.stock_movements for insert to authenticated
  with check ((select private.is_staff()) and created_by = (select auth.uid()));
create policy alerts_read on public.alerts for select to authenticated using ((select private.is_staff()));
create policy alerts_upd on public.alerts for update to authenticated using ((select private.is_staff())) with check ((select private.is_staff()));

grant select, insert, update, delete on all tables in schema public to authenticated;
grant usage, select on all sequences in schema public to authenticated;
revoke all on all tables in schema public from anon;
revoke execute on function public.record_order from public, anon;
grant execute on function public.record_order to authenticated, service_role;
