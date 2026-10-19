// Fetches each sampled signal's posting from the company's own ATS so a human can audit it.
// Writes only the evidence columns of signal_audit; the verdict is filled in by the auditor.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";
const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const UA = "gtm-signals-collector/1.0 (+https://github.com/knife-co)";
const plain = (h: string) => h.replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&amp;/g, "&").replace(/<[^>]+>/g, " ").replace(/&nbsp;/g, " ").replace(/\s+/g, " ").trim();
async function get(u: string) { const r = await fetch(u, { headers: { "User-Agent": UA, Accept: "application/json" } }); let b: any = null; try { b = await r.json(); } catch {} return { code: r.status, b }; }
const ashby = new Map<string, any[]>();
Deno.serve(async (req) => {
  const { audit_id } = await req.json();
  const { data: rows } = await db.from("signal_audit").select("sample_rank, lead_ref").eq("audit_id", audit_id).is("fetched_status", null);
  let done = 0; let i = 0;
  await Promise.all(Array.from({ length: 5 }, async () => {
    while (i < (rows ?? []).length) {
      const r: any = rows![i++];
      const [ats, token, id] = r.lead_ref.split(":");
      let out: any = { fetched_status: 0 };
      try {
        if (ats === "greenhouse") {
          const g = await get(`https://boards-api.greenhouse.io/v1/boards/${token}/jobs/${id}`);
          out = { fetched_status: g.code, fetched_title: g.b?.title ?? null, fetched_location: g.b?.location?.name ?? null,
            fetched_posted: (g.b?.first_published ?? g.b?.updated_at ?? "").slice(0, 10) || null, fetched_excerpt: g.b?.content ? plain(g.b.content).slice(0, 1800) : null };
        } else if (ats === "lever") {
          const g = await get(`https://api.lever.co/v0/postings/${token}/${id}`);
          out = { fetched_status: g.code, fetched_title: g.b?.text ?? null, fetched_location: g.b?.categories?.location ?? null,
            fetched_posted: g.b?.createdAt ? new Date(g.b.createdAt).toISOString().slice(0, 10) : null, fetched_excerpt: g.b?.descriptionPlain ? String(g.b.descriptionPlain).replace(/\s+/g, " ").slice(0, 1800) : null };
        } else if (ats === "ashby") {
          if (!ashby.has(token)) { const g = await get(`https://api.ashbyhq.com/posting-api/job-board/${token}`); ashby.set(token, g.code === 200 ? (g.b?.jobs ?? []) : []); }
          const j = ashby.get(token)!.find((x: any) => String(x.id) === id);
          out = j ? { fetched_status: 200, fetched_title: j.title, fetched_location: j.location ?? null, fetched_posted: (j.publishedAt ?? "").slice(0, 10) || null,
            fetched_excerpt: String(j.descriptionPlain ?? plain(j.descriptionHtml ?? "")).replace(/\s+/g, " ").slice(0, 1800) } : { fetched_status: 404 };
        }
      } catch (e) { out = { fetched_status: -1, fetched_excerpt: String(e).slice(0, 200) }; }
      await db.from("signal_audit").update(out).eq("audit_id", audit_id).eq("sample_rank", r.sample_rank);
      done++;
    }
  }));
  return new Response(JSON.stringify({ fetched: done }), { headers: { "Content-Type": "application/json" } });
});
