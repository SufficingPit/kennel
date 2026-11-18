// Supabase Edge Function "request-spot": the only way to send a booking request.
// 1. Checks the Cloudflare Turnstile token (the "verify you're human" check).
// 2. Calls request_spot() with the service key, which re-checks every rule and holds the spot.
// Deploy with "Verify JWT" OFF (the public page has no login). Needs the secret TURNSTILE_SECRET.
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided by Supabase automatically.
//    Or, with kind "form", calls guest_form_submit() for a new guest form filled out online,
//    and returns one-time upload links for any vet records sent with it (uploadLinks below).
//    Or, with kind "records", adds vet records to a stay request from its page (request_add_docs)
//    and returns upload links for them.
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

  let body: { token?: string; kind?: string; p?: Record<string, unknown> };
  try { body = await req.json(); } catch { return reply({ ok: false, reason: "Bad request." }, 400); }
  if (!body?.p || typeof body.p !== "object") return reply({ ok: false, reason: "Bad request." }, 400);
  const isForm = body.kind === "form";
  if (JSON.stringify(body.p).length > (isForm ? 60000 : 8000)) return reply({ ok: false, reason: "That’s too long." }, 400);

  const secret = Deno.env.get("TURNSTILE_SECRET");
  if (!secret) return reply({ ok: false, reason: "Online requests aren’t set up yet. Please call us." }, 503);
  const form = new FormData();
  form.append("secret", secret.trim());
  form.append("response", String(body.token ?? ""));
  const ip = req.headers.get("cf-connecting-ip") ?? req.headers.get("x-forwarded-for")?.split(",")[0]?.trim();
  if (ip) form.append("remoteip", ip);
  const check = await fetch("https://challenges.cloudflare.com/turnstile/v0/siteverify", { method: "POST", body: form })
    .then((r) => r.json()).catch(() => ({ success: false }));
  if (!check.success) console.log("turnstile failed", JSON.stringify(check["error-codes"]), check.hostname || "");
  if (!check.success) return reply({ ok: false, reason: "The human check didn’t go through. Please try it again.", retry: true }, 400);

  const url = Deno.env.get("SUPABASE_URL")!, key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  if (body.kind === "records") return reply(await requestRecords(url, key, body.p as Record<string, any>));
  const r = await fetch(url + "/rest/v1/rpc/" + (isForm ? "guest_form_submit" : "request_spot"), {
    method: "POST",
    headers: { apikey: key, Authorization: "Bearer " + key, "Content-Type": "application/json" },
    body: JSON.stringify({ p: body.p }),
  });
  if (!r.ok) return reply({ ok: false, reason: "Couldn’t send. Please try again." }, 502);
  const out = await r.json();
  if (out?.ok) await notify(url, key, isForm ? formMsg(body.p) : requestMsg(body.p)).catch(() => {});
  // vet records sent with a guest form: one-time upload links into the private "docs" bucket
  if (out?.ok && isForm) out.uploads = await uploadLinks(url, key, body.p).catch(() => []);
  // "Change it" on a request: records sent on the one they changed follow to the new one (request_carry_docs)
  const from = String((body.p as Record<string, unknown>).from || "");
  if (out?.ok && !isForm && out.token && /^[0-9a-f-]{36}$/i.test(from)) {
    await fetch(url + "/rest/v1/rpc/request_carry_docs", {
      method: "POST",
      headers: { apikey: key, Authorization: "Bearer " + key, "Content-Type": "application/json" },
      body: JSON.stringify({ p_from: from, p_to: out.token }),
    }).catch(() => {});
  }
  return reply(out);
});

