# Manual Usage Analytics Queries

When `--usage` is denied, partially fails, or returns empty results, you can run these NRQL queries by hand in New Relic and save the results into the export archive manually. The DMA New Relic App reads the same JSON files regardless of how they were produced.

> **When you need this:** Your User API Key cannot run NRQL against `NrAuditEvent`, `NrAiIncident`, or `NrConsumption` — typically because the role lacks **insights query access** or your account does not retain audit history. The export still produces a valid archive without these files; usage-based prioritization in the DMA App will simply be unavailable.

---

## Table of Contents

1. [Overview](#overview)
2. [How to Run NRQL Manually](#how-to-run-nrql-manually)
3. [Query 1 — Dashboard Views (Top 100)](#query-1--dashboard-views-top-100)
4. [Query 2 — Alerts Most Fired](#query-2--alerts-most-fired)
5. [Query 3 — Most Active Users](#query-3--most-active-users)
6. [Query 4 — Ingest by Data Type](#query-4--ingest-by-data-type)
7. [Inserting Manual Files into the Archive](#inserting-manual-files-into-the-archive)
8. [Permission Requirements](#permission-requirements)
9. [What If a Query Returns Nothing?](#what-if-a-query-returns-nothing)

---

## Overview

The `--usage` flag instructs the script to run four NRQL queries per account and save the results as JSON files under `account_<id>/_usage_analytics/`. The files drive usage-based migration prioritization in the DMA App — for example, "rank dashboards by view count so we migrate the most-used ones first."

| Query | File | Source Event | Retention |
|---|---|---|---|
| Dashboard views (top 100) | `dashboard_views_top100.json` | `NrAuditEvent` | 30–395 days (plan-dependent) |
| Alerts most fired | `alerts_most_fired.json` | `NrAiIncident` | 90 days standard |
| Most active users | `users_most_active.json` | `NrAuditEvent` | Same as dashboards |
| Ingest by data type | `ingest_by_data_type.json` | `NrConsumption` | 13 months |

If the script's `--usage` step succeeds, you do not need this document. If it fails for one or more queries, run the affected queries by hand and merge the output into the archive before uploading to DMA.

---

## How to Run NRQL Manually

### Option A — UI (NRQL Editor)

1. Sign in at [one.newrelic.com](https://one.newrelic.com).
2. Click **Query your data** in the left navigation.
3. Switch to the **NRQL** tab.
4. Pick the correct account in the account selector (top-right of the editor) — queries are scoped per-account.
5. Paste a query, click **Run**.
6. Click **Export** → **JSON** to download the result.

### Option B — NerdGraph

```bash
ACCOUNT_ID=1234567
curl -s -X POST https://api.newrelic.com/graphql \
  -H "Content-Type: application/json" \
  -H "API-Key: $NR_API_KEY" \
  -d "$(jq -n --arg q '<NRQL HERE>' --argjson aid $ACCOUNT_ID \
        '{query: ("{ actor { account(id: \(.aid)) { nrql(query: \"" + .q + "\") { results } } } }")}')" \
  | jq '.data.actor.account.nrql.results'
```

The script uses this same pattern internally. Output is the `results` array — that is exactly what the JSON file should contain.

---

## Query 1 — Dashboard Views (Top 100)

Identifies which dashboards have actually been used in the last 90 days. Migration priority is typically driven by view count — dashboards with zero views are candidates for archival rather than translation.

### NRQL

```sql
SELECT count(*) AS 'views', latest(timestamp) AS 'lastViewed'
FROM NrAuditEvent
WHERE actionIdentifier = 'dashboard.view'
FACET targetId
LIMIT MAX
SINCE 90 days ago
```

### Expected Output Shape

```json
[
  {
    "facet": "MTIzNDU2N3xWSVp8REFTSEJPQVJEfDk4NzY1NDM=",
    "targetId": "MTIzNDU2N3xWSVp8REFTSEJPQVJEfDk4NzY1NDM=",
    "views": 412,
    "lastViewed": 1714512034567
  },
  {
    "facet": "MTIzNDU2N3xWSVp8REFTSEJPQVJEfDg3NjU0MzI=",
    "targetId": "MTIzNDU2N3xWSVp8REFTSEJPQVJEfDg3NjU0MzI=",
    "views": 287,
    "lastViewed": 1714498822101
  }
]
```

### Save As

```
account_<ACCOUNT_ID>/_usage_analytics/dashboard_views_top100.json
```

> **Top 100 truncation.** The script's NRQL fetches `LIMIT MAX` (~2000 facets), then sorts by view count in post-processing and keeps the top 100. If you run this manually, do the same trim:
> ```bash
> jq 'sort_by(-.views) | .[0:100]' raw_export.json > dashboard_views_top100.json
> ```

### Joining to Dashboard Names

`targetId` is the GUID of the dashboard. Cross-reference against `account_<id>/dashboards/dashboards.json` (which has both GUID and human-readable name) to translate.

---

## Query 2 — Alerts Most Fired

Identifies which alert conditions have actually fired incidents over the last 90 days. Alert conditions that never fire are candidates for review rather than translation — they may be misconfigured or measuring inactive systems.

### NRQL

```sql
SELECT count(*) AS 'fired'
FROM NrAiIncident
FACET conditionName
LIMIT MAX
SINCE 90 days ago
```

### Expected Output Shape

```json
[
  { "facet": "Web transaction time > 2s", "conditionName": "Web transaction time > 2s", "fired": 142 },
  { "facet": "Error rate > 5%",            "conditionName": "Error rate > 5%",            "fired":  89 },
  { "facet": "Apdex score < 0.7",          "conditionName": "Apdex score < 0.7",          "fired":  31 }
]
```

### Save As

```
account_<ACCOUNT_ID>/_usage_analytics/alerts_most_fired.json
```

### Notes

- `NrAiIncident` is the event type for the **Applied Intelligence** incident pipeline. If your account uses legacy alerts that have not been migrated, no data will appear and the file will be `[]` — which is valid input for the DMA App.
- `conditionName` is the user-friendly condition title, not the internal ID. The DMA App will match this back to entries in `account_<id>/alerts/nrql_conditions.json` by name.

---

## Query 3 — Most Active Users

Top 50 users by audit-event count. Helps prioritize which user accounts must be migrated to Dynatrace IAM and which can be deactivated.

### NRQL

```sql
SELECT count(*) AS 'actions'
FROM NrAuditEvent
FACET actorEmail
LIMIT 50
SINCE 90 days ago
```

### Expected Output Shape

```json
[
  { "facet": "alice@example.com",   "actorEmail": "alice@example.com",   "actions": 1872 },
  { "facet": "bob@example.com",     "actorEmail": "bob@example.com",     "actions":  944 },
  { "facet": "ci-bot@example.com",  "actorEmail": "ci-bot@example.com",  "actions":  632 }
]
```

### Save As

```
account_<ACCOUNT_ID>/_usage_analytics/users_most_active.json
```

### Notes

- `actorEmail` may be empty for service-account or token-based actions. Those rows are still valid — keep them in the JSON; the DMA App handles empty actors.
- This file contains PII. Treat it the same way you treat the `_rbac/users.json` file — gate on internal data-handling policy before sharing the archive externally. Use `--anonymize` to produce a SHA-256-masked copy.

---

## Query 4 — Ingest by Data Type

Daily ingest in GB by event type. Used to estimate Dynatrace Grail storage cost for the migrated environment.

### NRQL

```sql
SELECT bytecountestimate() / 1e9 AS 'daily_gb'
FROM NrConsumption
WHERE usageMetric = 'EventsBytes'
FACET metric
SINCE 30 days ago
LIMIT MAX
```

### Expected Output Shape

```json
[
  { "facet": "Transaction",       "metric": "Transaction",       "daily_gb": 142.7 },
  { "facet": "PageView",          "metric": "PageView",          "daily_gb":  31.2 },
  { "facet": "MobileSession",     "metric": "MobileSession",     "daily_gb":   8.4 },
  { "facet": "BrowserInteraction","metric": "BrowserInteraction","daily_gb":   2.9 }
]
```

### Save As

```
account_<ACCOUNT_ID>/_usage_analytics/ingest_by_data_type.json
```

### Notes

- `NrConsumption` is the metering event type and has 13 months of retention regardless of plan.
- `daily_gb` is the **daily** average over the 30-day window — not the cumulative total. Multiply by 30 for the monthly equivalent.
- If the account is very new (less than 24 hours old), this query may return no rows. Wait at least one full day after first ingest before running.

---

## Inserting Manual Files into the Archive

Once you have all four files, drop them into the existing archive structure:

```bash
# Extract the archive the script produced
tar -xzf dma_export_newrelic_20260430T203012Z.tar.gz
cd dma_export_newrelic_20260430T203012Z

# Create the analytics directory if missing
mkdir -p account_1234567/_usage_analytics

# Place the four files
mv ~/Downloads/dashboard_views_top100.json account_1234567/_usage_analytics/
mv ~/Downloads/alerts_most_fired.json       account_1234567/_usage_analytics/
mv ~/Downloads/users_most_active.json       account_1234567/_usage_analytics/
mv ~/Downloads/ingest_by_data_type.json     account_1234567/_usage_analytics/

# Re-tar
cd ..
tar -czf dma_export_newrelic_20260430T203012Z_with_analytics.tar.gz dma_export_newrelic_20260430T203012Z
```

### Optional: Update the Manifest

The DMA App reads the manifest to determine which sections are present. If you added analytics manually after the script ran, also update `manifest.json`:

```bash
jq '.export_summary.usage_analytics_files = 4' \
   dma_export_newrelic_20260430T203012Z/manifest.json > /tmp/m.json
mv /tmp/m.json dma_export_newrelic_20260430T203012Z/manifest.json
```

The DMA App is tolerant — it will still process the analytics files even if the manifest count disagrees, but keeping it accurate avoids confusing reconciliation later.

---

## Permission Requirements

Each query needs **insights query access** for the relevant event types:

| Query | Required Permission | Where to Grant |
|---|---|---|
| Queries 1, 3 (`NrAuditEvent`) | "Insights queries: Query data" + access to internal events | Administration → Access management → Roles |
| Query 2 (`NrAiIncident`)      | Applied Intelligence read access                          | Administration → Access management → Roles |
| Query 4 (`NrConsumption`)     | Org-level metering read                                   | Account owners only on most plans |

If `--usage` returned `Auth error` for a specific query, the most likely fix is to add the corresponding permission to the role used by your User API Key — then re-run the script with `--usage`. Manual execution from this document is only necessary if the permission cannot be granted (e.g., compliance restrictions on `NrAuditEvent`).

---

## What If a Query Returns Nothing?

A query returning `[]` (empty array) is **not** an error — it's a valid result that means "no events in the time window match." Save the empty array to the file anyway:

```bash
echo '[]' > account_1234567/_usage_analytics/dashboard_views_top100.json
```

The DMA App handles empty analytics files cleanly — that section will simply be empty in the migration report. This is preferable to omitting the file entirely, which the manifest validator may flag as a missing artifact.

### Common reasons a query returns empty

- **Account is too new.** No events exist in the 90-day window.
- **Audit logging is disabled or sampled.** `NrAuditEvent` is sample-rate-limited on lower plans.
- **Wrong account.** The NRQL Editor's account selector defaults to your home account; if your dashboards live in a sub-account, switch the selector.
- **Time skew.** `SINCE 90 days ago` is wall-clock relative — if you ran the export and the manual queries days apart, the windows differ slightly. Not a problem in practice.

---

## See Also

- [README-NEWRELIC.md](README-NEWRELIC.md) — Setup and permission requirements
- [INTERACTIVE-WALKTHROUGH.md](INTERACTIVE-WALKTHROUGH.md) — Full first-run walkthrough including `--test-access`
- [SCRIPT-GENERATED-ANALYTICS-REFERENCE.md](SCRIPT-GENERATED-ANALYTICS-REFERENCE.md) — Detailed reference for what the analytics files mean and how the DMA App consumes them
- [EXPORT-SCHEMA.md](EXPORT-SCHEMA.md) — Full archive schema
