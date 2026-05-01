# DMA New Relic Export — First-Run Walkthrough

A step-by-step walkthrough for running the export tool against a real New Relic account for the first time. Covers prerequisite setup, permission validation, a full export, and uploading the result to the DMA New Relic App.

> **Note on naming.** The Splunk equivalent of this document is `INTERACTIVE-WALKTHROUGH.md` because the Splunk Cloud script has interactive prompts. The New Relic script is **non-interactive** — every option is supplied via CLI flag — so this walkthrough shows the CLI flow with sample output instead.

---

## Table of Contents

1. [Before You Begin](#before-you-begin)
2. [Step 1 — Install Prerequisites](#step-1--install-prerequisites)
3. [Step 2 — Generate a User API Key](#step-2--generate-a-user-api-key)
4. [Step 3 — Find Your Account IDs](#step-3--find-your-account-ids)
5. [Step 4 — Run `--test-access`](#step-4--run---test-access)
6. [Step 5 — Run a Full Export](#step-5--run-a-full-export)
7. [Step 6 — Inspect the Archive](#step-6--inspect-the-archive)
8. [Step 7 — Upload to DMA](#step-7--upload-to-dma)
9. [Common Pitfalls](#common-pitfalls)

---

## Before You Begin

You will need:

| | |
|---|---|
| A New Relic account with **Full Platform** or **Admin** role | Required to read dashboards, alerts, synthetics, workloads, SLIs |
| A machine with internet access to NerdGraph | Your laptop, a jump host, or a CI runner — anywhere `curl` can reach `api.newrelic.com` |
| 5–30 minutes | Depending on account size and how many resource types you export |

You do **not** need access to New Relic's infrastructure. The script only calls the public NerdGraph API.

---

## Step 1 — Install Prerequisites

### Bash (Linux / macOS / WSL)

```bash
# macOS
brew install jq

# Debian / Ubuntu
sudo apt-get install -y jq

# Verify
bash --version    # 3.2+ (macOS default is fine)
curl --version
jq --version
tar --version
```

The script writes nothing on failure — if any of `curl`/`jq`/`tar` is missing, it prints what to install and exits.

### PowerShell (Windows / Cross-platform)

PowerShell 5.1 ships with Windows 10+ — no install needed. Verify:

```powershell
$PSVersionTable.PSVersion
```

The PowerShell script has zero external dependencies. JSON, HTTP, and archive creation all use built-in cmdlets.

---

## Step 2 — Generate a User API Key

1. Sign in at [one.newrelic.com](https://one.newrelic.com).
2. Click your user icon (bottom-left) → **API keys**.
3. Click **Create a key**.
4. Set:
   - **Key type:** `User`
   - **Account:** any account you can read
   - **Name:** `dma-export` (or similar)
5. Copy the key — it begins with `NRAK-` and is shown only once.

> **Wrong key types** — License keys (`NRLA-...`) and Browser keys (`NRBA-...`) cannot read configurations and will fail every test in Step 4. You **must** use a User key.

---

## Step 3 — Find Your Account IDs

If you skip this step, the script will auto-discover all accounts your key can see. Specifying `--accounts` explicitly is recommended for production runs so you know exactly which environments are covered.

### Option A — UI

1. In New Relic, click your user name (top-left).
2. The account switcher lists each account with its numeric ID.

### Option B — NerdGraph

```bash
curl -s -X POST https://api.newrelic.com/graphql \
  -H "Content-Type: application/json" \
  -H "API-Key: $NR_API_KEY" \
  -d '{"query":"{ actor { accounts { id name } } }"}' \
  | jq .
```

Sample response:

```json
{
  "data": {
    "actor": {
      "accounts": [
        { "id": 1234567, "name": "production" },
        { "id": 8901234, "name": "staging" }
      ]
    }
  }
}
```

---

## Step 4 — Run `--test-access`

**Always run this first on a new key.** It probes every category the export will touch and reports PASS / WARN / FAIL / SKIP without writing any files. The single most common cause of incomplete exports is permissions — this catches them up front.

### Bash

```bash
./dma-newrelic-export.sh \
  --api-key "$NR_API_KEY" \
  --accounts "1234567" \
  --test-access
```

### PowerShell

```powershell
.\dma-newrelic-export.ps1 `
  -ApiKey $env:NR_API_KEY `
  -Accounts "1234567" `
  -TestAccess
```

### Sample Output

```
  ╔══════════════════════════════════════════════════════════════════════════╗
  ║                       DMA New Relic Access Test                          ║
  ╚══════════════════════════════════════════════════════════════════════════╝

  Testing API key permissions for: https://api.newrelic.com/graphql

  +----------------------------------+--------+----------------------------------+
  | CATEGORY                         | RESULT | NOTES                            |
  +----------------------------------+--------+----------------------------------+
  | Credentials (user info)          | PASS   | 1 item(s)                        |
  | Account discovery                | PASS   | 2 item(s)                        |
  | Organization (RBAC prereq)       | PASS   | 1 item(s)                        |
  | Dashboards                       | PASS   | 47 item(s)                       |
  | Alert policies                   | PASS   | 12 item(s)                       |
  | NRQL alert conditions            | PASS   | 38 item(s)                       |
  | Synthetic monitors               | PASS   | 8 item(s)                        |
  | Workloads                        | WARN   | Reachable; no items found        |
  | NRQL queries (--usage prereq)    | PASS   | 1 item(s)                        |
  | RBAC users (--rbac prereq)       | FAIL   | Insufficient permissions         |
  +----------------------------------+--------+----------------------------------+
  | SUMMARY                           PASS:  8  WARN:  1  FAIL:  1  SKIP:  0 |
  +----------------------------------+--------+----------------------------------+

  One or more categories FAILED. Fix permissions before running a full export.
```

### How to Read the Result Codes

| Code | Meaning | Action |
|---|---|---|
| **PASS** | The key has the necessary permission and there is at least one item to read. | Nothing to do. |
| **WARN** | The key reaches the API and the API returns a valid (empty) response. | Either there are zero items of that type in the account, or the key has a partial scope. Safe to run; that section will be empty. |
| **FAIL** | HTTP 4xx, GraphQL error, or unreachable endpoint. | Fix before exporting — that category will be missing. |
| **SKIP** | A prerequisite failed (e.g. account discovery couldn't find an id). | Resolve the upstream FAIL first. |

The exit code is **0** unless any category failed (then **1**). Use this to gate CI/automation.

---

## Step 5 — Run a Full Export

Once `--test-access` shows PASS or WARN for every category you care about:

### Bash

```bash
./dma-newrelic-export.sh \
  --api-key "$NR_API_KEY" \
  --accounts "1234567" \
  --all \
  --rbac \
  --usage
```

### PowerShell

```powershell
.\dma-newrelic-export.ps1 `
  -ApiKey $env:NR_API_KEY `
  -Accounts "1234567" `
  -All `
  -Rbac `
  -Usage
```

### What `--all` Covers

`--all` enables `--dashboards`, `--alerts`, `--synthetics`, `--workloads`, and `--service-levels`. RBAC and usage analytics are opt-in — they contain PII (`--rbac`) or are slow on large accounts (`--usage`).

### Sample Output (truncated)

```
  Region:   US
  Endpoint: https://api.newrelic.com/graphql
  Output:   /tmp/dma_newrelic_export_1714521234
  Accounts: 1234567

  Processing account: 1234567
  ℹ   [Account 1234567] Exporting dashboards...
  ✓   [Account 1234567] Exported 47 dashboards (102 widgets)
  ℹ   [Account 1234567] Exporting alert policies and NRQL conditions...
  ✓   [Account 1234567] Exported 12 policies, 38 NRQL conditions
  ℹ   [Account 1234567] Exporting synthetic monitors...
  ✓   [Account 1234567] Exported 8 monitors
  ℹ   [Account 1234567] Exporting workloads...
  ✓   [Account 1234567] Exported 0 workloads
  ℹ   [Account 1234567] Exporting service level indicators...
  ✓   [Account 1234567] Exported 4 SLIs
  ℹ   [Account 1234567] Generating usage analytics...
  ✓   [Account 1234567] Generated 4 analytics files

  ℹ Exporting users and groups (RBAC)...
  ✓ Exported 24 users across 1 auth domain

  ✓ Manifest written
  ✓ Summary written
  ✓ Archive created: dma_export_newrelic_20260430T203012Z.tar.gz (412 KB)

  ✓ Export complete!
  Archive: /tmp/dma_newrelic_export_1714521234/dma_export_newrelic_20260430T203012Z.tar.gz
  Log:     /tmp/.../export.log (inside archive)

  Next step: Upload dma_export_newrelic_20260430T203012Z.tar.gz to the DMA New Relic App in Dynatrace.
```

### Expected Duration

| Account Size | Duration |
|---|---|
| <100 dashboards / <50 alerts | 30–60 seconds |
| 100–500 dashboards / 50–200 alerts | 2–5 minutes |
| 500+ dashboards / 200+ alerts | 5–15 minutes |
| `--usage` with deep audit history | +1–3 minutes |
| `--rbac` with multiple auth domains | +30 seconds per domain |

Each NerdGraph call is paginated and rate-limited at ~50ms between requests. Large accounts trade duration for safety from rate-limit rejections.

---

## Step 6 — Inspect the Archive

```bash
tar -tzf dma_export_newrelic_20260430T203012Z.tar.gz | head -20
```

```
dma_export_newrelic_20260430T203012Z/
dma_export_newrelic_20260430T203012Z/manifest.json
dma_export_newrelic_20260430T203012Z/dma-env-summary.md
dma_export_newrelic_20260430T203012Z/export.log
dma_export_newrelic_20260430T203012Z/_systeminfo/environment.json
dma_export_newrelic_20260430T203012Z/_systeminfo/accounts.json
dma_export_newrelic_20260430T203012Z/_rbac/users.json
dma_export_newrelic_20260430T203012Z/_rbac/groups.json
dma_export_newrelic_20260430T203012Z/account_1234567/dashboards/dashboards.json
dma_export_newrelic_20260430T203012Z/account_1234567/alerts/policies.json
dma_export_newrelic_20260430T203012Z/account_1234567/alerts/nrql_conditions.json
dma_export_newrelic_20260430T203012Z/account_1234567/synthetics/monitors.json
dma_export_newrelic_20260430T203012Z/account_1234567/workloads/workloads.json
dma_export_newrelic_20260430T203012Z/account_1234567/service_levels/indicators.json
dma_export_newrelic_20260430T203012Z/account_1234567/_usage_analytics/dashboard_views_top100.json
...
```

For the full schema reference, see [EXPORT-SCHEMA.md](EXPORT-SCHEMA.md).

### Quick sanity checks

```bash
# Extract and read the manifest
tar -xzf dma_export_newrelic_20260430T203012Z.tar.gz
cd dma_export_newrelic_20260430T203012Z
jq '.export_summary' manifest.json
```

```json
{
  "accounts_exported": 1,
  "dashboards": 47,
  "alert_policies": 12,
  "nrql_conditions": 38,
  "synthetic_monitors": 8,
  "workloads": 0,
  "service_level_indicators": 4,
  "users": 24
}
```

If any count is unexpectedly zero, re-run `--test-access` to diagnose permissions, or check the relevant collector's section in [`export.log`](export.log).

---

## Step 7 — Upload to DMA

1. Open Dynatrace → **DMA New Relic App** (sidebar or App Store).
2. Click **Upload export archive**.
3. Drop the `.tar.gz` file or browse to it.
4. The app validates the manifest and lists what it found. Migration planning, dashboard translation, and NRQL → DQL conversion proceed from there.

If you produced an anonymized archive with `--anonymize`, you'll have **two** files (`*.tar.gz` and `*_masked.tar.gz`). Upload the unmasked one for migration; the masked one is for sharing externally with sensitive identifiers replaced.

---

## Common Pitfalls

### `command not found: jq`

Bash script only. Install jq — there is no Python fallback. See [README-NEWRELIC.md → Prerequisites](README-NEWRELIC.md#prerequisites).

### `Auth error (HTTP 401)` on every category

The API key is wrong, expired, revoked, or of the wrong type. Common causes:

- Used a License key (`NRLA-...`) — needs a User key (`NRAK-...`).
- Used the right key but in the wrong region (US key tested against EU endpoint or vice versa).
- Pasted the key with whitespace or quotes embedded.

### Empty results for one resource type

The account may genuinely have zero of that type. Confirm by running the equivalent UI search in New Relic — e.g. for dashboards, navigate to the Dashboards page and count.

If the UI shows items but the export does not, the user role does not have read access to that resource type. Check the role's "data plane" permissions in **Administration → Access management**.

### `--rbac` returns 0 users

`customerAdministration` is gated behind the **Authentication Domain Manager** role. Only authentication-domain admins can list users via API. A regular Full Platform user cannot run `--rbac` even though they can see all dashboards/alerts.

### `--usage` is slow or partial

Usage analytics queries scan up to 90 days of `NrAuditEvent` and `NrConsumption` data. On large accounts this can take minutes. If you do not need analytics, omit `--usage` — the rest of the export does not depend on it.

### Script exits with `$'\r': command not found`

Bash script with Windows CRLF line endings. The script auto-detects this on first run and rewrites itself in place — let it complete the conversion and re-run the same command.

### Archive larger than expected

The archive contains JSON for every dashboard, alert, monitor, etc. with full widget definitions, NRQL queries, and metadata. A 47-dashboard account producing a ~400 KB archive is normal. If the archive is very large (>50 MB), the account likely has hundreds of dashboards or a `--usage` window with millions of audit events.

---

## See Also

- [README-NEWRELIC.md](README-NEWRELIC.md) — Setup, prerequisites, permission requirements
- [EXPORT-SCHEMA.md](EXPORT-SCHEMA.md) — Archive format specification
- [SCRIPT-GENERATED-ANALYTICS-REFERENCE.md](SCRIPT-GENERATED-ANALYTICS-REFERENCE.md) — Analytics file format reference
- [MANUAL-USAGE-QUERIES.md](MANUAL-USAGE-QUERIES.md) — Manual NRQL queries for cases where `--usage` returns empty results
