# Amalfi Desserts – stock tracker

Tracks stock for Amalfi Desserts, takes it off automatically when orders come in, and emails when something is running low.

## How it works

```
Delivery orders ──► orders-webhook ─┐
CSV upload / "Record sale" ─────────┼──► record_order() ──► stock_movements ──► low-stock trigger ──► alerts
Staff add / use / count stock ──────┘                            │                                   │
                                                          stock_levels view                    send-alerts (every 5 min
                                                                 │                              + 8am summary) ──► email
                                                           Dashboard (index.html)
```

- **Database (Supabase / Postgres)**: `supabase/migrations/`
  - `stock_items`: what's counted (e.g. Biscoff Cheesecake, counted in slices, bought as whole cheesecakes of 8).
  - `menu_items` + `menu_recipes`: what customers order and how much stock each uses (a Dessert Sharer = 1 Biscoff slice + 2 brownies…). `aliases` match other spellings from the delivery apps.
  - `stock_movements`: every change (opening, purchase, sale, used, waste, count correction). Current stock is the sum of these, so it can always be checked.
  - `record_order()`: saves an order and takes stock off in one step. The same order number sent twice is ignored.
  - A trigger opens an `alerts` row when an item reaches its low level, and closes it when restocked.
  - Row-level security: only invited staff can see anything. Only the owner can change products, recipes, staff and settings.
- **Edge functions**: `supabase/functions/`
  - `orders-webhook`: receives orders from a delivery integration (e.g. Deliverect) or any system.
  - `send-alerts`: emails low-stock alerts (via Resend) and the morning summary. Run by `pg_cron`.
- **Dashboard**: `index.html`, a single static page (no build step).

## Webhook format

`POST https://byoufnhfuicamwqjdrkb.supabase.co/functions/v1/orders-webhook`
Header `x-webhook-secret: <from Setup page>`

```json
{ "channel": "deliveroo", "order_id": "ABC123", "placed_at": "2026-11-10T19:00:00Z",
  "items": [ { "name": "Biscoff Cheesecake Slice", "qty": 2 } ] }
```

An array of orders also works. Items whose name doesn't match a menu item or alias are saved but flagged "not matched".

## Deploy the dashboard

Import this repo on [vercel.com](https://vercel.com/new) and leave every setting at its default. It's a static page. Then in Supabase → Authentication → URL Configuration, set **Site URL** to the Vercel address so sign-up emails link back to it.

The first account created becomes the **owner**. Other staff are invited from the Setup page.
