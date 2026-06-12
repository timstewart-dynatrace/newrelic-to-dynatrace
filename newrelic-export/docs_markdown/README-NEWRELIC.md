# DMA New Relic Export — Setup Guide

Complete prerequisites, permissions, and troubleshooting guide for running the New Relic export scripts.

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [API Key Setup](#api-key-setup)
3. [Required Permissions](#required-permissions)
4. [Finding Your Account IDs](#finding-your-account-ids)
5. [Running the Export](#running-the-export)
6. [Export Options Reference](#export-options-reference)
7. [Network Requirements](#network-requirements)
8. [Troubleshooting](#troubleshooting)
9. [Known Limitations](#known-limitations)

---

## Prerequisites

### Bash Script (Linux / macOS)

| Requirement | Minimum Version | Check | Install |
|---|---|---|---|
| bash | 3.2+ | `bash --version` | Pre-installed on macOS/Linux |
| curl | 7.0+ | `curl --version` | Pre-installed on macOS/Linux |
| jq | 1.5+ | `jq --version` | `brew install jq` (macOS) / `apt-get install jq` (Linux) |
| tar | any | `tar --version` | Pre-installed on macOS/Linux |
| Disk space | 500MB+ free | `df -h .` | — |

> The script targets bash 3.2 (default on macOS) and works with `set -o pipefail` only — no need to install bash 5.

### PowerShell Script (Windows / Cross-platform)

| Requirement | Minimum Version | Check |
|---|---|---|
| PowerShell | 5.1+ (Windows) or 7.0+ (cross-platform) | `$PSVersionTable.PSVersion` |
| Disk space | 500MB+ free | — |

No additional dependencies required — all JSON handling uses built-in PowerShell cmdlets.

---

## API Key Setup

You need a **New Relic User API Key** (`NRAK-...`). This is different from:
- License keys (`NRLA-...`) — ingest only, cannot query configurations
- Browser keys (`NRBA-...`) — browser monitoring only

### Creating a User API Key

1. Log in to New Relic at [one.newrelic.com](https://one.newrelic.com)
2. Click your user icon (bottom left) → **API keys**
3. Click **Create a key**
4. Set:
   - **Key type:** User
   - **Account:** Any account you have access to
   - **Name:** `dma-export` (or similar)
5. Copy the key — it is only shown once

### Using the API Key

Pass via `--api-key` flag:

```bash
./dma-newrelic-export.sh --api-key "NRAK-XXXXXXXXXXXXXXXXXXXX" ...
```

Or via environment variable (avoids key appearing in shell history):

```bash
export NR_API_KEY="NRAK-XXXXXXXXXXXXXXXXXXXX"
./dma-newrelic-export.sh --api-key "$NR_API_KEY" ...
```

---

## Required Permissions

The API key must belong to a user with sufficient permissions on each account being exported.

### Minimum Required Roles

| Resource | Required Permission |
|---|---|
| Dashboards | `Read` on Dashboards |
| Alert policies | `Read` on Alerts |
| Alert conditions | `Read` on Alerts |
| Synthetic monitors | `Read` on Synthetics |
| Workloads | `Read` on Workloads |
| Service levels | `Read` on Service Levels |
| Users & groups (`--rbac`) | **Organization Manager** or **Authentication Domain Manager** |
| Usage analytics (`--usage`) | `Read` on NRQL (access to `NrAuditEvent`, `NrConsumption`) |

### Recommended Role

For the simplest setup, assign the **Admin** role on each account. This covers all resources without individual permission configuration.

---

## Finding Your Account IDs

### Method 1 — Auto-discovery

Omit `--accounts` and the script will query all accounts your API key has access to:

```bash
./dma-newrelic-export.sh --api-key "$NR_API_KEY" --all
```

### Method 2 — New Relic UI

1. Log in to [one.newrelic.com](https://one.newrelic.com)
2. Click your account name (top left)
3. Account IDs are listed in the account switcher

### Method 3 — NerdGraph query

```bash
curl -s -X POST https://api.newrelic.com/graphql \
  -H "Content-Type: application/json" \
  -H "API-Key: $NR_API_KEY" \
  -d '{"query":"{ actor { accounts { id name } } }"}' \
  | jq .
```

---

## Running the Export

### Minimal Export (dashboards and alerts only)

```bash
./dma-newrelic-export.sh \
  --api-key "$NR_API_KEY" \
  --accounts "1234567" \
  --dashboards --alerts
```

### Full Export

```bash
./dma-newrelic-export.sh \
  --api-key "$NR_API_KEY" \
  --accounts "1234567" \
  --all
```

### Full Export with RBAC and Usage Analytics

```bash
./dma-newrelic-export.sh \
  --api-key "$NR_API_KEY" \
  --accounts "1234567" \
  --all --rbac --usage
```

### Multiple Accounts

```bash
./dma-newrelic-export.sh \
  --api-key "$NR_API_KEY" \
  --accounts "1234567,8901234,5678901" \
  --all
```

### EU Region

```bash
./dma-newrelic-export.sh \
  --api-key "$NR_API_KEY" \
  --accounts "1234567" \
  --all --region EU
```

### Debug Mode (verbose logging)

```bash
./dma-newrelic-export.sh \
  --api-key "$NR_API_KEY" \
  --accounts "1234567" \
  --dashboards --debug
```

---

## Export Options Reference

| Flag | PowerShell | Default | Description |
|---|---|---|---|
| `--api-key KEY` | `-ApiKey KEY` | required | New Relic User API Key |
| `--accounts IDS` | `-Accounts IDS` | auto-discover | Comma-separated account IDs |
| `--region REGION` | `-Region REGION` | `US` | `US` or `EU` |
| `--all` | `-All` | off | Dashboards + alerts + synthetics + workloads + service levels |
| `--dashboards` | `-Dashboards` | off | Export dashboards |
| `--alerts` | `-Alerts` | off | Export alert policies and NRQL conditions |
| `--synthetics` | `-Synthetics` | off | Export synthetic monitors |
| `--workloads` | `-Workloads` | off | Export workloads |
| `--service-levels` | `-ServiceLevels` | off | Export service level indicators |
| `--rbac` | `-Rbac` | off | Users and groups (contains PII) |
| `--usage` | `-Usage` | off | Usage analytics (NRQL queries on audit data) |
| `--anonymize` | `-Anonymize` | off | Also produce SHA-256 masked archive |
| `--output-dir DIR` | `-OutputDir DIR` | `/tmp/dma_newrelic_...` | Custom working directory |
| `--debug` | `-Debug` | off | Verbose logging |
| `--help` | `-Help` | — | Show usage |

---

## Network Requirements

The scripts only require outbound HTTPS (port 443) to the NerdGraph endpoint:

| Region | Hostname | Port |
|---|---|---|
| US | `api.newrelic.com` | 443 |
| EU | `api.eu.newrelic.com` | 443 |

### Corporate Proxy

If your environment requires a proxy, set standard environment variables before running:

```bash
export HTTPS_PROXY="https://proxy.example.com:8080"
./dma-newrelic-export.sh ...
```

PowerShell uses system proxy settings by default. Override with:

```powershell
$env:HTTPS_PROXY = "https://proxy.example.com:8080"
.\dma-newrelic-export.ps1 ...
```

---

## Troubleshooting

### `401 Unauthorized`

The API key is invalid or expired. Verify it starts with `NRAK-` and was created as a **User** key.

### `403 Forbidden`

The API key's user lacks permissions on the requested account. Check [Required Permissions](#required-permissions).

### Empty results for a resource type

- The account may not have any resources of that type
- The user key may lack read permission for that resource
- Run with `--debug` to see the raw API responses

### `command not found: jq`

Install jq: `brew install jq` (macOS) or `apt-get install jq` (Linux). The script depends on jq for JSON parsing — there is no Python fallback.

### `$'\r': command not found` on first run (Windows)

The script was edited or downloaded with Windows CRLF line endings. The script auto-detects this and rewrites itself in place — let it complete the conversion and re-run.

### Slow export on large environments

Normal. Each resource type requires paginated API calls. A 500-dashboard account may take 2–5 minutes. Use `--debug` to monitor progress.

---

## Known Limitations

| Limitation | Detail |
|---|---|
| Legacy notification channels | Old-style notification channels (pre-2022) are in REST API v2 only — not exported |
| APM alert conditions | Only NRQL-based conditions are exported; APM metric conditions require REST API v2 |
| Dashboard permissions | Private dashboards owned by other users may return empty widgets |
| Synthetic scripted monitors | Script source code is not returned by the entity search API |
| Usage analytics accuracy | `NrAuditEvent` retention varies by account tier (typically 30–90 days) |
