// P3 tech-stack detector: works out which GTM tools a company uses from public clues only.
//  1. Its homepage HTML (script tags, inline snippets), response headers, and its public Google Tag Manager container
//  2. Its public DNS records: MX (who handles email), TXT (SPF senders + domain verifications), www CNAME (hosting)
// Matches both against the tech_signatures table, then hands results to ingest_tech_scan,
// which keeps the stack up to date and creates tool_added signals for NEW tools.
// Polite by design: one homepage request per company, honours robots.txt, identifies itself,
// and stops (no retry, no workaround) on 403 / 429 / 503 or a bot challenge.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const UA_TOKEN = "gtm-signals-collector";
const UA = `${UA_TOKEN}/1.0 (+https://github.com/knife-co; homepage tech scan)`;
const CONCURRENCY = 6;
const TIMEOUT_MS = 10000;
const MAX_BYTES = 700_000; // enough for the <head> and script tags of almost every homepage
const DEADLINE_MS = 100000; // stop starting new companies after 100 seconds
// Bump this whenever detection LOGIC changes. Scans are only compared with scans from the same version,
// so a smarter detector never creates fake "tool added" signals.
// v1: html + dns + headers + gtm containers. v2: ignores GTM's built-in vendor lookup list.
const DETECTOR_VERSION = 2;

type Sig = { tool: string; category: string; method: string; pattern: string; re: RegExp };
type Det = { tool: string; category: string; method: string; evidence: string };

async function timedFetch(url: string, init: RequestInit = {}) {
  const ctrl = new AbortController();
  // The timer is NOT cleared when headers arrive, so it also caps the time spent reading the body.
  setTimeout(() => ctrl.abort(), TIMEOUT_MS);
  return await fetch(url, { ...init, signal: ctrl.signal, redirect: "follow" });
}

async function readCapped(r: Response): Promise<string> {
  if (!r.body) return "";
  const reader = r.body.getReader();
  const chunks: Uint8Array[] = []; let n = 0;
  while (n < MAX_BYTES) {
    const { done, value } = await reader.read();
    if (done) break;
    chunks.push(value); n += value.length;
  }
  try { await reader.cancel(); } catch { /* ignore */ }
  const buf = new Uint8Array(Math.min(n, MAX_BYTES)); let o = 0;
  for (const c of chunks) { const s = c.subarray(0, Math.max(0, buf.length - o)); buf.set(s, o); o += s.length; if (o >= buf.length) break; }
  return new TextDecoder("utf-8", { fatal: false }).decode(buf);
}

