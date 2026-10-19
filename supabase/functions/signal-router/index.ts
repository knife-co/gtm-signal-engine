// P3 Signal Router: runs on Supabase every morning, no laptop needed.
//  1. Checks every signal source ran recently (job boards, tech scan)
//  2. route_accounts(): dedupe -> decay -> priority (ICP fit x signal) -> play, saved with history in router_decisions
//  3. Writes Salesforce: Signal__c (upsert by Signal_Key__c), Account priority/tier/play, a Task for each NEW Tier A account
//  4. Posts a Slack digest when an account newly enters Tier A/B, or a source is stale
// Modes (POST body): {"mode":"run"} default | {"mode":"check"} test logins, no writes | {"mode":"setup"} create Salesforce fields
// Secrets (Supabase dashboard -> Edge Functions -> Secrets): SF_CLIENT_ID, SF_USERNAME, SF_PRIVATE_KEY, SF_LOGIN_URL, SLACK_WEBHOOK_URL
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const env = (k: string) => (Deno.env.get(k) ?? "").trim();
const API = "v62.0";

// ---------- Salesforce login (JWT bearer: we sign a short note with the private key; Salesforce trusts the matching certificate) ----------
const b64url = (b: Uint8Array | string) => {
  const bytes = typeof b === "string" ? new TextEncoder().encode(b) : b;
  let s = ""; for (const x of bytes) s += String.fromCharCode(x);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
};
function derLen(n: number): number[] {
  if (n < 128) return [n];
  const out: number[] = []; while (n > 0) { out.unshift(n & 0xff); n >>= 8; }
  return [0x80 | out.length, ...out];
}
function der(tag: number, body: Uint8Array): Uint8Array {
  const len = derLen(body.length); const out = new Uint8Array(1 + len.length + body.length);
  out[0] = tag; out.set(len, 1); out.set(body, 1 + len.length); return out;
}
const cat = (...a: Uint8Array[]) => { const o = new Uint8Array(a.reduce((s, x) => s + x.length, 0)); let i = 0; for (const x of a) { o.set(x, i); i += x.length; } return o; };
// Accepts "BEGIN PRIVATE KEY" (PKCS#8) or "BEGIN RSA PRIVATE KEY" (PKCS#1), even if pasted on one line.
function keyToPkcs8(pem: string): Uint8Array {
  const isPkcs1 = /BEGIN RSA PRIVATE KEY/.test(pem);
  const body = pem.replace(/-----BEGIN [A-Z ]+-----/, "").replace(/-----END [A-Z ]+-----/, "").replace(/\\n/g, "").replace(/\s+/g, "");
  const raw = Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
  if (!isPkcs1) return raw;
  const version = new Uint8Array([0x02, 0x01, 0x00]);
  const algId = new Uint8Array([0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00]);
  return der(0x30, cat(version, algId, der(0x04, raw)));
}
let sfSession: { token: string; instance: string } | null = null;
async function sfLogin() {
  if (sfSession) return sfSession;
  const clientId = env("SF_CLIENT_ID"), user = env("SF_USERNAME"), pem = env("SF_PRIVATE_KEY");
  const login = (env("SF_LOGIN_URL") || "https://login.salesforce.com").replace(/\/$/, "");
  if (!clientId || !user || !pem) throw new Error("Salesforce secrets missing (SF_CLIENT_ID, SF_USERNAME, SF_PRIVATE_KEY)");
  const key = await crypto.subtle.importKey("pkcs8", keyToPkcs8(pem), { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
  const head = b64url(JSON.stringify({ alg: "RS256" }));
  const claims = b64url(JSON.stringify({ iss: clientId, sub: user, aud: login, exp: Math.floor(Date.now() / 1000) + 180 }));
  const sig = new Uint8Array(await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(`${head}.${claims}`)));
  const r = await fetch(`${login}/services/oauth2/token`, {
    method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion: `${head}.${claims}.${b64url(sig)}` }),
  });
  const j = await r.json();
  if (!r.ok) throw new Error(`Salesforce login failed: ${j.error ?? r.status} ${j.error_description ?? ""}`);
  sfSession = { token: j.access_token, instance: j.instance_url };
  return sfSession;
}
async function sf(method: string, path: string, body?: unknown) {
  const s = await sfLogin();
  const r = await fetch(`${s.instance}/services/data/${API}/${path}`, {
    method, headers: { Authorization: `Bearer ${s.token}`, "Content-Type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await r.text();
  let data: any = null; try { data = text ? JSON.parse(text) : null; } catch { data = text; }
  return { status: r.status, data };
}
// composite/sobjects takes max 200 records per call: send in chunks, return results in the original order
async function sfBatch(method: string, path: string, records: any[]) {
  const out: any[] = [];
  for (let i = 0; i < records.length; i += 200) {
    const chunk = records.slice(i, i + 200);
    const r = await sf(method, path, { allOrNone: false, records: chunk });
    if (Array.isArray(r.data)) out.push(...r.data);
    else out.push(...chunk.map(() => ({ success: false, errors: [{ message: `HTTP ${r.status}`, detail: r.data }] })));
  }
  return out;
}

// ---------- Salesforce fields this router needs (setup mode; safe to run twice) ----------
const pick = (vals: [string, string][]) => ({ restricted: true, valueSetDefinition: { sorted: false, value: vals.map(([k, v]) => ({ fullName: k, label: v, default: false })) } });
const NEW_FIELDS: [string, any][] = [
  ["Account.Priority__c", { label: "Priority", type: "Number", precision: 3, scale: 0, description: "0-100 from the P3 Signal Router: ICP fit x signal strength" }],
  ["Account.Priority_Tier__c", { label: "Priority Tier", type: "Picklist", valueSet: pick([["A", "A - act today"], ["B", "B - this week"], ["C", "C - nurture"], ["none", "None"]]) }],
  ["Account.Play__c", { label: "Play", type: "Text", length: 100 }],
  ["Account.Play_Opener__c", { label: "Play: who, channel, opener", type: "LongTextArea", length: 2000, visibleLines: 4 }],
  ["Account.Routed_At__c", { label: "Routed At", type: "DateTime" }],
];
async function setup() {
  const log: any[] = [];
  const acc = await sf("GET", "sobjects/Account/describe");
  const have = new Set((acc.data?.fields ?? []).map((f: any) => `Account.${f.name}`));
  const toMake = NEW_FIELDS.filter(([n]) => !have.has(n));
  if (toMake.length) {
    const r = await sf("POST", "tooling/composite", { allOrNone: false, compositeRequest: toMake.map(([n, md], i) => ({
      method: "POST", url: `/services/data/${API}/tooling/sobjects/CustomField`, referenceId: `f${i}`, body: { FullName: n, Metadata: md } })) });
    log.push({ created: toMake.map(([n]) => n), result: (r.data?.compositeResponse ?? []).map((x: any) => x.httpStatusCode) });
  } else log.push({ created: [], note: "Account fields already exist" });
  // add 'duplicate' and 'noise' to Signal__c.Band__c
  // find the field: object id first, then the field by name on that object, then read its full definition
  const obj = await sf("GET", `tooling/query?q=${encodeURIComponent("SELECT Id FROM CustomObject WHERE DeveloperName = 'Signal'")}`);
  const objId = obj.data?.records?.[0]?.Id;
  const fq = objId ? await sf("GET", `tooling/query?q=${encodeURIComponent(`SELECT Id FROM CustomField WHERE DeveloperName = 'Band' AND TableEnumOrId = '${objId}'`)}`) : null;
  const fieldId = fq?.data?.records?.[0]?.Id;
  const fld = fieldId ? (await sf("GET", `tooling/sobjects/CustomField/${fieldId}`)).data : null;
  if (!fld) log.push({ band_field: "not found", object: obj.data, field: fq?.data });
  if (fld) {
    const md = fld.Metadata; const vals = md.valueSet.valueSetDefinition.value as any[];
    const names = new Set(vals.map((v) => v.fullName));
    let changed = false;
    for (const [k, l] of [["duplicate", "Duplicate"], ["noise", "Noise"]]) if (!names.has(k)) { vals.push({ fullName: k, label: l, default: false }); changed = true; }
    if (changed) { const u = await sf("PATCH", `tooling/sobjects/CustomField/${fld.Id}`,
      { Metadata: JSON.parse(JSON.stringify(md, (_k, v) => (v === null ? undefined : v))) }); // Salesforce rejects the nulls it sends us
      log.push({ band_values_added: u.status, detail: u.status >= 300 ? u.data : undefined }); }
    else log.push({ band_values: "already there" });
  }
  // field-level security for System Administrator (new fields are hidden from everyone until this is set)
  const ps = await sf("GET", `query?q=${encodeURIComponent("SELECT Id FROM PermissionSet WHERE IsOwnedByProfile = true AND Profile.Name = 'System Administrator'")}`);
  const psId = ps.data?.records?.[0]?.Id;
  if (psId && toMake.length) {
    const fls = await sfBatch("POST", "composite/sobjects", toMake.map(([n]) => ({ attributes: { type: "FieldPermissions" }, ParentId: psId,
      SobjectType: n.split(".")[0], Field: n, PermissionsRead: true, PermissionsEdit: true })));
    log.push({ field_security: fls.map((x) => x.success) });
  }
  return log;
}

// ---------- Slack ----------
async function slack(payload: any) {
  const url = env("SLACK_WEBHOOK_URL");
  if (!url) return "skipped: SLACK_WEBHOOK_URL not set";
  const r = await fetch(url, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(payload) });
  return r.ok ? "sent" : `failed: HTTP ${r.status} ${(await r.text()).slice(0, 100)}`;
}

// ---------- Source health: did every collector run recently? ----------
async function sourceHealth() {
  const hours = (t: string | null) => (t ? Math.round((Date.now() - new Date(t).getTime()) / 36e5) : null);
  const { data: jobs } = await db.from("collector_runs").select("finished_at").eq("mode", "collect").not("finished_at", "is", null).order("id", { ascending: false }).limit(1);
  const { data: tech } = await db.from("tech_scan_runs").select("finished_at").not("finished_at", "is", null).order("id", { ascending: false }).limit(1);
  const s = [
    { source: "Job boards (Greenhouse/Lever/Ashby)", hours_ago: hours(jobs?.[0]?.finished_at ?? null), max_hours: 26 },
    { source: "Tech-stack scan", hours_ago: hours(tech?.[0]?.finished_at ?? null), max_hours: 26 },
  ].map((x) => ({ ...x, ok: x.hours_ago !== null && x.hours_ago <= x.max_hours }));
  const summary = s.map((x) => `${x.ok ? "✅" : "⚠️"} ${x.source} ${x.hours_ago === null ? "never" : x.hours_ago + "h ago"}`).join(" · ") + " · ⏳ Funding & new-exec: not built yet";
  return { sources: s, stale: s.filter((x) => !x.ok).map((x) => x.source), summary };
}

Deno.serve(async (req) => {
  let body: any = {}; try { body = await req.json(); } catch { body = {}; }
  const mode = body.mode ?? "run";
  try {
    if (mode === "check") {
      const out: any = { secrets: Object.fromEntries(["SF_CLIENT_ID", "SF_USERNAME", "SF_PRIVATE_KEY", "SF_LOGIN_URL", "SLACK_WEBHOOK_URL"].map((k) => [k, env(k) ? "set" : "MISSING"])) };
      try { const s = await sfLogin(); const who = await sf("GET", "query?q=" + encodeURIComponent("SELECT COUNT() FROM Account")); out.salesforce = { login: "ok", instance: s.instance, accounts: who.data?.totalSize }; }
      catch (e) { out.salesforce = { login: "failed", error: String((e as Error).message) }; }
      if (body.slack_test) out.slack = await slack({ text: "✅ Signal Router is connected to this channel." });
      out.sources = await sourceHealth();
      return Response.json(out);
    }
    if (mode === "setup") return Response.json({ setup: await setup() });

    // ----- daily run -----
    const health = await sourceHealth();
    const { data: run, error: re } = await db.from("router_runs").insert({ trigger: body.trigger ?? "manual", source_health: health }).select("id").single();
    if (re) throw re;
    const runId = run.id;
    const errors: any[] = [];
    const { data: routed, error: rerr } = await db.rpc("route_accounts", { p_run_id: runId });
    if (rerr) throw rerr;

    let sfResult: any = { skipped: true };
    try {
      const { data: p, error: pe } = await db.rpc("router_sf_payload", { p_run_id: runId, p_max: 500 });
      if (pe) throw pe;
      const sigRes = p.signals.length ? await sfBatch("PATCH", "composite/sobjects/Signal__c/Signal_Key__c", p.signals) : [];
      const accRes = p.accounts.length ? await sfBatch("PATCH", "composite/sobjects", p.accounts) : [];
      const taskRes = p.tasks.length ? await sfBatch("POST", "composite/sobjects", p.tasks) : [];
      const { data: rec, error: rce } = await db.rpc("router_sf_record", { p_run_id: runId, p_payload: p, p_signal_results: sigRes, p_account_results: accRes, p_task_results: taskRes });
      if (rce) throw rce;
      sfResult = rec;
    } catch (e) { errors.push({ step: "salesforce", error: String((e as Error).message ?? e) }); sfResult = { failed: String((e as Error).message ?? e) }; }

    let slackStatus = "no new alerts";
    const { data: digest } = await db.rpc("router_slack_digest", { p_run_id: runId });
    if ((digest?.alerts ?? 0) > 0 || health.stale.length || body.force_slack) {
      const blocks = [...digest.blocks];
      if (sfResult?.failed) blocks.push({ type: "context", elements: [{ type: "mrkdwn", text: `⚠️ Salesforce step failed: ${String(sfResult.failed).slice(0, 200)}` }] });
      slackStatus = await slack({ text: digest.text, blocks });
    }

    await db.from("router_runs").update({ finished_at: new Date().toISOString(), sf_result: sfResult, slack_status: slackStatus, errors }).eq("id", runId);
    return Response.json({ run_id: runId, routed: { a: routed?.tier_a, b: routed?.tier_b, c: routed?.tier_c, alerts: routed?.alerts, accounts: routed?.accounts_routed },
      salesforce: sfResult, slack: slackStatus, sources: health.summary, errors });
  } catch (e) {
    return Response.json({ error: String((e as any)?.message ?? e) }, { status: 500 });
  }
});