// A guest form can carry up to 3 photos or PDFs per pet (data.pets[i].docs = [{name, kind, path}]).
// Each path must be forms/<the form's key>/<pet>-<n>.jpg|pdf; files can't replace anything already there.
async function uploadLinks(url: string, key: string, p: Record<string, any>) {
  const fk = String(p.key || "").toLowerCase();
  if (!/^[0-9a-f-]{36}$/.test(fk)) return [];
  const want: string[] = [];
  ((p.data?.pets || []) as any[]).slice(0, 8).forEach((pet, i) =>
    ((pet?.docs || []) as any[]).slice(0, 3).forEach((d, j) => {
      const path = String(d?.path || "");
      if (path === `forms/${fk}/${i}-${j}.${d?.kind === "pdf" ? "pdf" : "jpg"}`) want.push(path);
    }));
  return (await Promise.all(want.map((path) => signUpload(url, key, path)))).filter(Boolean);
}
// a one-time link to upload one new file to the private "docs" bucket (it can't replace a file)
async function signUpload(url: string, key: string, path: string) {
  const r = await fetch(`${url}/storage/v1/object/upload/sign/docs/${path}`, {
    method: "POST", headers: { apikey: key, Authorization: "Bearer " + key, "Content-Type": "application/json" }, body: "{}",
  });
  if (!r.ok) return null;
  const j = await r.json();
  return j?.url ? { path, url: url + "/storage/v1" + j.url } : null;
}
// Vet records sent from a stay request's page: p = {req: the request's token, docs: [{ix, pet, name, kind}]}.
// The database checks the request is still open and picks each file's path.
async function requestRecords(url: string, key: string, p: Record<string, any>) {
  const tok = String(p.req || "");
  if (!/^[0-9a-f-]{36}$/i.test(tok) || !Array.isArray(p.docs)) return { ok: false, reason: "Bad request." };
  const r = await fetch(url + "/rest/v1/rpc/request_add_docs", {
    method: "POST",
    headers: { apikey: key, Authorization: "Bearer " + key, "Content-Type": "application/json" },
    body: JSON.stringify({ p_token: tok, p_docs: p.docs.slice(0, 9) }),
  });
  if (!r.ok) return { ok: false, reason: "Couldn’t send. Please try again." };
  const out = await r.json();
  if (!out?.ok) return out;
  await notify(url, key, { title: "Vet records: " + String(out.name || "").trim(), body: String(out.pets || ""), tag: "records-" }).catch(() => {});
  const docs = (out.docs || []) as { pet: number; ix: unknown; name: string; kind: string; path: string }[];
  const uploads = (await Promise.all(docs.map((d) => signUpload(url, key, d.path)))).filter(Boolean);
  return { ok: true, docs: docs.map((d) => ({ pet: d.pet, ix: d.ix, name: d.name, kind: d.kind, path: d.path })), uploads };
}

const md = (d: string) => new Date(d + "T12:00:00").toLocaleDateString("en-US", { month: "short", day: "numeric" });
function requestMsg(p: Record<string, any>) {
  const pets = (p.pets || []) as { species: string }[];
  const n = (sp: string) => pets.filter((x) => x.species === sp).length;
  const what = [n("dog") && n("dog") + (n("dog") === 1 ? " dog" : " dogs"), n("cat") && n("cat") + (n("cat") === 1 ? " cat" : " cats"),
    n("other") && n("other") + (n("other") === 1 ? " other pet" : " other pets")].filter(Boolean).join(", ");
  return { title: "New request: " + String(p.name || "").trim(), body: md(String(p.start)) + " – " + md(String(p.end)) + (what ? " · " + what : ""), tag: "request-" };
}
function formMsg(p: Record<string, any>) {
  const o = p.data?.owner || {}, pets = (p.data?.pets || []) as { name: string }[];
  const who = (String(o.first || "") + " " + String(o.last || "")).trim(), names = pets.map((x) => String(x.name || "").trim()).filter(Boolean).join(", ");
  const mode = p.data?.mode;   // new | pets (a family she has, adding pets) | update
  const title = mode === "pets" ? "New pet page: " + names : mode === "update" ? "Updated guest form: " + who : "New guest form: " + who;
  return { title, body: mode === "pets" ? "From " + who : names, tag: "form-" };
}
async function notify(url: string, key: string, m: { title: string; body: string; tag: string }) {
  const priv = Deno.env.get("VAPID_PRIVATE");
  if (!priv) return;
  webpush.setVapidDetails("mailto:littlevillagepetlodge@outlook.com", VAPID_PUB, priv.trim());
  const subs = await fetch(url + "/rest/v1/push_subs?select=endpoint,p256dh,auth", {
    headers: { apikey: key, Authorization: "Bearer " + key },
  }).then((x) => x.ok ? x.json() : []);
  const msg = JSON.stringify({ title: m.title, body: m.body, url: "./?tab=reqs", tag: m.tag + Date.now() });
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
