// P3 job-board collector: reads public job lists from Greenhouse, Lever and Ashby (no API keys needed).
// mode=probe   -> try unchecked company tokens; valid boards are ingested straight away
// mode=collect -> re-read every valid board (daily), find new + closed jobs, create hiring signals
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const UA = "gtm-signals-collector/1.0 (+https://github.com/knife-co)";
const CONCURRENCY = 12;
const TIMEOUT_MS = 10000;

type Job = { id: string; title: string; department: string | null; location: string | null; is_remote: boolean | null; url: string | null; published_at: string | null; raw: unknown };
type Result = { status: "valid" | "not_found" | "error"; jobs?: Job[]; boardName?: string | null; error?: string };

async function get(url: string): Promise<{ code: number; body: any }> {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
  try {
    const r = await fetch(url, { headers: { "User-Agent": UA, "Accept": "application/json" }, signal: ctrl.signal });
    let body: any = null;
    try { body = await r.json(); } catch { body = null; }
    return { code: r.status, body };
  } finally { clearTimeout(t); }
}

const iso = (v: any) => { if (v == null || v === "") return null; const d = new Date(typeof v === "number" ? v : String(v)); return isNaN(d.getTime()) ? null : d.toISOString(); };

async function readBoard(ats: string, token: string): Promise<Result> {
  const t = encodeURIComponent(token);
  try {
    if (ats === "greenhouse") {
      const r = await get(`https://boards-api.greenhouse.io/v1/boards/${t}/jobs`);
      if (r.code === 404) return { status: "not_found" };
      if (r.code !== 200 || !Array.isArray(r.body?.jobs)) return { status: "error", error: `HTTP ${r.code}` };
      const jobs: Job[] = r.body.jobs.map((j: any) => ({ id: String(j.id), title: j.title, department: null,
        location: j.location?.name ?? null, is_remote: /remote/i.test(j.location?.name ?? "") || null, url: j.absolute_url ?? null,
        published_at: iso(j.first_published ?? j.updated_at), raw: { updated_at: j.updated_at, requisition_id: j.requisition_id ?? null } }));
      let boardName: string | null = null;
      try { const n = await get(`https://boards-api.greenhouse.io/v1/boards/${t}`); boardName = n.body?.name ?? null; } catch { /* name is optional */ }
      return { status: "valid", jobs, boardName };
    }
    if (ats === "lever") {
      const r = await get(`https://api.lever.co/v0/postings/${t}?mode=json`);
      if (r.code === 404) return { status: "not_found" };
      if (r.code !== 200 || !Array.isArray(r.body)) return { status: "error", error: `HTTP ${r.code}` };
      const jobs: Job[] = r.body.map((j: any) => ({ id: String(j.id), title: j.text, department: j.categories?.department ?? j.categories?.team ?? null,
        location: j.categories?.location ?? null, is_remote: j.workplaceType ? j.workplaceType === "remote" : null, url: j.hostedUrl ?? null,
        published_at: iso(j.createdAt), raw: { team: j.categories?.team ?? null, commitment: j.categories?.commitment ?? null, workplaceType: j.workplaceType ?? null } }));
      return { status: "valid", jobs, boardName: null };
    }
    if (ats === "ashby") {
      const r = await get(`https://api.ashbyhq.com/posting-api/job-board/${t}`);
      if (r.code === 404) return { status: "not_found" };
      if (r.code !== 200 || !Array.isArray(r.body?.jobs)) return { status: r.code === 200 ? "not_found" : "error", error: `HTTP ${r.code}` };
      const jobs: Job[] = r.body.jobs.filter((j: any) => j.isListed !== false).map((j: any) => ({ id: String(j.id), title: j.title,
        department: j.department ?? j.team ?? null, location: j.location ?? null, is_remote: typeof j.isRemote === "boolean" ? j.isRemote : null,
        url: j.jobUrl ?? null, published_at: iso(j.publishedAt), raw: { team: j.team ?? null, employmentType: j.employmentType ?? null } }));
      return { status: "valid", jobs, boardName: null };
    }
    return { status: "error", error: "unknown ats" };
  } catch (e) {
    return { status: "error", error: String((e as Error)?.message ?? e).slice(0, 200) };
  }
}

async function pool<T>(items: T[], n: number, fn: (x: T) => Promise<void>) {
  let i = 0;
  await Promise.all(Array.from({ length: Math.min(n, items.length) }, async () => { while (i < items.length) { const x = items[i++]; await fn(x); } }));
}

Deno.serve(async (req) => {
  const url = new URL(req.url);
  let body: any = {};
  try { body = await req.json(); } catch { body = {}; }
  const mode = body.mode ?? url.searchParams.get("mode") ?? "collect";
  const limit = Math.min(Number(body.limit ?? url.searchParams.get("limit") ?? 300), 600);

  const view = mode === "probe" ? "boards_to_probe" : "boards_to_collect";
  const { data: boards, error } = await db.from(view).select("ats, token").limit(limit);
  if (error) return new Response(JSON.stringify({ error: error.message }), { status: 500 });

  const { data: run } = await db.from("collector_runs").insert({ mode }).select("id").single();
  const tally = { checked: 0, valid: 0, not_found: 0, error: 0, seen: 0, new: 0, closed: 0, signals: 0 };
  const errors: string[] = [];

  await pool(boards ?? [], CONCURRENCY, async (b: any) => {
    const res = await readBoard(b.ats, b.token);
    tally.checked++;
    if (res.status === "valid") {
      const { data, error: e } = await db.rpc("ingest_board", { p_ats: b.ats, p_token: b.token, p_jobs: res.jobs, p_board_name: res.boardName });
      if (e) { tally.error++; errors.push(`${b.ats}:${b.token} ingest ${e.message}`.slice(0, 200)); await db.rpc("mark_board", { p_ats: b.ats, p_token: b.token, p_status: "error", p_error: e.message }); return; }
      tally.valid++; tally.seen += data.seen; tally.new += data.new; tally.closed += data.closed; tally.signals += data.signals;
    } else {
      tally[res.status]++;
      if (res.status === "error") errors.push(`${b.ats}:${b.token} ${res.error}`);
      await db.rpc("mark_board", { p_ats: b.ats, p_token: b.token, p_status: res.status, p_error: res.error ?? null });
    }
  });

  await db.from("collector_runs").update({ finished_at: new Date().toISOString(), boards_checked: tally.checked, boards_valid: tally.valid,
    boards_not_found: tally.not_found, boards_error: tally.error, jobs_seen: tally.seen, jobs_new: tally.new, jobs_closed: tally.closed,
    gtm_signals_new: tally.signals, notes: { errors: errors.slice(0, 20), limit } }).eq("id", run?.id);

  return new Response(JSON.stringify({ run_id: run?.id, mode, ...tally, sample_errors: errors.slice(0, 5) }), { headers: { "Content-Type": "application/json" } });
});
