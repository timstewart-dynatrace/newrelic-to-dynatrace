# Export Archive Schema — v1.0

Specification for the `.tar.gz` archive produced by the DMA New Relic Export scripts.

---

## Archive Naming

```
dma_export_newrelic_YYYYMMDDTHHMMSSZ.tar.gz
```

Example: `dma_export_newrelic_20260421T140523Z.tar.gz`

When `--anonymize` is used, a second masked archive is produced:

```
dma_export_newrelic_20260421T140523Z_masked.tar.gz
```

---

## Archive Structure

```
dma_export_newrelic_TIMESTAMP/
├── manifest.json                          # Master index (always present)
├── dma-env-summary.md              # Human-readable summary (always present)
├── export.log                             # Execution log (always present)
├── _systeminfo/
│   ├── environment.json                   # Host and script metadata
│   └── accounts.json                      # All accessible accounts
├── _rbac/                                 # Only with --rbac
│   ├── users.json
│   └── groups.json
└── account_<ACCOUNT_ID>/                  # One directory per exported account
    ├── dashboards/                        # Only with --dashboards or --all
    │   └── dashboards.json
    ├── alerts/                            # Only with --alerts or --all
    │   ├── policies.json
    │   ├── nrql_conditions.json
    │   └── notification_channels.json
    ├── synthetics/                        # Only with --synthetics or --all
    │   └── monitors.json
    ├── workloads/                         # Only with --workloads or --all
    │   └── workloads.json
    ├── service_levels/                    # Only with --service-levels or --all
    │   └── indicators.json
    └── _usage_analytics/                  # Only with --usage
        ├── dashboard_views_top100.json
        ├── alerts_most_fired.json
        ├── users_most_active.json
        └── ingest_by_data_type.json
```

---

## manifest.json

Master index file. Always present.

```json
{
  "schema_version": "1.0",
  "export_tool_version": "1.0.0",
  "export_tool": "dma-newrelic-export",
  "export_timestamp": "2026-04-21T14:05:23Z",
  "export_end_timestamp": "2026-04-21T14:07:41Z",
  "source_system": {
    "platform": "New Relic",
    "region": "US",
    "account_ids": ["1234567", "8901234"]
  },
  "export_options": {
    "dashboards": true,
    "alerts": true,
    "synthetics": true,
    "workloads": true,
    "service_levels": true,
    "rbac": false,
    "usage_analytics": false
  },
  "statistics": {
    "accounts": 2,
    "account_1234567": {
      "dashboards": 142,
      "alert_policies": 23,
      "nrql_conditions": 87,
      "synthetic_monitors": 34,
      "workloads": 5,
      "service_level_indicators": 12
    },
    "account_8901234": {
      "dashboards": 67,
      "alert_policies": 11,
      "nrql_conditions": 44,
      "synthetic_monitors": 8,
      "workloads": 2,
      "service_level_indicators": 3
    }
  },
  "accounts": [
    { "id": 1234567, "name": "Production" },
    { "id": 8901234, "name": "Staging" }
  ]
}
```

---

## _systeminfo/environment.json

```json
{
  "export_timestamp": "2026-04-21T14:05:23Z",
  "export_tool": "dma-newrelic-export",
  "export_tool_version": "1.0.0",
  "host": {
    "os": "Linux",
    "os_version": "#1 SMP ...",
    "hostname": "export-host-01"
  }
}
```

---

## _systeminfo/accounts.json

Array of all New Relic accounts accessible to the API key.

```json
[
  { "id": 1234567, "name": "Production" },
  { "id": 8901234, "name": "Staging" },
  { "id": 5678901, "name": "Development" }
]
```

---

## account_ACCOUNTID/dashboards/dashboards.json

Array of dashboard entities from NerdGraph `entitySearch(type='DASHBOARD')`.