// robots.txt: is the homepage "/" disallowed for us (our own token first, then "*")?
async function robotsAllowsHome(origin: string): Promise<boolean> {
  try {
    const r = await timedFetch(`${origin}/robots.txt`, { headers: { "User-Agent": UA } });
    if (r.status !== 200) return true; // no robots file = allowed
    const text = (await readCapped(r)).slice(0, 200_000);
    const groups: { agents: string[]; rules: { allow: boolean; path: string }[] }[] = [];
    let cur: (typeof groups)[number] | null = null; let lastWasAgent = false;
    for (const raw of text.split(/\r?\n/)) {
      const line = raw.replace(/#.*/, "").trim(); if (!line) continue;
      const m = line.match(/^([A-Za-z-]+)\s*:\s*(.*)$/); if (!m) continue;
      const key = m[1].toLowerCase(), val = m[2].trim();
      if (key === "user-agent") {
        if (!cur || !lastWasAgent) { cur = { agents: [], rules: [] }; groups.push(cur); }
        cur.agents.push(val.toLowerCase()); lastWasAgent = true;
      } else if ((key === "allow" || key === "disallow") && cur) {
        cur.rules.push({ allow: key === "allow", path: val }); lastWasAgent = false;
      } else lastWasAgent = false;
    }
    const mine = groups.filter(g => g.agents.some(a => a !== "*" && UA_TOKEN.startsWith(a)));
    const applicable = mine.length ? mine : groups.filter(g => g.agents.includes("*"));
    const rules = applicable.flatMap(g => g.rules).filter(r => r.path !== "");
    // longest matching rule wins (standard robots behaviour) for path "/"
    let best: { allow: boolean; len: number } | null = null;
    for (const r of rules) {
      const p = r.path;
      const matches = p === "/" || p === "/*" || p === "/$" || p === "*";
      if (matches && (!best || p.length > best.len || (p.length === best.len && r.allow))) best = { allow: r.allow, len: p.length };
    }
    return best ? best.allow : true;
  } catch { return true; } // unreachable robots file is treated as "no rules"
}

async function doh(name: string, type: string): Promise<string[] | null> {
  const urls = [
    `https://dns.google/resolve?name=${encodeURIComponent(name)}&type=${type}`,
    `https://cloudflare-dns.com/dns-query?name=${encodeURIComponent(name)}&type=${type}`,
  ];
  for (const u of urls) {
    try {
      const r = await timedFetch(u, { headers: { "Accept": "application/dns-json" } });
      if (r.status !== 200) continue;
      const j = await r.json();
      if (j.Status !== 0 && j.Status !== 3) continue; // 0 = ok, 3 = no such name
      const want = ({ MX: 15, TXT: 16, CNAME: 5 } as Record<string, number>)[type];
      return (j.Answer ?? []).filter((a: any) => a.type === want).map((a: any) => String(a.data));
    } catch { /* try next resolver */ }
  }
  return null;
}

const hostOf = (u: string) => { try { return new URL(u).hostname.toLowerCase(); } catch { return ""; } };
const bare = (h: string) => h.replace(/^www\./, "");
const clip = (s: string, n = 140) => s.replace(/\s+/g, " ").slice(0, n);

function match(sigs: Sig[], method: string, texts: string[], out: Det[], seen: Set<string>) {
  for (const s of sigs) {
    if (s.method !== method) continue;
    for (const t of texts) {
      const m = t.match(s.re);
      if (m) {
        const key = `${s.tool}|${method}`;
        if (!seen.has(key)) {
          seen.add(key);
          const i = m.index ?? 0;
          out.push({ tool: s.tool, category: s.category, method, evidence: clip(t.slice(Math.max(0, i - 60), i + m[0].length + 60), 200) });
        }
        break;
      }
    }
  }
}

// Big text (HTML, GTM container): ONE combined regex pass instead of one pass per signature.
// Edge Functions get ~2s of CPU per request, so 75 separate scans of a large page is too expensive.
// Each hit is then checked against the individual signatures to find which tool it belongs to.
type Combined = { re: RegExp; sigs: Sig[] };
function combine(sigs: Sig[]): Combined {
  return { re: new RegExp(sigs.map(s => `(?:${s.pattern})`).join("|"), "gi"), sigs };
}
// Newer GTM containers ship Google's own lookup list of analytics vendors, e.g. "bat.bing.com":"bing".
// A hit that is a KEY in that list (followed by ":"vendorname") is not a tag the company installed: skip it.
const LOOKUP_ENTRY = /^[^"'\s,]{0,80}?\\*"\s*:\s*\\*"[a-z0-9_ .-]{2,30}\\*"/i;
function matchBig(c: Combined, method: string, text: string, out: Det[], seen: Set<string>) {
  let hits = 0;
  for (const m of text.matchAll(c.re)) {
    if (++hits > 2000) break; // safety cap
    const i0 = (m.index ?? 0) + m[0].length;
    if (method === "gtm_container" && LOOKUP_ENTRY.test(text.slice(i0, i0 + 120))) continue;
    for (const s of c.sigs) {
      const key = `${s.tool}|${method}`;
      if (seen.has(key) || !s.re.test(m[0])) continue;
      seen.add(key);
      const i = m.index ?? 0;
      out.push({ tool: s.tool, category: s.category, method, evidence: clip(text.slice(Math.max(0, i - 30), i + m[0].length + 30)) });
    }
  }
}

async function scan(domain: string, sigs: Sig[], htmlC: Combined, gtmC: Combined) {
  const d = bare(domain.toLowerCase().trim());
  const det: Det[] = []; const seen = new Set<string>();
  let html_status = "error", http_status: number | null = null, final_url: string | null = null;
  let html_bytes: number | null = null, error: string | null = null, redirected_off = false;
  const gtm_containers: string[] = [];

  // ---- DNS (public records, asked through public resolvers) ----
  const [mx, txt, cname] = await Promise.all([doh(d, "MX"), doh(d, "TXT"), doh(`www.${d}`, "CNAME")]);
  const dns_status = mx === null && txt === null ? "error" : "ok";
  match(sigs, "dns_mx", mx ?? [], det, seen);
  match(sigs, "dns_txt", txt ?? [], det, seen);
  match(sigs, "dns_cname", cname ?? [], det, seen);

  // ---- Homepage ----
  let origin = `https://${d}`;
  try {
    if (!(await robotsAllowsHome(origin))) {
      html_status = "robots_disallowed";
    } else {
      let r: Response;
      try { r = await timedFetch(`${origin}/`, { headers: { "User-Agent": UA, "Accept": "text/html,application/xhtml+xml" } }); }
      catch (_e) {
        // bare domain unreachable: try www once (many sites only answer there)
        origin = `https://www.${d}`;
        r = await timedFetch(`${origin}/`, { headers: { "User-Agent": UA, "Accept": "text/html,application/xhtml+xml" } });
      }
      http_status = r.status; final_url = r.url || `${origin}/`;
      const fh = hostOf(final_url);
      redirected_off = !!fh && !(fh === d || fh.endsWith(`.${d}`));
      const headerText = [...r.headers.entries()].map(([k, v]) => `${k}: ${v}`);
      const challenged = r.headers.get("cf-mitigated") === "challenge";
      if ([401, 403, 429, 503].includes(r.status) || challenged) {
        html_status = "blocked"; try { await r.body?.cancel(); } catch { /* ignore */ }
      } else if (r.status >= 400) {
        html_status = "error"; error = `HTTP ${r.status}`; try { await r.body?.cancel(); } catch { /* ignore */ }
      } else if (!/html/i.test(r.headers.get("content-type") ?? "html")) {
        html_status = "not_html"; try { await r.body?.cancel(); } catch { /* ignore */ }
      } else {
        const html = await readCapped(r);
        html_bytes = html.length;
        if (/<title>\s*just a moment\.\.\.\s*<\/title>|challenge-platform|cf-chl-/i.test(html) && html.length < 60000) {
          html_status = "blocked"; // bot challenge page: do not parse, do not retry
        } else {
          html_status = "ok";
          matchBig(htmlC, "html", html, det, seen);
          match(sigs, "header", headerText, det, seen);
          // Tools loaded through Google Tag Manager are not in the raw HTML. The container file is public:
          // read it (max 2 per site) and look for the same script signatures inside it.
          const ids = [...new Set([...html.matchAll(/GTM-[A-Z0-9]{4,10}/g)].map(m => m[0]))].slice(0, 2);
          for (const id of ids) {
            try {
              const g = await timedFetch(`https://www.googletagmanager.com/gtm.js?id=${id}`, { headers: { "User-Agent": UA } });
              if (g.status !== 200) { try { await g.body?.cancel(); } catch { /* ignore */ } continue; }
              const js = await readCapped(g);
              gtm_containers.push(id);
              matchBig(gtmC, "gtm_container", js, det, seen);
            } catch { /* container unreadable: skip */ }
          }
        }
      }
    }
  } catch (e) {
    html_status = "error"; error = String((e as Error)?.message ?? e).slice(0, 200);
  }
  return { html_status, dns_status, http_status, final_url, redirected_off, html_bytes, gtm_containers, det, error };
}

async function pool<T>(items: T[], n: number, fn: (x: T) => Promise<void>, deadline: number) {
  let i = 0;
  await Promise.all(Array.from({ length: Math.min(n, items.length) }, async () => {
    while (i < items.length && Date.now() < deadline) { const x = items[i++]; await fn(x); }
  }));
}

Deno.serve(async (req) => {
  let body: any = {}; try { body = await req.json(); } catch { body = {}; }
  const limit = Math.min(Number(body.limit ?? 40), 60);
  const only: string[] | null = Array.isArray(body.company_keys) ? body.company_keys : null;
  const dry = body.dry_run === true; // scan without saving (for testing signatures)
  const deadline = Date.now() + DEADLINE_MS;

  const { data: sigRows, error: se } = await db.from("tech_signatures").select("tool, category, method, pattern").eq("enabled", true);
  if (se) return new Response(JSON.stringify({ error: se.message }), { status: 500 });
  const sigs: Sig[] = [];
  const badSigs: string[] = [];
  for (const s of sigRows ?? []) { try { sigs.push({ ...s, re: new RegExp(s.pattern, "i") }); } catch { badSigs.push(`${s.tool}:${s.pattern}`); } }
  const htmlC = combine(sigs.filter(s => s.method === "html"));
  const gtmC = combine(sigs.filter(s => s.method === "html" && !["cms", "hosting", "tag_manager"].includes(s.category)));

  if (body.domains && Array.isArray(body.domains)) {
    // test mode: arbitrary domains, never saved
    const results: any[] = [];
    await pool(body.domains.slice(0, 20), CONCURRENCY, async (dm: string) => { const r = await scan(dm, sigs, htmlC, gtmC); results.push({ domain: dm, ...r }); }, deadline);
    return new Response(JSON.stringify({ test: true, detector_version: DETECTOR_VERSION, results }), { headers: { "Content-Type": "application/json" } });
  }
  const q = only
    ? db.from("icp_companies").select("company_key, company_name, domain").in("company_key", only).not("domain", "is", null)
    : db.from("companies_to_scan").select("company_key, company_name, domain").limit(limit);
  const { data: companies, error: ce } = await q;
  if (ce) return new Response(JSON.stringify({ error: ce.message }), { status: 500 });

  const run = dry ? null : (await db.from("tech_scan_runs").insert({}).select("id").single()).data;
  const tally = { checked: 0, html_ok: 0, blocked: 0, robots: 0, errors: 0, tools: 0, signals: 0 };
  const errs: string[] = []; const preview: any[] = [];

  await pool(companies ?? [], CONCURRENCY, async (c: any) => {
    const r = await scan(c.domain, sigs, htmlC, gtmC);
    tally.checked++;
    if (r.html_status === "ok") tally.html_ok++;
    else if (r.html_status === "blocked") tally.blocked++;
    else if (r.html_status === "robots_disallowed") tally.robots++;
    else { tally.errors++; errs.push(`${c.domain}: ${r.html_status} ${r.error ?? ""}`.slice(0, 160)); }
    tally.tools += new Set(r.det.map(x => x.tool)).size;
    if (dry) { preview.push({ domain: c.domain, html_status: r.html_status, tools: [...new Set(r.det.map(x => x.tool))] }); return; }
    const { data, error } = await db.rpc("ingest_tech_scan", {
      p_run_id: run?.id, p_company_key: c.company_key, p_domain: c.domain,
      p_html_status: r.html_status, p_dns_status: r.dns_status, p_http_status: r.http_status, p_final_url: r.final_url,
      p_redirected_off_domain: r.redirected_off, p_html_bytes: r.html_bytes, p_detections: r.det, p_error: r.error,
      p_detector_version: DETECTOR_VERSION, p_gtm_containers: r.gtm_containers,
    });
    if (error) { tally.errors++; errs.push(`${c.domain}: ingest ${error.message}`.slice(0, 160)); return; }
    tally.signals += data?.new_signals ?? 0;
  }, deadline);

  if (run) await db.from("tech_scan_runs").update({
    finished_at: new Date().toISOString(), companies_checked: tally.checked, html_ok: tally.html_ok, blocked: tally.blocked,
    robots_disallowed: tally.robots, errors: tally.errors, tools_found: tally.tools, tool_signals_new: tally.signals,
    notes: { limit, queued: companies?.length ?? 0, errors: errs.slice(0, 25), bad_signatures: badSigs, detector_version: DETECTOR_VERSION },
  }).eq("id", run.id);

  return new Response(JSON.stringify({ detector_version: DETECTOR_VERSION, run_id: run?.id ?? null, queued: companies?.length ?? 0, ...tally, bad_signatures: badSigs, sample_errors: errs.slice(0, 8), preview: dry ? preview : undefined }),
    { headers: { "Content-Type": "application/json" } });
});
