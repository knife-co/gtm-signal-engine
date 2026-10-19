# Comparison study: signal accounts vs cold P1 accounts

**Written and frozen on 18 Oct 2026, before any outcome existed.** Study id `p3-vs-p1-2026-10-18`. Result to be read once, on or after **17 Nov 2026**.

## Question

Do companies with a live GTM-ops hiring signal start using new GTM tools more often, in the next 30 days, than comparable companies with no signal?

## Why this outcome

No outreach is being sent, so there are no replies to compare. Adopting a new GTM tool is real buying behaviour, and it is read from company websites by the tech detector: a different source from the job posts that create the signal, so the signal is not grading itself.

## Groups

- **Universe:** P1 companies P3 can actually watch: a valid Greenhouse/Lever/Ashby board, board name not flagged "different", at least one successful website scan. "Cold" therefore means watched and quiet, not unseen.
- **Signal arm:** at least one `gtm_hire` signal in a core-ops function (RevOps, Sales Ops, Marketing Ops, Marketing Automation, CRM Admin, CRM Dev, GTM Engineering) posted in the 30 days to 17 Oct. These were 22 of 22 right in the audit.
- **Cold arm:** no `gtm_hire` signal of any kind in the same window.
- **Excluded:** companies with only broad-bucket signals (their labels were mostly wrong).

## Matching

Signal companies skewed bigger. Coarsened exact matching on total open jobs (bands 1–9, 10–24, 25–59, 60+), equal numbers per arm in each band, picked in md5 hash order.

| | Signal | Cold |
|---|---|---|
| Before matching | 32 | 59 |
| Matched sample | 30 | 30 |

Balance (standardised mean difference, under 0.1 = balanced): log open jobs 0.26 before → **−0.03** after; GTM tools already in use −0.04.

Membership is locked: a database trigger refuses any update or delete on `cohort_members`.

## Outcome and analysis

- **Primary:** share of companies with at least one new GTM tool first seen after the freeze, absent from the baseline scan, and seen again on a later scan, within 30 days.
- **Secondary:** share of cold companies that post a core-ops role in the window.
- **Analysis:** as assigned (no switching), each arm's rate with Wilson 95% intervals, the difference, Fisher's exact test. Read once.

## Stated limits

- With 30 a side, a difference is detected 4 times in 5 only if it is large, about 10% against 45%. Smaller real differences may not show.
- Buying intent, not replies or revenue.
- The detector misses tools hidden behind logins, equally for both arms.