```json
[
  {
    "guid": "MTIzNDU2N3xWSVp8REFTSEJPQVJEFDE",
    "name": "Application Overview",
    "description": "Golden signals for the checkout services",
    "accountId": 1234567,
    "createdAt": "2024-03-15T10:22:00Z",
    "updatedAt": "2025-11-02T08:45:00Z",
    "permissions": "PUBLIC_READ_WRITE",
    "owner": {
      "email": "user@example.com",
      "userId": 4567890
    },
    "variables": [
      {
        "name": "services",
        "title": "Services",
        "type": "NRQL",
        "isMultiSelection": true,
        "replacementStrategy": "STRING",
        "defaultValues": [ { "value": { "string": "*" } } ],
        "items": null,
        "nrqlQuery": {
          "accountIds": [1234567],
          "query": "FROM Transaction SELECT uniques(appName) SINCE 1 day ago"
        },
        "options": {
          "excluded": false,
          "hiddenOnVariablesBar": false,
          "ignoreTimeRange": false,
          "showApplyAction": false
        }
      },
      {
        "name": "severity",
        "title": "Severity",
        "type": "ENUM",
        "isMultiSelection": null,
        "replacementStrategy": "STRING",
        "defaultValues": [ { "value": { "string": "ERROR" } } ],
        "items": [ { "title": "Error", "value": "ERROR" }, { "title": "Warn", "value": "WARN" } ],
        "nrqlQuery": null,
        "options": { "excluded": false, "hiddenOnVariablesBar": false, "ignoreTimeRange": false, "showApplyAction": false }
      }
    ],
    "pages": [
      {
        "guid": "MTIzNDU2N3xWSVp8REFTSEJPQVJEFDE_page1",
        "name": "Overview",
        "description": null,
        "widgets": [
          {
            "id": "widget-1",
            "title": "Transaction Throughput",
            "layout": { "row": 1, "column": 1, "height": 3, "width": 4 },
            "visualization": { "id": "viz.line" },
            "rawConfiguration": {
              "nrqlQueries": [
                {
                  "accountIds": [1234567],
                  "query": "SELECT rate(count(*), 1 minute) FROM Transaction TIMESERIES"
                }
              ]
            }
          }
        ]
      }
    ],
    "tags": [
      { "key": "team", "values": ["platform"] }
    ]
  }
]
```

Widget queries reference variables as `{{name}}`. `type` is `NRQL`, `ENUM` or `STRING`;
`replacementStrategy` is `DEFAULT`, `IDENTIFIER`, `NUMBER` or `STRING`.

`description` and `variables` are exported from v1.3.8 (`.ps1` v1.0.4). In earlier archives,
widget queries keep their `{{name}}` placeholders but the variable definitions are missing.

---

## account_ACCOUNTID/alerts/policies.json

```json
[
  {
    "id": "123456",
    "name": "Production Critical",
    "incidentPreference": "PER_CONDITION_AND_TARGET"
  }
]
```

`incidentPreference` values: `PER_POLICY`, `PER_CONDITION`, `PER_CONDITION_AND_TARGET`

---

## account_ACCOUNTID/alerts/nrql_conditions.json

```json
[
  {
    "id": "7890123",
    "name": "High Error Rate",
    "type": "STATIC",
    "enabled": true,
    "description": "Fires when error rate exceeds 5% for 5 minutes",
    "policyId": "123456",
    "runbookUrl": "https://wiki.example.com/runbooks/high-error-rate",
    "nrql": {
      "query": "SELECT percentage(count(*), WHERE error IS true) FROM Transaction WHERE appName = 'my-app'"
    },
    "signal": {
      "aggregationWindow": 60,
      "aggregationMethod": "EVENT_FLOW",
      "aggregationDelay": null,
      "aggregationTimer": null,
      "fillOption": "NONE",
      "fillValue": null,
      "slideBy": null,
      "evaluationDelay": null
    },
    "terms": [
      {
        "threshold": 5.0,
        "thresholdDuration": 300,
        "thresholdOccurrences": "ALL",
        "operator": "ABOVE",
        "priority": "CRITICAL"
      }
    ],
    "violationTimeLimitSeconds": 86400,
    "expiration": {
      "closeViolationsOnExpiration": true,
      "expirationDuration": 3600,
      "openViolationOnExpiration": false
    }
  }
]
```

