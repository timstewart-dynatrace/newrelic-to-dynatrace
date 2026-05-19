# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.4] - 2026-05-05

### Fixed

- **`--region` flag now works on macOS default bash (3.2)** (sh only). The argument parser used `REGION="${2^^}"`, a bash 4+ parameter expansion for uppercasing. macOS ships bash 3.2 as `/bin/bash`; running the script with `--region us` produced no uppercase conversion and downstream endpoint selection silently fell through to defaults. The pre-flight checklist already claims `bash 3.2+` support, so the bug was a divergence from the declared support matrix. Replaced with `REGION=$(printf '%s' "$2" | tr '[:lower:]' '[:upper:]')` — POSIX-compatible, identical behavior on bash 4+. PowerShell port unaffected (case-insensitive parameter binding is native to PowerShell).

## [1.0.3] - 2026-05-08

### Fixed

- **`json_merge_arrays` no longer silently drops large batches** (sh only). The helper used `jq -n --argjson a "$1" --argjson b "$2"` to merge two JSON arrays — `--argjson` passes values via the command line, which is bounded by `ARG_MAX` (~256KB on Linux, ~1MB on macOS). Real-world dashboard exports can return per-batch payloads of several MB once `widget.rawConfiguration` is included, blowing past `ARG_MAX`. The original `2>/dev/null || echo "$1"` fallback then silently returned the first (empty) array, producing an export that reported `Exported 0 dashboards` while the entitySearch-then-batch-fetch logic correctly retrieved 24 dashboard details. Rewrote the helper to pipe both arrays via stdin (`printf | jq -s 'add'`) — no command-line size limit. Same fallback semantics. PowerShell port unaffected (uses native arrays, no shell-arg-size constraint).
- Discovered while exporting an account with 5 terraform-managed dashboards plus their auto-generated child page entities (24 dashboard entities total). Verified post-fix: `Exported 24 dashboards`, tarball size 13KB vs the previous 5KB silent-empty.

## [1.0.2] - 2026-05-05

### Fixed

- **Manifest schema now satisfies `@dma/newrelic-converter` `ManifestParser`.** The DMA New Relic App rejected uploaded archives with `Invalid manifest: Manifest missing "version" field`, then would have rejected for missing `exportedAt`, then `accounts[].region`, then `counts`. The exporter emitted `schema_version`/`export_timestamp`/nested `statistics` and accounts without per-account region. Both `generate_manifest()` (sh) and `Generate-Manifest` (ps1) now emit both naming conventions side-by-side: legacy fields preserved (back-compat for any v1.0.1 reader), plus `version`, `exportedAt`, `accounts[].region`, flattened `counts`, and `files[]` (relative paths under output dir, manifest and log excluded).

## [1.0.1] - 2026-04-22

### Fixed

- **NerdGraph `entitySearch` schema compatibility** — `entitySearch.results.entities` returns `*EntityOutline` types, not the full entity types. Spreading `... on DashboardEntity`/`SyntheticMonitorEntity`/`WorkloadEntity` against the outline union silently returned no fields. Reworked dashboard, synthetic monitor, workload, and service-level indicator exports into a two-phase fetch: `entitySearch` enumerates GUIDs, then `actor.entities(guids:)` (batched at 25 per call) retrieves full details.
- **Service level indicators now discoverable** — SLIs live on `Entity.serviceLevel.indicators`, not on `Account.serviceLevel`. Rewrote the SLI export to probe all entities in an account and collect any that expose an SLI.
- **RBAC export failing with "filter required"** — `customerAdministration.users` now requires `filter: { authenticationDomainId: { eq: ... } }` and `customerAdministration.groups` requires `filter: { organizationId: { eq: ... } }`. Response collection renamed from `users`/`groups` to `items`. Script now discovers the organization id and iterates auth domains before fetching users.
- **Alert NRQL condition query schema** — removed interface-level queries for `terms`/`signal`/`valueFunction`/`violationTimeLimitSeconds` that are only valid on concrete `AlertsNrqlStaticCondition`/`AlertsNrqlBaselineCondition` types. Query now reads only `AlertsNrqlCondition` interface fields; concrete-type detail can be added once each type's schema is verified against live NerdGraph.
- **Empty GraphQL argument lists rejected** — `policiesSearch()` and `nrqlConditionsSearch()` with empty parens returned parse errors. First-page calls now omit the parens entirely.
- **`head -n -N` incompatible with macOS/BSD coreutils** — HTTP response splitting in `nerdgraph_query` replaced `head -n -1` with `sed '$d'` so the Bash script works on macOS.
- **`log_info` and `log_debug` polluting stdout** — helper functions that are invoked inside `$(...)` captures were writing logs to stdout, which got captured into JSON strings. All log functions now route to stderr.
- **Staging directory deleted before final log lines** — `rm -rf "$OUTPUT_DIR"` moved from `create_archive` to the tail of `main()` so completion logging runs before cleanup.
- **PowerShell strict-mode property access errors** — `$response.errors` now probed via `psobject.Properties['errors']` before read; `$_.Exception.Response?.StatusCode?.value__` replaced with a `try/catch` cast for PowerShell 5.1 compatibility.
- **PowerShell `$AccountIdList` collapsing to scalar** — forced array context with `@(...)` around the split so a single comma-less account value doesn't break `.Count` under `Set-StrictMode`.
- **PowerShell JSON serialization of single-item arrays** — `Save-Json` now normalizes empty/single/multi-item collections explicitly (using `-AsArray` for single items) so PowerShell and Bash archives stay byte-compatible.

### Added

- `ENTITY_FETCH_BATCH` / `$EntityFetchBatch` constant (25) — documented batch size for `actor.entities(guids:)` calls.

## [1.0.0] - 2026-04-21

### Added
- Initial release of DMA New Relic Export tool
- Bash export script (`dma-newrelic-export.sh`) for Linux/macOS
- PowerShell export script (`dma-newrelic-export.ps1`) for Windows and cross-platform
- NerdGraph (GraphQL) API integration with cursor-based pagination
- Dashboard export including widget definitions, NRQL queries, and layout
- Alert policy and NRQL condition export with full threshold and signal configuration
- Notification destinations, channels, and AI workflow export
- Synthetic monitor export (browser and scripted API monitors)
- Workload export with entity scope and account relationships
- Service level indicator/objective export
- User and group (RBAC) export via `customerAdministration` API (opt-in)
- Usage analytics generation via NRQL audit queries (opt-in):
  - `dashboard_views_top100.json` — Top viewed dashboards (90 days)
  - `alerts_most_fired.json` — Most fired alert conditions (90 days)
  - `users_most_active.json` — Most active users (90 days)
  - `ingest_by_data_type.json` — Data ingestion by event type (30 days)
- US and EU region support
- Automatic account discovery when no `--accounts` specified
- Retry logic with exponential backoff for API failures
- 50ms rate limiting between paginated requests
- `manifest.json` generation with per-account export statistics
- Human-readable `dma-env-summary.md` with migration guidance
- `--anonymize` flag for producing a second SHA-256-masked export archive
- `--debug` verbose logging mode
- Schema version 1.0 export archive format
- Full documentation suite:
  - `docs_markdown/README-NEWRELIC.md` — Setup guide and prerequisites
  - `docs_markdown/EXPORT-SCHEMA.md` — Archive format specification
  - `docs_markdown/SCRIPT-GENERATED-ANALYTICS-REFERENCE.md` — Analytics files reference
