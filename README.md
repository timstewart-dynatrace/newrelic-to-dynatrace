# DMA New Relic Export Script

**Version**: 1.3.6
**Last Updated**: August 2026

> **Developed for Dynatrace One by Enterprise Solutions & Architecture**
> *An ACE Services Division of Dynatrace*

---

## Overview

`dma-newrelic-export.sh` (and `.ps1`) extracts dashboards, alert policies, NRQL conditions, synthetic monitors, workloads, service level indicators, and usage analytics from New Relic accounts via the NerdGraph GraphQL API. The export archive powers the **Dynatrace Migration Assistant (DMA)** — feeding the **DMA New Relic App** for migration planning, dashboard translation, and New Relic-to-Dynatrace conversion workflows.

As of **v1.2.0** the exporter also captures the 8 supplemental object types that used to live in the standalone `nr-supplemental-export.sh` (incident/AI workflows, notification destinations, muting rules, drop rules, log parsing rules, lookup tables, events-to-metrics rules, entity tags). They are now part of the single `dma_export_newrelic_<timestamp>.tar.gz` archive — written to `account_<id>/supplemental/` and recorded under the `supplemental` block of `manifest.json`. They opt in exactly like the core types: `--all` captures them along with everything else, `--supplemental` enables the whole group, or `--<type>` enables one (e.g. `--drop-rules`); subtract from `--all` with `--no-<type>` (e.g. `--no-drop-rules`) or `--no-supplemental`. The separate supplemental script has been removed.

As of **v1.3.0** the exporter emits **one archive per account** — `dma_export_newrelic_<account_id>_<timestamp>.tar.gz` for each account in the run — instead of a single combined multi-account archive. The DMA treats a New Relic account as a Dynatrace-tenant-equivalent (its own org/team/environment, e.g. prod vs nonprod), so each account is a distinct migration scope/target: **import each archive into the DMA New Relic App as its own project.** Each per-account archive contains exactly one `account_<id>/` tree + a single-account `manifest.json` (with exact per-account `counts`) and the shared `_systeminfo`/summary/log, so it stands alone. (A multi-account run simply produces multiple files.)

> **PowerShell note:** the `.ps1` Windows port does **not** yet include the 8 supplemental object types (v1.2.0) or the per-account archive split (v1.3.0) — that parity work is a separate follow-up.

---

## Before You Begin

### Prerequisites

| Requirement | Detail |
|-------------|--------|
| **Platform** | Linux, macOS, or WSL |
| **Shell** | bash 3.2+ (works with macOS default bash) |
| **curl** | `curl --version` to verify |
| **jq** | `jq --version` to verify — install with `brew install jq` (macOS) or `apt-get install jq` (Linux) |
| **tar** | `tar --version` to verify |
| **Network** | HTTPS access to `api.newrelic.com/graphql` (US) or `api.eu.newrelic.com/graphql` (EU) |
| **Disk space** | 500 MB+ free in the working directory |

### Where to Run

The script runs from **any machine with internet access** to the New Relic NerdGraph API — your laptop, a jump host, or a CI/CD runner. No access to New Relic infrastructure is required.

---

## CRITICAL: API Key and Permissions

**Using the wrong API key type is the most common cause of authentication failures.**

### What You Need

| Credential | Where to Generate | Type |
|------------|-------------------|------|
| **User API Key** | Account Settings → API keys → Create a key | Must be **User key** (not Ingest - License key) |

The key must begin with `NRAK-`. Keys beginning with other prefixes will not work.

### Credential Sources

The bash script accepts credentials three ways, highest precedence first:

1. **CLI flags** — `--api-key`, `--accounts`, `--region`
2. **Environment variables** — `NEW_RELIC_USER_API_KEY`, `NEW_RELIC_ACCOUNT_ID`, `NEW_RELIC_REGION`
3. **`.env` file** — same variable names; the current directory is checked first, then the repo root

Never commit a `.env` file — it is git-ignored for this reason.

### Required Permissions

The User API Key must belong to a user with **Full Platform Access** or **Admin** role to export all data types. Reduced permissions will cause some exports to return empty results without an error.

| Permission | What It Exports |
|------------|----------------|
| Full Platform Access | Dashboards, alerts, synthetics, workloads, service levels |
| Admin (in addition) | RBAC users and groups (`--rbac` flag) |

### Connectivity Test

Run this to verify your key works before a full export:

```bash
curl -s -X POST https://api.newrelic.com/graphql \
  -H "Content-Type: application/json" \
  -H "API-Key: NRAK-your-key-here" \
  -d '{"query":"{ actor { user { name email } } }"}' | jq .
```

Expected: JSON with your user name and email.

---

## Quick Start

### Bash (Linux / macOS / WSL)

```bash
chmod +x newrelic-export/dma-newrelic-export.sh

./newrelic-export/dma-newrelic-export.sh \
  --api-key "NRAK-XXXXXXXXXXXXXXXXXXXX" \
  --accounts "1234567" \
  --all
```

### PowerShell (Windows / Cross-platform)

```powershell
.\newrelic-export\dma-newrelic-export.ps1 `
  -ApiKey "NRAK-XXXXXXXXXXXXXXXXXXXX" `
  -Accounts "1234567" `
  -All