`type` is `STATIC`, `BASELINE` or `OUTLIER`. Type-specific fields:

- **`BASELINE`** adds `baselineDirection` (`UPPER_ONLY`, `LOWER_ONLY`, `UPPER_AND_LOWER`). Its
  `terms[].threshold` is a number of **standard deviations from the baseline**, not a value of the
  query result. Do not convert it as a static threshold.
- **`OUTLIER`** adds `expectedGroups` and `openViolationOnGroupOverlap`.

`terms`, `signal`, `type`, `runbookUrl` and `violationTimeLimitSeconds` are exported from
v1.3.7 (`.ps1` v1.0.3). Earlier archives lack them, so every threshold reads as missing.

---

## account_ACCOUNTID/alerts/notification_channels.json

```json
{
  "destinations": [
    {
      "id": "dest-uuid-1",
      "name": "PagerDuty Production",
      "type": "PAGERDUTY_ACCOUNT_INTEGRATION",
      "status": "DEFAULT",
      "isUserAuthenticated": false,
      "properties": [
        { "key": "service_key_id", "value": "pd-service-key-abc123" }
      ]
    }
  ],
  "channels": [
    {
      "id": "channel-uuid-1",
      "name": "PagerDuty Production Channel",
      "type": "PAGERDUTY_ACCOUNT_INTEGRATION",
      "destinationId": "dest-uuid-1",
      "product": "ALERTS",
      "status": "DEFAULT"
    }
  ]
}
```

---

## account_ACCOUNTID/synthetics/monitors.json

```json
[
  {
    "guid": "MTIzNDU2N3xU...",
    "name": "Production API Health Check",
    "accountId": 1234567,
    "monitorType": "SIMPLE_API",
    "period": "EVERY_5_MINUTES",
    "status": "ENABLED",
    "locations": [
      { "label": "AWS_US_EAST_1" },
      { "label": "AWS_EU_WEST_1" }
    ],
    "tags": [
      { "key": "env", "values": ["production"] }
    ]
  }
]
```

`monitorType` values: `SIMPLE`, `BROWSER`, `SCRIPT_BROWSER`, `SCRIPT_API`, `SIMPLE_API`, `CERT_CHECK`, `BROKEN_LINKS`

`period` values: `EVERY_MINUTE`, `EVERY_5_MINUTES`, `EVERY_10_MINUTES`, `EVERY_15_MINUTES`, `EVERY_30_MINUTES`, `EVERY_HOUR`, `EVERY_6_HOURS`, `EVERY_12_HOURS`, `EVERY_DAY`

---

## account_ACCOUNTID/workloads/workloads.json

```json
[
  {
    "guid": "MTIzNDU2N3xXTHxXT1JLTE9BRHwx",
    "name": "E-commerce Platform",
    "accountId": 1234567,
    "createdAt": "2024-06-01T09:00:00Z",
    "updatedAt": "2025-10-15T14:30:00Z",
    "permalink": "https://one.newrelic.com/workloads/...",
    "tags": [
      { "key": "team", "values": ["ecommerce"] }
    ],
    "description": "Checkout and catalog services",
    "entitySearchQueries": [
      { "query": "type IN ('APPLICATION', 'SERVICE') AND tags.team = 'ecommerce'" }
    ],
    "entityGuids": ["MTIzNDU2N3xBUE18QVBQTElDQVRJT058MQ"],
    "scopeAccounts": {
      "accountIds": [1234567, 8901234]
    },
    "statusConfig": {
      "automatic": {
        "enabled": true,
        "remainingEntitiesRule": {
          "rollup": { "strategy": "WORST_STATUS_WINS", "thresholdType": null, "thresholdValue": null }
        },
        "rules": [
          {
            "entitySearchQueries": [ { "query": "type = 'APPLICATION'" } ],
            "entities": [],
            "rollup": { "strategy": "BEST_STATUS_WINS", "thresholdType": "FIXED", "thresholdValue": 1 }
          }
        ]
      },
      "static": []
    }
  }
]
```

