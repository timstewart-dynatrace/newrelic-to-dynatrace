# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **`nr-supplemental-export.sh` v0.2.0 — `.env` credential support**, ported from the main exporter: loads `NEW_RELIC_USER_API_KEY` / `NEW_RELIC_ACCOUNT_ID` / `NEW_RELIC_REGION` from a `.env` file (current directory first, then repo root) with precedence CLI flags > exported environment > `.env`. Usage text updated (env section now documents the `.env` file and comma-separated account IDs).

### Fixed

- **`nr-supplemental-export.sh`: `NEW_RELIC_REGION` was dead code** — `REGION` is initialized to `US`, so the `[[ -z "$REGION" ]]` env fallback could never fire; the env var the usage text advertised was silently ignored. Now applied whenever `--region` is not passed explicitly (`REGION_EXPLICIT` flag, same pattern as the main script).
- **`nr-supplemental-export.sh`: lowercase region rejected** — `--region eu` failed the case-sensitive `US|EU` validation. Region input is now uppercased via the same POSIX `to_upper` helper as the main script (bash 3.2-safe). Verified on bash 3.2.57.

- **`README-NEWRELIC.md` prerequisites corrected — jq, not python3** (docs only, no script change). The detailed setup guide carried over dynabridge-era instructions telling users to install python3 3.6+ and bash 5; the script actually requires jq and targets bash 3.2. Prerequisites table now lists bash 3.2+/curl/jq/tar with install commands, the NerdGraph example pipes to `jq .` instead of `python3 -m json.tool`, and troubleshooting covers `command not found: jq` plus the CRLF auto-fix instead of the obsolete python3/bash-5 entries. The root `README.md` was already correct. (Redone from abandoned-branch commit `6e62f43`, archived at `archive/feature-parity-with-splunk`.)

## [1.3.0] - 2026-06-30

### Changed

- **One archive per account (was: one combined multi-account archive).** A multi-account run now emits `dma_export_newrelic_<account_id>_<timestamp>.tar.gz` for **each** account, not a single bundle. Rationale: the DMA treats a New Relic account as a Dynatrace-tenant-equivalent (its own org/team/environment — prod vs nonprod), so each account is a distinct migration scope/target and must be imported as its own DMA project. New `create_account_archive()` packages one account: its `account_<id>/` tree + the shared `_systeminfo`/summary/log + a **single-account `manifest.json` sliced from the combined manifest with exact per-account `counts`** (which also sidesteps the multi-account aggregate-`counts` quirk for the shipped output). `main()` loops it per account. No `@dma/newrelic-converter`/app change — each per-account archive is a valid single-account archive (one `account_<id>/` dir) parsed unchanged.

### Known issues (still open)

- The **combined** manifest's top-level `counts` aggregation (jq `reduce ({}; . + $a)` does object-merge/last-wins, not numeric sum) remains buggy, but is now moot for shipped output — per-account archives set `counts` exactly. Fix the combined aggregation if it's ever consumed directly.
- PowerShell `.ps1` lacks both the v1.2.0 supplemental types and the v1.3.0 per-account split.

## [1.2.0] - 2026-06-30

### Added

