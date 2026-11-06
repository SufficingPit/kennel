// Supabase Edge Function "request-spot": the only way to send a booking request.
// 1. Checks the Cloudflare Turnstile token (the "verify you're human" check).
// 2. Calls request_spot() with the service key, which re-checks every rule and holds the spot.
// Deploy with "Verify JWT" OFF (the public page has no login). Needs the secret TURNSTILE_SECRET.
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided by Supabase automatically.

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
  return reply(await r.json());
});
