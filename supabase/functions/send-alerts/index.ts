// Sends low-stock alerts and the daily summary by email (via Resend).
// Called by the database every 5 minutes (alerts) and 8am daily (summary),
// or by the owner from the dashboard ("Send test").
import { db, json, safeEqual, settings } from "../_shared/db.ts";

async function isOwner(req: Request) {
  const auth = req.headers.get("authorization") ?? "";
  if (!auth.startsWith("Bearer ")) return false;
  const res = await fetch(`${Deno.env.get("SUPABASE_URL")}/auth/v1/user`, {
    headers: { Authorization: auth, apikey: Deno.env.get("SUPABASE_ANON_KEY")! },
  });
  if (!res.ok) return false;
  const user = await res.json();
  const rows = await db(`staff?user_id=eq.${user.id}&role=eq.owner&select=user_id`);
  return rows.length > 0;
}

async function sendEmail(cfg: any, subject: string, html: string) {
  if (!cfg.resend_api_key || !cfg.alert_emails?.length) return { sent: false, reason: "email not set up" };
  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${cfg.resend_api_key}`, "Content-Type": "application/json" },
    body: JSON.stringify({ from: cfg.alert_from, to: cfg.alert_emails, subject, html }),
  });
  return { sent: res.ok, status: res.status, detail: res.ok ? undefined : await res.text() };
}

const esc = (s: string) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]!));
const row = (s: any) =>
  `<tr><td style="padding:4px 12px 4px 0">${esc(s.name)}</td><td style="padding:4px 12px 4px 0"><b>${Number(s.on_hand)}</b> ${esc(s.unit)}${Number(s.on_hand) === 1 ? "" : "s"}</td><td style="color:${s.status === "out" ? "#b42318" : "#b54708"}">${s.status === "out" ? "OUT" : "low"}</td></tr>`;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return json({ ok: true });
  const cfg = await settings();
  const fromCron = safeEqual(req.headers.get("x-cron-secret") ?? "", cfg.cron_secret);
  if (!fromCron && !(await isOwner(req))) return json({ error: "unauthorised" }, 401);

  const { mode = "alerts" } = await req.json().catch(() => ({}));
  const levels = await db("stock_levels?active=eq.true&select=*&order=name");
  const low = levels.filter((s: any) => s.status !== "ok");

  if (mode === "summary" || mode === "test") {
    const html = `<h2>${esc(cfg.shop_name)} – stock ${mode === "test" ? "test" : "this morning"}</h2>` +
      (low.length
        ? `<p>These need reordering:</p><table>${low.map(row).join("")}</table>`
        : `<p>Everything is above its low level. 👍</p>`) +
      `<p style="color:#667085">Full stock: ${levels.map((s: any) => `${esc(s.name)} ${Number(s.on_hand)}`).join(" · ")}</p>`;
    const r = await sendEmail(cfg, `${cfg.shop_name}: ${low.length ? `${low.length} item(s) to reorder` : "stock OK"}`, html);
    return json({ mode, low: low.length, ...r });
  }

  // mode = alerts: send any alerts not yet emailed
  const pending = await db("alerts?resolved_at=is.null&sent_at=is.null&select=id,stock_item_id,kind");
  if (!pending.length) return json({ mode, pending: 0 });
  const items = levels.filter((s: any) => pending.some((p: any) => p.stock_item_id === s.id));
  const html = `<h2>Running low at ${esc(cfg.shop_name)}</h2><table>${items.map(row).join("")}</table>`;
  const r = await sendEmail(cfg, `⚠️ ${cfg.shop_name}: ${items.map((s: any) => s.name).join(", ")} running low`, html);
  if (r.sent) {
    await db(`alerts?id=in.(${pending.map((p: any) => p.id).join(",")})`, {
      method: "PATCH", body: JSON.stringify({ sent_at: new Date().toISOString() }),
    });
  }
  return json({ mode, pending: pending.length, ...r });
});