- **Folded the 8 supplemental object types into the primary exporter (sh only); one tarball.** `dma-newrelic-export.sh` now captures the object types that previously required the standalone `nr-supplemental-export.sh`: AI/incident workflows, AI notification destinations, alert muting rules, NRQL drop rules, log parsing (Grok) rules, lookup tables (placeholder pointing at source CSVs), events-to-metrics rules, and entity tags (tag-filtered). They are written to `account_<id>/supplemental/` inside the existing `dma_export_newrelic_<timestamp>.tar.gz` and recorded under a new `supplemental` block in `manifest.json` (per-type options/flags, per-account `statistics`, flattened `counts`, plus the `entity_tag_filter`). Opt in consistently with the core types: `--all` now captures these 8 along with the 5 core types (so `--all` = the full migration corpus), `--supplemental` enables the whole group, and per-type `--ai-workflows` / `--ai-destinations` / `--muting-rules` / `--drop-rules` / `--log-configs` / `--lookup-tables` / `--events-to-metrics` / `--entity-tags` enable one each; the matching `--no-<type>` and `--no-supplemental` flags subtract from `--all`. New `--tag-key` / `--tag-value` flags control the entity-tag filter (default `team=migration`).
- A new `nerdgraph_query_vars(query, variables)` helper (variables-capable sibling of the existing single-arg `nerdgraph_query`, reusing the same `$GRAPHQL_ENDPOINT`, retry constants, and logging) plus an `account_scoped_query(account_id, body)` string builder support the parameterized supplemental queries. The original single-arg `nerdgraph_query` — the live core-export path — is unchanged.

### Removed

- **`nr-supplemental-export.sh` deleted** — its 8 extractors (v0.2.0) are now part of the primary exporter, so the migration corpus comes from a single script and a single archive. The app's embedded-scripts sync config no longer references it.

### Notes

- The PowerShell port (`dma-newrelic-export.ps1`) does **not** yet include the 8 supplemental object types — that parity work is a separate follow-up.

### Known issues (to fix)

- **🐞 `manifest.json` top-level `counts` aggregate emits all-zeros on real multi-account exports** — both the core `counts` (`dashboards`/`alert_policies`/`synthetic_monitors`/…) **and** the new `supplemental.counts`. Verified on `dma_export_newrelic_20260630T193523Z` (6 accounts): the per-account `statistics` / `supplemental.statistics` blocks are **correct** (e.g. 431 dashboards, 607 synthetics, 522 policies; 440 AI workflows, 572 notification destinations across accounts), but every `counts` value is `0`. The roll-up that should sum `statistics` into `counts` is broken (the core `counts` was already broken pre-combine; the combine's `supplemental.counts` reduce inherits the same problem). **Fix:** populate `counts` by summing the per-account `statistics` (or drop `counts` and have consumers read `statistics`). **Workaround in place downstream:** `dma-newrelic-app` v0.1.90 reads `supplemental.statistics` (summed), not `counts`.

## [1.1.0] - 2026-06-12

### Added

- **`.env` credential support** (sh only). The exporter now loads `NEW_RELIC_USER_API_KEY`, `NEW_RELIC_ACCOUNT_ID`, and `NEW_RELIC_REGION` from a `.env` file (current directory first, then repo root) or from already-exported environment variables. Precedence: CLI flags > process environment > `.env`. The `--api-key` error message now points at the env-var alternative. `.gitignore` gains `.env*` entries so credentials never land in git.
- **`nr-supplemental-export.sh` v0.1.0** — companion extractor covering the 8 NR object types the main exporter does not capture: aiWorkflows (incident routing), notification destinations, muting rules, NRQL drop rules (NR EOL 2026-06-30), log parsing (Grok) rules, lookup tables, events-to-metrics rules, and entity tags. CLI surface mirrors `dma-newrelic-export.sh` for operational consistency.
- **`build-docs.sh`** — pandoc renderer turning `newrelic-export/docs_markdown/*.md` into styled HTML in `newrelic-export/docs_html/` (template and logo tracked; rendered pages git-ignored).

### Fixed

- **`--region` flag now works on macOS default bash (3.2)** (sh only). The argument parser used `REGION="${2^^}"`, a bash 4+ uppercasing expansion that silently does nothing on macOS's `/bin/bash` 3.2, so `--region eu` fell through to the US endpoint. Replaced with a POSIX `tr`-based `to_upper` helper, which the new `NEW_RELIC_REGION` fallback also uses. Verified on bash 3.2.57. Supersedes PR #1 (same fix, different implementation). PowerShell port unaffected (parameter binding is case-insensitive).

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
