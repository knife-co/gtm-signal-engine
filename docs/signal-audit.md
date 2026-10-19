# Signal audit, 17 Oct 2026

**Question:** of the signals P3 delivers to Salesforce and Slack, how many are wrong?

## Rules, written before the sample was drawn

A signal is a **false positive** if it fails any of these four checks:

| Check | Question | Fails when |
|---|---|---|
| Real | Does (or did) the posting exist as a real opening on the company's own job board? | Template, placeholder, talent pool, evergreen "general application" |
| Role | Will this person own or change how the company sells or markets (RevOps, Sales Ops, Marketing Ops, GTM Engineering, CRM admin/dev, marketing automation, GTM strategy)? | Seller, recruiter, finance, legal, engineering, support, or a role that only mentions GTM |
| Company | Is it attached to the right company? | Another company's board, an agency hiring for a client |
| Date | Was it posted inside the 30-day window the signal claims? | Older repost |

The rules are stored in the `signal_audit_rules` table.

## Method

1. **Sample:** 50 of the 228 delivered signal clusters, ordered by `md5(lead_ref || ':audit-2026-10-17')` and the first 50 taken. Anyone can redraw the same 50.
2. **Evidence:** the `signal-audit-fetch` function pulled each posting fresh from Greenhouse, Lever or Ashby (45 live, 5 closed since; a closed posting counts as real if the collector saw it live).
3. **Verdict:** each posting read by hand; verdict, failed check and a one-line reason stored in `signal_audit`. An empty `owner_verdict` column is there for a second reviewer.

## Results

**22 of 50 were false positives: 44% (Wilson 95% interval 31–58%).** No fake postings, wrong companies or stale dates: every failure was about *what the role is*.

| Role bucket | Audited | Right | Wrong |
|---|---|---|---|
| Marketing Operations | 8 | 8 | 0 |
| Revenue Operations | 7 | 7 | 0 |
| Sales Ops, CRM Admin, CRM Dev, Marketing Automation, GTM Engineering | 7 | 7 | 0 |
| GTM Strategy | 15 | 6 | 9 |
| Lifecycle and CRM marketing | 6 | 0 | 6 |
| Demand Generation | 4 | 0 | 4 |
| Other (CRM consulting, growth ops, unmapped) | 3 | 0 | 3 |

Errors by type: 11 campaign marketers, 4 sellers, 3 customer-facing (support, onboarding), 2 finance, 1 agency consultant serving clients, 1 title the role map misread ("Asset Lifecycle Coordinator", an IT job).

**Lesson:** a keyword like "GTM" in a job title is a weak label. The function words (operations, admin, automation, engineering) carry the signal.

## What changed

`signal_function_policy` now lets only the seven core buckets create alerts. On the audited sample: 0 of the 22 false positives are still delivered, and 22 of the 28 real signals are (the 6 lost were mostly GTM strategy and enablement roles). Alerts fell from ~47 to ~23 a week.

## Limits

- One auditor (me). A second reviewer would make the figure sturdier.
- The after-fix figures are in-sample. Next: audit a fresh 50 with a new hash seed.
- Only `gtm_hire` signals existed when the sample was drawn.
