# GTM Signal Engine (P3)

A signal engine that watches companies for signs they are about to invest in sales and marketing systems, then tells a rep **who to contact, why, and what to say**. It reads ~310 company job boards and company websites every morning, scores each account, writes to Salesforce and posts to Slack.

Built on a $0 stack: **Supabase (Postgres + Edge Functions + pg_cron)**, **Salesforce Developer Edition** and a **Slack** incoming webhook. No laptop, no n8n: it runs on its own every day. Third project in my GTM Engineering portfolio. It works on the companies found by [gtm-icp-engine](https://github.com/knife-co/gtm-icp-engine) (P1) and the data cleaned by [gtm-enrichment-pipeline](https://github.com/knife-co/gtm-enrichment-pipeline) (P2).

## Results

**I hand-checked 50 alerts.** Alerts about core GTM-ops hires were right **22 of 22** times. Alerts about roles that only had "GTM", "lifecycle" or "demand gen" in the title were wrong **22 of 28** times. So the engine now alerts on the core roles only.

| | Before the audit | After (18 Oct) |
|---|---|---|
| Clean signals per week | ~47 | **~23** |
| Audited signals that were right | 28 of 50 (56%) | **22 of 22 (100%)**, 95% range 85–100% |
| Audited real signals still delivered | 28 of 28 | 22 of 28 (the cost) |

The 100% is measured on the same 50 alerts that shaped the fix, so it flatters the change. A fresh sample of 50 is the honest re-test. Method and the full breakdown: [docs/signal-audit.md](docs/signal-audit.md).

**Other numbers from the sprint (12–18 Oct 2026):**

- 257 raw signal clusters became **18 routed actions** on the first router run (dedupe, noise rules, decay, priority). A re-run created 0 duplicates.
- Salesforce: 0 write failures in 7 days of daily runs; 1 Task per new Tier A account, never repeated within 14 days.
- Tech-stack detector: at least one GTM tool detected for **65%** of scanned companies, precision 0.98 on a hand check, 0 fake "tool added" alerts after five safeguards.
- Health check: 7 scheduled jobs, 0 failed runs in 7 days. Closed a gap where 16 database views could be read with the public key.

**Still open:** a frozen, matched comparison of 30 signal accounts against 30 cold P1 accounts. It asks whether signal accounts start using new GTM tools more often in the 30 days after 18 Oct. The rules were written and published before the result: [docs/comparison-study.md](docs/comparison-study.md). Result due 17 Nov 2026.

## How it works

```
05:30  job-board-collector   Greenhouse / Lever / Ashby boards → new GTM-ops job posts = gtm_hire signals
06:00  tech-stack-detector   homepage HTML, Google Tag Manager container, DNS → new GTM tool = tool_added signal
06:20  job-feed              worldwide-remote job boards → "Jobs for me" list (a side project, see below)
07:15  signal-router         dedupe + noise rules → decay → priority = ICP fit × signal strength
                             → tier (A/B/C) + play → Salesforce (Signal__c, Account, Task) → Slack digest
```

- **Signals decay.** Each type has a fresh period, then a half-life, then a hard stop. A 3-day-old job post outranks a 40-day-old one.
- **One score per account:** the strongest live signal of each type, combined so two weak signals never beat one strong one.
- **Priority** = 100 × (ICP/100)^0.4 × (signal/100)^0.6. Tiers: A ≥ 70, B ≥ 50, C ≥ 25. Accounts with a strong signal but no ICP score go to a review lane instead of being dropped.
- **Plays:** the first matching play gives the who, the angle and the channel.
- **Only trusted role types alert.** `signal_function_policy` lists which job functions may create alerts, with the audit result that decided it. Switched-off types still reach Salesforce marked "noise".
- **Safe to re-run.** Salesforce writes are upserts keyed on `Signal_Key__c`; Slack alerts stay pending until Slack confirms delivery.
- **Polite to websites.** Identifies itself, reads robots.txt, one homepage request per company, stops on 403/429/503 or a bot challenge, backs off from dead domains.

## Repo layout

```
supabase/
  migrations/   29 SQL files, the exact changes applied to the live project, in order
  seed/         01 tech signatures (105) · 02 extra title rule · 03 daily schedule
  functions/    job-board-collector · tech-stack-detector · signal-router · job-feed · signal-audit-fetch
docs/           signal-audit.md · comparison-study.md
```

## Rebuild it

1. Build P1 and P2 first: P3 uses their tables and helpers (`icp_companies`, `normalize_title()`, `title_function_map`, `name_verdict()` and others).
2. Run the files in `supabase/migrations/` in name order, then `supabase/seed/01` and `02`.
3. Deploy the five functions in `supabase/functions/` with **Verify JWT on**.
4. Add these Edge Function secrets in the Supabase dashboard (never in code): `SF_CLIENT_ID`, `SF_USERNAME`, `SF_PRIVATE_KEY`, `SF_LOGIN_URL`, `SLACK_WEBHOOK_URL`.
5. Call `signal-router` once with `{"mode":"setup"}` to create the Salesforce fields, then `{"mode":"check"}` to test the logins.
6. Edit `supabase/seed/03_schedule.sql` (your project ref and anon key) and run it.

The migrations are the real history, so some files replace earlier ones (for example the detector's v1 → v2). Step-by-step guides with a check after each step live in my Notion build guides.

## Side project: Jobs for me

The `job-feed` function reuses the engine for my own job search: five worldwide-remote boards (Himalayas, Remote OK, Jobicy, We Work Remotely; Remotive is switched off), a location and job-description reader that decides **yes / maybe / no for a candidate in Lagos**, and a ranked list with a daily Slack digest. GTM roles clearly open to Nigeria went from 0 to 45 on the first day. Each board's call limits and attribution rules are stored next to its data, and every job links back to its board.

## What is not in this repo

Keys, the Salesforce org, the Supabase project ID (placeholders like `YOUR_PROJECT_REF` instead), and any collected job or company data. Job boards' terms do not allow republishing their listings.
