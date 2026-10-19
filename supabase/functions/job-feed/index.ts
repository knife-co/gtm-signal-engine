// P3 job-feed: worldwide-remote job boards + description reading for unclear ATS jobs + "jobs for you" Slack digest.
// mode=collect  -> Remotive, Remote OK, Jobicy, Himalayas (Nigeria filter), We Work Remotely (each at most once per ~20h)
// mode=describe -> read descriptions of open GTM jobs on Greenhouse/Lever/Ashby whose location just says "Remote"
// mode=digest   -> post new "yes" jobs to Slack (only marked as sent once Slack confirms)
// mode=daily    -> describe, collect, digest
// Rules: identify ourselves, honour robots.txt, stop a source on 403/429/503, keep the board's own link, store no full descriptions.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const UA = "gtm-signals-collector/1.0 (+https://github.com/knife-co)";
const TIMEOUT_MS = 20000;
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

// Coarse title filter so we only read descriptions of possibly-relevant jobs; SQL normalize_title makes the final call.
const TITLE_HINT = /(rev ?ops|revenue|sales ?op|marketing ?op|\bmops\b|\bgtm\b|go[- ]to[- ]market|\bcrm\b|salesforce|hubspot|marketo|automation|lifecycle|demand gen|growth|operations|systems|enablement|strategy|analyst|\bops\b)/i;