```

Both scripts produce an identical `.tar.gz` archive that can be uploaded directly to the DMA New Relic App in your Dynatrace tenant.

---

## Export Options

| Bash Flag | PowerShell Flag | Description | Default |
|---|---|---|---|
| `--all` | `-All` | Export dashboards, alerts, synthetics, workloads, service levels | off |
| `--dashboards` | `-Dashboards` | Dashboards and NRQL widget queries | off |
| `--alerts` | `-Alerts` | Alert policies and NRQL conditions | off |
| `--synthetics` | `-Synthetics` | Synthetic monitor configurations | off |
| `--workloads` | `-Workloads` | Workload configurations | off |
| `--service-levels` | `-ServiceLevels` | Service level indicators (SLOs) | off |
| `--rbac` | `-Rbac` | Users and groups (contains PII — opt-in) | off |
| `--usage` | `-Usage` | Usage analytics via NRQL audit queries (opt-in) | off |
| `--region US\|EU` | `-Region US\|EU` | API region (default: US) | US |
| `--accounts IDs` | `-Accounts IDs` | Comma-separated account IDs (auto-discovers if omitted) | auto |
| `--anonymize` | `-Anonymize` | Also produce a SHA-256 masked archive | off |
| `--output-dir DIR` | `-OutputDir DIR` | Custom working directory | system temp |
| `--debug` | `-DebugMode` | Verbose logging | off |

---

## Output Archive Structure

```
dma_export_newrelic_YYYYMMDDTHHMMSSZ.tar.gz
├── manifest.json                          # Master index with statistics
├── dma-env-summary.md                     # Human-readable summary
├── export.log                             # Execution log
├── _systeminfo/
│   ├── environment.json                   # Host metadata
│   └── accounts.json                      # Account inventory
├── _rbac/                                 # Optional: users & groups
│   ├── users.json
│   └── groups.json
└── account_{ID}/
    ├── dashboards/
    │   └── dashboards.json                # Full dashboard + widget JSON
    ├── alerts/
    │   ├── policies.json                  # Alert policy definitions
    │   ├── nrql_conditions.json           # NRQL alert conditions with queries
    │   └── notification_channels.json     # Destinations and channels
    ├── synthetics/
    │   └── monitors.json                  # Synthetic monitor configurations
    ├── workloads/
    │   └── workloads.json                 # Workload entity definitions
    ├── service_levels/
    │   └── indicators.json                # SLI/SLO definitions
    └── _usage_analytics/                  # Optional: usage data
        ├── dashboard_views.json
        ├── alerts_most_fired.json
        ├── users_most_active.json
        └── ingest_by_data_type.json
```

---

## Examples

```bash
# All data, single account
./dma-newrelic-export.sh --api-key "NRAK-XXX" --accounts "1234567" --all

# Dashboards and alerts only
./dma-newrelic-export.sh --api-key "NRAK-XXX" --accounts "1234567" --dashboards --alerts

# Multiple accounts
./dma-newrelic-export.sh --api-key "NRAK-XXX" --accounts "1234567,8901234" --all

# Full export with RBAC and usage analytics
./dma-newrelic-export.sh --api-key "NRAK-XXX" --accounts "1234567" --all --rbac --usage

# EU region
./dma-newrelic-export.sh --api-key "NRAK-XXX" --accounts "1234567" --all --region EU

# Anonymized export (for sharing without PII)
./dma-newrelic-export.sh --api-key "NRAK-XXX" --accounts "1234567" --all --anonymize
```

---

## What Gets Exported

| Category | Contents |
|---|---|
| **Dashboards** | JSON widget definitions, NRQL queries, layout, page structure, permissions |
| **Alert Policies** | Policy names, incident preferences |
| **NRQL Conditions** | Conditions with NRQL queries, thresholds, signal configuration |
| **Notification Channels** | Destinations (webhooks, PagerDuty, etc.) and AI notification channels |
| **Synthetic Monitors** | Browser/API monitor definitions, locations, schedules |
| **Workloads** | Entity scope, account relationships, tags |
| **Service Levels** | SLI/SLO indicators, events, objectives |
| **Users & Groups** | RBAC configuration (optional, contains PII — requires `--rbac`) |
| **Usage Analytics** | Dashboard views, alert fire rates, user activity, ingest volume (optional, requires `--usage`) |

---

## Migration Mapping Reference

| New Relic | Dynatrace Gen3 |
|---|---|
| Dashboard (NRQL widgets) | Dashboard (DQL tiles) |
| NRQL query | DQL query |
| Alert policy + NRQL condition | Metric event alert or DQL-based alert |
| Synthetic monitor | Browser/HTTP monitor |
| Workload | Management Zone |
| Service level indicator | SLO |
| Notification destination | Notification integration |

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Authentication failed (HTTP 401)` | Wrong API key | Verify key starts with `NRAK-` and is a User key, not Ingest key |
| Empty export (0 dashboards, 0 alerts) | Insufficient permissions | Ensure key owner has Full Platform Access |
| `jq: command not found` | jq not installed | `brew install jq` (macOS) or `apt-get install jq` (Linux) |
| Network error (HTTP 000) | Firewall blocking API | Verify HTTPS access to `api.newrelic.com` |
| Script hangs on large account | Rate limiting | Normal — the script retries. Large accounts (1000+ dashboards) can take 15-20 min |

---

## Related Projects

| Project | Purpose |
|---|---|
| `dma-nrql-translator` | `@dma/nrql-translator` — NRQL to DQL translation library |
| `dma-newrelic-converter` | `@dma/newrelic-converter` — converts export archive to Dynatrace artifacts |
| `dma-newrelic-app` | Dynatrace AppEngine migration UI (`my.dma.newrelic.app`) |
| `dynabridge-for-newrelic` | Earlier version — superseded by this project |
