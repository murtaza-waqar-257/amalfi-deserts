// Receives delivery orders and takes the stock off.
// POST https://<project>.supabase.co/functions/v1/orders-webhook
// Header: x-webhook-secret: <secret from Settings>   (or ?secret=... in the URL)
// Body (simple format):
// { "channel": "deliveroo", "order_id": "ABC123", "placed_at": "2026-11-10T19:00:00Z",
//   "items": [ { "name": "Biscoff Cheesecake Slice", "qty": 2 } ] }
// Also accepts "quantity" instead of "qty" and "channelOrderId"/"id" instead of "order_id".
import { db, json, safeEqual, settings } from "../_shared/db.ts";

const CHANNELS = ["deliveroo", "ubereats", "justeat", "in_store", "other"];

function normChannel(v: unknown): string {
  const s = String(v ?? "").toLowerCase().replace(/[\s_-]/g, "");
  if (s.includes("deliveroo")) return "deliveroo";
  if (s.includes("uber")) return "ubereats";
  if (s.includes("justeat")) return "justeat";
  if (s.includes("store") || s.includes("shop") || s.includes("till")) return "in_store";
  return CHANNELS.includes(s) ? s : "other";
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return json({ ok: true });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  const cfg = await settings();
  const given = req.headers.get("x-webhook-secret") ?? new URL(req.url).searchParams.get("secret") ?? "";
  if (!safeEqual(given, cfg.webhook_secret)) return json({ error: "unauthorised" }, 401);

  let body: any;
  try { body = await req.json(); } catch { return json({ error: "body must be JSON" }, 400); }

  const orders = Array.isArray(body) ? body : [body];
  const results = [];
  for (const o of orders) {
    const externalId = String(o.order_id ?? o.channelOrderId ?? o.id ?? "").trim();
    const items = (o.items ?? []).map((i: any) => ({
      name: String(i.name ?? i.title ?? "").trim(),
      qty: Number(i.qty ?? i.quantity ?? 1),
    })).filter((i: any) => i.name && i.qty > 0);
    if (!externalId || !items.length) {
      results.push({ status: "rejected", reason: "needs order_id and at least one item" });
      continue;
    }
    const r = await db("rpc/record_order", {
      method: "POST",
      body: JSON.stringify({
        p_channel: normChannel(o.channel ?? o.channelName),
        p_external_id: externalId,
        p_lines: items,
        p_placed_at: o.placed_at ?? o.createdAt ?? new Date().toISOString(),
        p_raw: o,
      }),
    });
    results.push(r);
  }
  return json(Array.isArray(body) ? results : results[0]);
});