// ---------- description reading ----------
const PLACE_OK = /^(nigeria|africa|lagos|anywhere|any country|the world|world|worldwide|emea)/i;
const NOT_IN = String.raw`(?!\s+(in|within|across)\s+(?!the world))`; // "anywhere in the US" is not worldwide
const NO_RULES: RegExp[] = [
  /\banywhere\s+(in|within|across)\s+(the\s+)?([a-z .,'-]{2,40})/i,
  /\b(must|need to|required to|should|will need to)\s+(currently\s+)?(be\s+)?(located|based|reside|residing|live|living)\s+(in|within)\s+(the\s+)?([a-z .,'-]{2,40})/i,
  /\b(authori[sz]ed|eligible|legally (able|permitted)|permission)\s+to\s+work\s+in\s+(the\s+)?(u\.?s\.?a?|united states|canada|uk|united kingdom|european union|eu)\b/i,
  /\b(u\.?s\.?|usa|united states|canada|uk)[- ](based|only)\s+(candidates|applicants|residents|employees|team members)\b/i,
  /\b(this (role|position) is (only )?(open|available) (only )?to)\s+(candidates|applicants|residents|people)?\s*(in|from|based in|located in)\s+(the\s+)?([a-z .,'-]{2,40})/i,
  /\bopen\s+(only\s+)?to\s+(candidates|applicants|residents)\s+(in|from|based in|located in)\s+(the\s+)?([a-z .,'-]{2,40})/i,
  /\b(we\s+(are|can)\s+(only|currently only)\s+(able to\s+)?(hire|employ))\s+(in|people in|candidates in|residents of)\s+(the\s+)?([a-z .,'-]{2,40})/i,
];
const YES_RULES: RegExp[] = [
  new RegExp(String.raw`\b(anywhere in the world|work from anywhere${NOT_IN}|any country|regardless of (your )?(location|country)|fully distributed across \d+ countries|hire (talent |people )?(globally|worldwide|from anywhere${NOT_IN})|open to candidates (worldwide|globally|anywhere${NOT_IN}))`, "i"),
  /\b(candidates|applicants|hire|hiring|based|located|team members?)\b[^.]{0,60}\b(nigeria|africa)\b/i,
];

function plain(html: string): string {
  return html.replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&#39;|&#x27;/g, "'").replace(/&amp;/g, "&")
    .replace(/<[^>]+>/g, " ").replace(/&nbsp;/g, " ").replace(/\s+/g, " ").slice(0, 30000);
}
function sentenceAround(t: string, idx: number) {
  const s = Math.max(t.lastIndexOf(".", idx) + 1, idx - 150), e = t.indexOf(".", idx);
  return t.slice(s, e === -1 ? idx + 150 : Math.min(e + 1, idx + 200)).trim().slice(0, 220);
}
function readDescription(raw: string | null | undefined): { desc_verdict: "yes" | "no" | null; desc_evidence: string | null } {
  if (!raw) return { desc_verdict: null, desc_evidence: null };
  const t = plain(raw);
  let yes: string | null = null, no: string | null = null;
  for (const r of YES_RULES) { const m = r.exec(t); if (m) { yes = sentenceAround(t, m.index); break; } }
  for (const r of NO_RULES) {
    const m = r.exec(t); if (!m) continue;
    const place = (m[m.length - 1] ?? "").trim();
    if (PLACE_OK.test(place)) { yes = yes ?? sentenceAround(t, m.index); continue; }
    no = sentenceAround(t, m.index); break;
  }
  if (yes && !no) return { desc_verdict: "yes", desc_evidence: yes };
  if (no && !yes) return { desc_verdict: "no", desc_evidence: no };
  if (yes && no) return { desc_verdict: null, desc_evidence: "Mixed: " + no };
  return { desc_verdict: null, desc_evidence: null };
}

// ---------- polite fetching ----------
const robotsCache = new Map<string, string[]>();
async function robotsOk(u: URL) {
  if (!robotsCache.has(u.origin)) {
    const dis: string[] = [];
    try {
      const r = await fetch(u.origin + "/robots.txt", { headers: { "User-Agent": UA } });
      if (r.status === 200) {
        let applies = false;
        for (const raw of (await r.text()).split(/\r?\n/)) {
          const line = raw.split("#")[0].trim(); if (!line) continue;
          const i = line.indexOf(":"); const k = line.slice(0, i).trim(); const v = line.slice(i + 1).trim();
          if (/^user-agent$/i.test(k)) applies = v === "*" || /gtm-signals/i.test(v);
          else if (applies && /^disallow$/i.test(k) && v) dis.push(v);
        }
      }
    } catch { /* unreachable robots = no rules */ }
    robotsCache.set(u.origin, dis);
  }
  return !robotsCache.get(u.origin)!.some((d) => u.pathname.startsWith(d));
}
class Stop extends Error {}
async function getText(url: string, accept = "application/json"): Promise<{ code: number; text: string }> {
  const u = new URL(url);
  if (!(await robotsOk(u))) throw new Stop(`robots.txt disallows ${u.pathname}`);
  const ctrl = new AbortController(); const t = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
  try {
    const r = await fetch(url, { headers: { "User-Agent": UA, Accept: accept }, signal: ctrl.signal });
    if ([403, 429, 503].includes(r.status)) throw new Stop(`HTTP ${r.status} (stopping this source)`);
    return { code: r.status, text: await r.text() };
  } finally { clearTimeout(t); }
}
const iso = (v: any) => { if (v == null || v === "") return null; const sv = String(v); const d = new Date(typeof v === "number" ? (v < 1e12 ? v * 1000 : v) : /^\d{4}-\d\d-\d\d \d/.test(sv) ? sv.replace(" ", "T") : sv); return isNaN(d.getTime()) ? null : d.toISOString(); };

type J = { id: string; title: string; company: string | null; url: string; location: string | null; countries?: string[] | null; tz?: number[] | null; published_at: string | null; desc_verdict: string | null; desc_evidence: string | null };
const mk = (o: Omit<J, "desc_verdict" | "desc_evidence">, desc: string | null | undefined): J => ({ ...o, ...readDescription(desc) });

// ---------- sources ----------
const SOURCES: Record<string, () => Promise<{ jobs: J[]; full: boolean; calls: number }>> = {
  async remotive() {
    // Their open feed only returns a sample; ask by category. 2 calls/day, 35s apart (limit: 4/day, max 2/min).
    const all: any[] = []; let calls = 0;
    for (const cat of ["sales-business", "marketing"]) {
      if (calls > 0) await sleep(35000);
      const r = await getText(`https://remotive.com/api/remote-jobs?category=${cat}`); calls++;
      if (r.code !== 200) throw new Error(`Remotive ${cat} HTTP ${r.code}`);
      all.push(...(JSON.parse(r.text).jobs ?? []));
    }
    const jobs = all.filter((x: any) => TITLE_HINT.test(x.title ?? "")).map((x: any) => mk({ id: String(x.id), title: x.title, company: x.company_name ?? null,
      url: x.url, location: x.candidate_required_location ?? null, published_at: iso(x.publication_date) }, x.description));
    return { jobs, full: true, calls };
  },
  async remoteok() {
    const r = await getText("https://remoteok.com/api");
    const arr = JSON.parse(r.text);
    const jobs = (Array.isArray(arr) ? arr : []).filter((x: any) => x?.id && x?.position && TITLE_HINT.test(x.position)).map((x: any) => mk({ id: String(x.id), title: x.position,
      company: x.company ?? null, url: x.url ?? `https://remoteok.com/remote-jobs/${x.id}`, location: x.location ?? null, published_at: iso(x.date ?? x.epoch) }, x.description));
    return { jobs, full: false, calls: 1 };
  },
  async jobicy() {
    const r = await getText("https://jobicy.com/api/v2/remote-jobs?count=100");
    const b = JSON.parse(r.text);
    const jobs = (b.jobs ?? []).filter((x: any) => TITLE_HINT.test(x.jobTitle ?? "")).map((x: any) => mk({ id: String(x.id), title: plain(x.jobTitle), company: x.companyName ?? null,
      url: x.url, location: x.jobGeo ?? null, published_at: iso(x.pubDate) }, x.jobDescription));
    return { jobs, full: false, calls: 1 };
  },
  async himalayas() {
    // Search endpoint with country=Nigeria returns only jobs that can hire someone in Nigeria.
    const queries = ["revenue operations", "sales operations", "marketing operations", "gtm engineer", "go-to-market", "salesforce", "hubspot", "crm"];
    const seen = new Map<string, J>(); let calls = 0;
    for (const q of queries) {
      for (let page = 1; page <= 2; page++) {
        if (calls > 0) await sleep(1500);
        const r = await getText(`https://himalayas.app/jobs/api/search?q=${encodeURIComponent(q)}&country=Nigeria&page=${page}`); calls++;
        if (r.code !== 200) break;
        const list = JSON.parse(r.text).jobs ?? [];
        for (const x of list) {
          const id = String(x.guid ?? x.applicationLink ?? x.title + x.companyName);
          if (seen.has(id) || !TITLE_HINT.test(x.title ?? "")) continue;
          seen.set(id, mk({ id, title: x.title, company: x.companyName ?? null, url: x.guid ?? x.applicationLink, location: null,
            countries: Array.isArray(x.locationRestrictions) ? x.locationRestrictions.map((c: any) => typeof c === "string" ? c : c?.name ?? String(c)) : [],
            tz: Array.isArray(x.timezoneRestrictions) ? x.timezoneRestrictions : null, published_at: iso(x.pubDate) }, x.description));
        }
        if (list.length < 20) break;
      }
    }
    return { jobs: [...seen.values()], full: false, calls };
  },
  async weworkremotely() {
    const r = await getText("https://weworkremotely.com/categories/remote-sales-and-marketing-jobs.rss", "application/rss+xml");
    const tag = (it: string, n: string) => { const m = it.match(new RegExp(`<${n}>(?:<!\\[CDATA\\[)?([\\s\\S]*?)(?:\\]\\]>)?</${n}>`)); return m ? m[1].trim() : null; };
    const jobs: J[] = [];
    for (const it of r.text.split("<item>").slice(1)) {
      const full = plain(tag(it, "title") ?? ""); const i = full.indexOf(":");
      const company = i > 0 ? full.slice(0, i).trim() : null; const title = i > 0 ? full.slice(i + 1).trim() : full;
      if (!TITLE_HINT.test(title)) continue;
      const link = tag(it, "link") ?? tag(it, "guid") ?? "";
      jobs.push(mk({ id: tag(it, "guid") ?? link, title, company, url: link, location: tag(it, "region"), published_at: iso(tag(it, "pubDate")) }, tag(it, "description")));
    }
    return { jobs, full: true, calls: 1 };
  },
};

async function collect(only: string[] | null, force: boolean) {
  const { data: srcs } = await db.from("job_feed_sources").select("*").eq("enabled", true);
  const out: any[] = [];
  for (const s of srcs ?? []) {
    if (only && !only.includes(s.source)) continue;
    const since = s.last_called_at ? Date.now() - new Date(s.last_called_at).getTime() : Infinity;
    const minMs = force ? 3600_000 : (Number(String(s.min_interval).split(":")[0]) || 20) * 3600_000; // force still waits 1h (Jobicy rule)
    if (since < minMs) { out.push({ source: s.source, skipped: "called " + Math.round(since / 60000) + " min ago" }); continue; }
    try {
      const res = await SOURCES[s.source]();
      const { data, error } = await db.rpc("ingest_remote_jobs", { p_source: s.source, p_jobs: res.jobs, p_full_list: res.full });
      out.push(error ? { source: s.source, error: error.message } : { ...data, calls: res.calls });
    } catch (e) {
      const msg = String((e as Error)?.message ?? e).slice(0, 200);
      await db.from("job_feed_sources").update({ last_called_at: new Date().toISOString(), last_status: "error: " + msg }).eq("source", s.source);
      out.push({ source: s.source, error: msg });
    }
  }
  return out;
}

async function describe(limit: number) {
  const { data: rows } = await db.from("ats_jobs_to_describe").select("ats, token, job_id").limit(limit);
  const stopped = new Set<string>(); const ashbyBoards = new Map<string, any[]>();
  const tally = { checked: 0, yes: 0, no: 0, unclear: 0, errors: 0 } as Record<string, number>;
  const results: any[] = [];
  let i = 0;
  await Promise.all(Array.from({ length: 6 }, async () => {
    while (i < (rows ?? []).length) {
      const r: any = rows![i++];
      if (stopped.has(r.ats)) continue;
      let code = 0, text: string | null = null;
      try {
        if (r.ats === "greenhouse") {
          const g = await getText(`https://boards-api.greenhouse.io/v1/boards/${encodeURIComponent(r.token)}/jobs/${encodeURIComponent(r.job_id)}`); code = g.code;
          if (code === 200) text = JSON.parse(g.text).content ?? null;
        } else if (r.ats === "lever") {
          const g = await getText(`https://api.lever.co/v0/postings/${encodeURIComponent(r.token)}/${encodeURIComponent(r.job_id)}`); code = g.code;
          if (code === 200) { const b = JSON.parse(g.text); text = [b.descriptionPlain, ...(b.lists ?? []).map((l: any) => l.text + " " + l.content), b.additionalPlain].filter(Boolean).join(" "); }
        } else if (r.ats === "ashby") {
          if (!ashbyBoards.has(r.token)) {
            ashbyBoards.set(r.token, []);
            const g = await getText(`https://api.ashbyhq.com/posting-api/job-board/${encodeURIComponent(r.token)}`); code = g.code;
            if (code === 200) ashbyBoards.set(r.token, JSON.parse(g.text).jobs ?? []);
          } else code = 200;
          const j = ashbyBoards.get(r.token)!.find((x: any) => String(x.id) === r.job_id);
          text = j ? (j.descriptionPlain ?? j.descriptionHtml ?? null) : null;
        }
      } catch (e) {
        if (e instanceof Stop) stopped.add(r.ats);
        tally.errors++; continue;
      }
      const d = readDescription(text);
      tally.checked++; tally[d.desc_verdict ?? "unclear"]++;
      results.push({ ats: r.ats, token: r.token, job_id: r.job_id, http_status: code, desc_verdict: d.desc_verdict, desc_evidence: d.desc_evidence, checked_at: new Date().toISOString() });
    }
  }));
  if (results.length) { const { error } = await db.from("job_description_checks").upsert(results); if (error) tally.write_error = error.message as any; }
  return { ...tally, stopped: [...stopped] };
}

async function digest(force: boolean) {
  const { data, error } = await db.rpc("jobs_slack_digest", { p_force: force });
  if (error) return { error: error.message };
  if (!data?.keys?.length) return { sent: 0 };
  const hook = Deno.env.get("SLACK_WEBHOOK_URL");
  if (!hook) return { sent: 0, note: "SLACK_WEBHOOK_URL not set" };
  const r = await fetch(hook, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ text: data.text, blocks: data.blocks }) });
  if (!r.ok) return { sent: 0, slack_status: r.status };
  await db.rpc("jobs_mark_notified", { p_keys: data.keys });
  return { sent: data.keys.length };
}

Deno.serve(async (req) => {
  let body: any = {};
  try { body = await req.json(); } catch { body = {}; }
  const mode = body.mode ?? "daily";
  const { data: run } = await db.from("job_feed_runs").insert({ mode }).select("id").single();
  const stats: any = { mode };
  if (mode === "describe" || mode === "daily") stats.describe = await describe(Math.min(Number(body.limit ?? 60), 120));
  if (mode === "collect" || mode === "daily") stats.collect = await collect(body.sources ?? null, !!body.force);
  if (mode === "digest" || mode === "daily") stats.digest = await digest(!!body.force_slack);
  await db.from("job_feed_runs").update({ finished_at: new Date().toISOString(), stats }).eq("id", run?.id);
  return new Response(JSON.stringify({ run_id: run?.id, ...stats }), { headers: { "Content-Type": "application/json" } });
});