`guid`, `name`, `accountId`, `createdAt`, `updatedAt`, `permalink` and `tags` come from the
`WorkloadEntity`. The definition fields (`description`, `entitySearchQueries`, `entityGuids`,
`scopeAccounts`, `statusConfig`) come from `account.workload.collections` and are merged in by
`guid`. They are exported from v1.3.8 (`.ps1` v1.0.4). Earlier archives carry only the entity
metadata, so a workload has no membership rules. `entityGuids` lists statically added entities.
If the definitions query fails, the exporter logs a warning and writes the metadata alone.

---

## account_ACCOUNTID/service_levels/indicators.json

```json
[
  {
    "id": "sli-uuid-1",
    "name": "Checkout API Availability",
    "description": "99.9% of checkout requests succeed",
    "slug": "checkout-availability",
    "entityGuid": "MTIzNDU2N3xBUE18QVBQTElDQVRJT058...",
    "createdAt": "2024-09-01T00:00:00Z",
    "updatedAt": "2025-11-30T00:00:00Z",
    "events": {
      "accountId": 1234567,
      "validEvents": {
        "from": "Transaction",
        "where": "appName = 'checkout-service'"
      },
      "goodEvents": {
        "from": "Transaction",
        "where": "appName = 'checkout-service' AND error IS false"
      },
      "badEvents": null
    },
    "objectives": [
      {
        "name": "99.9% availability",
        "description": null,
        "target": 99.9,
        "timeWindow": {
          "rolling": {
            "count": 7,
            "unit": "DAY"
          }
        }
      }
    ]
  }
]
```

---

## _rbac/users.json

Only present with `--rbac`.

```json
[
  {
    "id": "user-uuid-1",
    "name": "Jane Smith",
    "email": "jane.smith@example.com",
    "timeZone": "America/New_York",
    "type": {
      "id": "0",
      "displayName": "Full platform"
    }
  }
]
```

---

## _rbac/groups.json

Only present with `--rbac`.

```json
[
  {
    "id": "group-uuid-1",
    "displayName": "Platform Engineers",
    "users": {
      "users": [
        { "id": "user-uuid-1", "name": "Jane Smith", "email": "jane.smith@example.com" }
      ]
    },
    "roles": {
      "roles": [
        { "roleId": "role-1", "name": "All Product Admin", "type": "ORGANIZATION", "accountId": null }
      ]
    }
  }
]
```

---

## _usage_analytics/ Files

Only present with `--usage`. See [SCRIPT-GENERATED-ANALYTICS-REFERENCE.md](SCRIPT-GENERATED-ANALYTICS-REFERENCE.md) for full descriptions.

| File | NRQL Source | Time Range |
|---|---|---|
| `dashboard_views_top100.json` | `NrAuditEvent WHERE actionIdentifier = 'dashboard.view'` | 90 days |
| `alerts_most_fired.json` | `NrAiIncident` | 90 days |
| `users_most_active.json` | `NrAuditEvent` | 90 days |
| `ingest_by_data_type.json` | `NrConsumption` | 30 days |

---

## Anonymized Archive

When `--anonymize` is used, a second archive is produced with these transformations:

| Field | Transformation |
|---|---|
| User emails | SHA-256 hash (first 16 chars) |
| Dashboard names | SHA-256 hash prefix |
| Account names | `account_<SHA-256[:8]>` |
| Hostnames | `host_<SHA-256[:8]>` |
| NRQL queries | Preserved (contains no PII by convention) |
| GUIDs | Preserved (opaque identifiers) |

The same value always maps to the same hash within a single export run, preserving relationships for analysis.
