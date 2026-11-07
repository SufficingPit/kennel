// Supabase Edge Function "request-spot": the only way to send a booking request.
// 1. Checks the Cloudflare Turnstile token (the "verify you're human" check).
// 2. Calls request_spot() with the service key, which re-checks every rule and holds the spot.
// Deploy with "Verify JWT" OFF (the public page has no login). Needs the secret TURNSTILE_SECRET.
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided by Supabase automatically.
// 3. Sends a notification to every phone that turned them on (push_subs), if the secret
//    VAPID_PRIVATE is set. A failed notification never fails the request.
import webpush from "npm:web-push@3.6.7";
const VAPID_PUB = "BArT00BpVojpgIlfimBgeOb_LqGiLpie5j8F_NeQkz5EWhFu6FNfpNqBSvArQL_DGdDw47XIwOSU_sU18q4F-cQ";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "content-type, apikey, authorization, x-client-info",
};
const reply = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS });
  if (req.method !== "POST") return reply({ ok: false, reason: "Use POST." }, 405);

  let body: { token?: string; p?: Record<string, unknown> };
  try { body = await req.json(); } catch { return reply({ ok: false, reason: "Bad request." }, 400); }
  if (!body?.p || typeof body.p !== "object") return reply({ ok: false, reason: "Bad request." }, 400);
  if (JSON.stringify(body.p).length > 8000) return reply({ ok: false, reason: "That’s too long." }, 400);

  const secret = Deno.env.get("TURNSTILE_SECRET");
  if (!secret) return reply({ ok: false, reason: "Online requests aren’t set up yet. Please call us." }, 503);
  const form = new FormData();
  form.append("secret", secret);
  form.append("response", String(body.token ?? ""));
  const ip = req.headers.get("cf-connecting-ip") ?? req.headers.get("x-forwarded-for")?.split(",")[0]?.trim();
  if (ip) form.append("remoteip", ip);
  const check = await fetch("https://challenges.cloudflare.com/turnstile/v0/siteverify", { method: "POST", body: form })
    .then((r) => r.json()).catch(() => ({ success: false }));
  if (!check.success) return reply({ ok: false, reason: "The human check didn’t go through. Please try it again.", retry: true }, 400);

  const url = Deno.env.get("SUPABASE_URL")!, key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const r = await fetch(url + "/rest/v1/rpc/request_spot", {
    method: "POST",
    headers: { apikey: key, Authorization: "Bearer " + key, "Content-Type": "application/json" },
    body: JSON.stringify({ p: body.p }),
  });
  if (!r.ok) return reply({ ok: false, reason: "Couldn’t send. Please try again." }, 502);
  const out = await r.json();
  if (out?.ok) await notify(url, key, body.p).catch(() => {});
  return reply(out);
});

const md = (d: string) => new Date(d + "T12:00:00").toLocaleDateString("en-US", { month: "short", day: "numeric" });
async function notify(url: string, key: string, p: Record<string, any>) {
  const priv = Deno.env.get("VAPID_PRIVATE");
  if (!priv) return;
  webpush.setVapidDetails("mailto:littlevillagepetlodge@outlook.com", VAPID_PUB, priv.trim());
  const subs = await fetch(url + "/rest/v1/push_subs?select=endpoint,p256dh,auth", {
    headers: { apikey: key, Authorization: "Bearer " + key },
  }).then((x) => x.ok ? x.json() : []);
  const pets = (p.pets || []) as { species: string }[];
  const n = (sp: string) => pets.filter((x) => x.species === sp).length;
  const what = [n("dog") && n("dog") + (n("dog") === 1 ? " dog" : " dogs"), n("cat") && n("cat") + (n("cat") === 1 ? " cat" : " cats"),
    n("other") && n("other") + (n("other") === 1 ? " other pet" : " other pets")].filter(Boolean).join(", ");
  const msg = JSON.stringify({
    title: "New request: " + String(p.name || "").trim(),
    body: md(String(p.start)) + " – " + md(String(p.end)) + (what ? " · " + what : ""),
    url: "./?tab=reqs", tag: "request-" + Date.now(),
  });
  await Promise.all(subs.map(async (s: { endpoint: string; p256dh: string; auth: string }) => {
    try {
      await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, msg, { TTL: 86400 });
    } catch (e: any) {
      // the phone unsubscribed or the app was removed: forget it
      if (e?.statusCode === 404 || e?.statusCode === 410) {
        await fetch(url + "/rest/v1/push_subs?endpoint=eq." + encodeURIComponent(s.endpoint), {
          method: "DELETE", headers: { apikey: key, Authorization: "Bearer " + key },
        });
      }
    }
  }));
}
