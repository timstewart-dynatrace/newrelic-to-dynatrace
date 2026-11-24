# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **`newrelic-export/breadth-test/`: export-breadth test build (proposed v1.4.0)**, built on official v1.3.10. It adds alert conditions from every source product (via `asNrqlConditionsSearch`), compound conditions, legacy REST alert channels (redacted, attributed by policy link), step and script content, private locations, secure credential names, monitor downtimes, and 5 supplemental types (log data-partition rules, log obfuscation, pipeline cloud rules, key transactions, browser applications). Verified end to end on a test account. The main `newrelic-export/dma-newrelic-export.sh` is unchanged.

- **`agent-directives/`**: self-contained briefs for applying staging fixes to the official `Dynatrace-Customer-Success` repos (the exporter and the DMA app), with an ordered index. The first two cover v1.3.7 (alert terms) and v1.3.8 (dashboard variables and workload definitions). Docs only; no script change.

- **`nr-supplemental-export.sh` v0.2.0 — `.env` credential support**, ported from the main exporter: loads `NEW_RELIC_USER_API_KEY` / `NEW_RELIC_ACCOUNT_ID` / `NEW_RELIC_REGION` from a `.env` file (current directory first, then repo root) with precedence CLI flags > exported environment > `.env`. Usage text updated (env section now documents the `.env` file and comma-separated account IDs).

### Fixed

- **`nr-supplemental-export.sh`: `NEW_RELIC_REGION` was dead code** — `REGION` is initialized to `US`, so the `[[ -z "$REGION" ]]` env fallback could never fire; the env var the usage text advertised was silently ignored. Now applied whenever `--region` is not passed explicitly (`REGION_EXPLICIT` flag, same pattern as the main script).
- **`nr-supplemental-export.sh`: lowercase region rejected** — `--region eu` failed the case-sensitive `US|EU` validation. Region input is now uppercased via the same POSIX `to_upper` helper as the main script (bash 3.2-safe). Verified on bash 3.2.57.

- **`README-NEWRELIC.md` prerequisites corrected — jq, not python3** (docs only, no script change). The detailed setup guide carried over dynabridge-era instructions telling users to install python3 3.6+ and bash 5; the script actually requires jq and targets bash 3.2. Prerequisites table now lists bash 3.2+/curl/jq/tar with install commands, the NerdGraph example pipes to `jq .` instead of `python3 -m json.tool`, and troubleshooting covers `command not found: jq` plus the CRLF auto-fix instead of the obsolete python3/bash-5 entries. The root `README.md` was already correct. (Redone from abandoned-branch commit `6e62f43`, archived at `archive/feature-parity-with-splunk`.)

## [1.3.8] - 2026-11-07

### Fixed

- **🔴 Dashboard variables were not exported.** The `DashboardEntity` selection had no `variables` field. Widget queries kept their `{{name}}` placeholders, but the archive had no definitions to resolve them against. The selection now includes `variables` with every `DashboardVariable` field: `name title type isMultiSelection replacementStrategy`, `defaultValues { value { string } }`, `items { title value }`, `nrqlQuery { accountIds query }` and `options { excluded hiddenOnVariablesBar ignoreTimeRange showApplyAction }`. The dashboard-level `description` is now selected too.
- **🔴 Workload definitions were not exported.** `WorkloadEntity` returns metadata only. Membership and health rules live on `account.workload.collections`, which the exporter never queried, so every workload arrived with no entity search queries, no static entities and no status rules. A third phase now queries the account's collections and merges these fields into each workload by `guid`:
  - `description`
  - `entitySearchQueries [{query}]`
  - `entityGuids` (from `entities[].guid`)
  - `scopeAccounts`
  - `statusConfig`: automatic rules and rollups, plus static statuses

  The field names match what `@dma/newrelic-converter` already reads (`NRWorkload.entitySearchQueries`, `entityGuids`, `description`). If the definitions query fails, the exporter logs a warning and still writes the metadata.

  **Verified against NerdGraph** on test account 8018100, with both the `.sh` and the `.ps1` (`.ps1` v1.0.4), and identical output from each:
  - 90 dashboards exported; the two with variables carry all their definitions (3 on the templated dashboard: an NRQL multi-select, an ENUM and a STRING `IDENTIFIER`)
  - all 5 workloads carry 1 entity search query and 5 automatic status rules
  - the converter now passes the workload query and description through; previously both were missing

### Changed

- `EXPORT-SCHEMA.md`: the dashboards section documents `description` and `variables`. The workloads section had shown an `entitySearchQuery` string that the exporter never produced and the converter never read; it now documents `entitySearchQueries`, `entityGuids`, `description`, `scopeAccounts` and `statusConfig`.

### Known issues

- `.ps1` `-All` / `-ServiceLevels` still fail at service levels (the pre-v1.3.3 `account.serviceLevel` shape). This is unchanged from v1.3.7; use `-Dashboards -Alerts -Synthetics -Workloads` on Windows until the port lands.

## [1.3.7] - 2026-11-05

### Fixed

- **🔴 Alert conditions exported with no thresholds.** The `nrqlConditionsSearch` query selected only `id name description enabled entityGuid policyId nrql expiration`. It never selected `type`, `terms`, `signal`, `runbookUrl` or `violationTimeLimitSeconds`, although `EXPORT-SCHEMA.md` documented all of them. Downstream, every condition read as `threshold: null`. `@dma/newrelic-converter` fell back to threshold `0`, a 60 s duration and the CRITICAL priority (`AlertConverter.ts:134-136`). Its alert-pool routing (`alertPool.ts:conditionIntervalMinutes`) never saw `signal.aggregationWindow`, so every condition defaulted to a Davis anomaly detector.

  The query now selects all five fields, plus `baselineDirection` for baseline conditions and `expectedGroups` / `openViolationOnGroupOverlap` for outlier conditions (inline fragments).

  **Verified against NerdGraph** on test account 8018100 (47 conditions: 42 static, 5 baseline):
  - the top-level `terms` selection is accepted for every condition type, so no per-type fragments are needed for it
  - all 47 conditions now export `terms`, with 0 null thresholds
  - all 47 export `signal.aggregationWindow`
  - all 5 baselines export `baselineDirection`

  The additive fields need no `ArchiveParser` change: `normalizeCondition()` in `alertAssembly.ts` already maps `type`, `terms`, `signal` and `violationTimeLimitSeconds`.

  ⚠️ **Downstream consequence:** a baseline condition's `terms[].threshold` is a number of standard deviations. A converter that treats it as a static threshold will produce a wrong detector. One test-account example is LOWER_ONLY "Throughput drop anomaly", which would become `ABOVE 4`.

- **🔴 `dma-newrelic-export.ps1` did not parse (v1.0.2).** Six `Log-Debug` strings wrote `"$page:"` / `"$batchNum:"`. PowerShell reads `$name:` as a scope-qualified variable, so the whole script failed with a `ParserError` before running anything. Now written as `${page}:` / `${batchNum}:` (`.ps1` v1.0.3). Verified with `pwsh` 0 parse errors and a live run that exports 47 conditions with terms.

### Known issues

- **`.ps1` service-level export still fails.** It queries `account.serviceLevel`, which NerdGraph rejects ("Cannot query field serviceLevel on type Account"; the bash script moved to the entity-based shape in v1.3.3). With `-All` or `-ServiceLevels`, the script throws after the retries (`The property 'Count' cannot be found`) and writes no archive. `-Dashboards -Alerts -Synthetics -Workloads` runs complete.

## [1.3.6] - 2026-08-10

### Fixed

- **🔴 Synthetic monitors on PRIVATE locations still exported with empty `locations`.** v1.3.4 lifted the `publicLocation` tag into a `locations` array, which was correct but incomplete: New Relic records run locations under **two** tag keys, and v1.3.4 read only one. On real customer data this covered **79 of 616 monitors (12.8%)** — every one of the other 537 carried a `privateLocation` tag instead, so the exact symptom v1.3.4 set out to fix persisted at customer scale under a different key. (v1.3.4 looked correct because the test accounts it was verified against are public-location-only: 9/9, 6/6, 1/1.)

  `export_synthetics_for_account()` now lifts **both** keys into `locations: [{label, type}]`, public entries first, then private. Re-derived against the real archives: **616 of 616 monitors (100%)** now carry usable locations, including the one monitor that legitimately runs from both a public and a private location.

  The new `type` discriminator (`"public"` / `"private"`) is additive — existing consumers reading only `.label` (`@dma/newrelic-converter`'s `SyntheticConverter.ts:50`) are unaffected. It exists because the two are **not** interchangeable downstream: a public label can be remapped to a Dynatrace public location at publish time (`SyntheticApiMapper.ts`), whereas a private NR location names a customer-hosted minion with no Dynatrace public equivalent and must be mapped to a DT private synthetic location the customer selects. Publishing a private-location monitor still needs that mapping decision — this change makes the requirement visible instead of silently emitting an unrunnable monitor.

### Changed

- **The header banner now carries the version, and can no longer drift silently.** The banner comment is what a human reads when they open the file, but it was hand-maintained separately from `SCRIPT_VERSION` and showed **v1.3.3 for the entire v1.3.4 release**. The banner now has an explicit `Version: vX.Y.Z` line, and the script compares it to `SCRIPT_VERSION` at startup, warning on stderr if they disagree. Deliberately non-fatal — a stale banner must never block a customer's export.

## [1.3.5] - 2026-08-10

### Fixed

- **🔴 `entitySearch` pagination never advanced past page 1 — dashboards, synthetic monitors, workloads and service levels all silently truncated at 200 per account.** The pagination cursor was passed as an argument to `entitySearch(query: …, cursor: …)`, but NerdGraph accepts the cursor on the nested **`results(cursor:)`** field, not on `entitySearch` itself. The loop therefore read a `nextCursor` it could never use, and exited after one page. **Nothing reported an error** — the collectors logged `Exported 200 dashboards` as a success, so the truncation was invisible in both the log and the archive.

  **How it was caught (2026-08-10):** two unrelated accounts in a customer export reported *exactly* 200 dashboards **and** *exactly* 200 synthetic monitors, while the alert collectors in this same script — which put the cursor in the correct position (`policiesSearch(cursor:)`, `nrqlConditionsSearch(cursor:)`) — returned 336/174 policies and 2,289/2,156 NRQL conditions with no cap. Four round numbers across two accounts and two asset types is not a coincidence; the working alert path was the control.

  **Impact:** any account with more than 200 of a given asset type exported an incomplete archive, and every downstream conversion/deploy-rate metric computed on such an archive used a truncated denominator. **Re-export any account that reported exactly 200 of anything.**

  Fixed in all four collectors — `export_dashboards_for_account` (`:525`), `export_synthetics_for_account` (`:787`), `export_workloads_for_account` (`:905`), `export_service_levels_for_account` (`:1017`). The three that previously ignored a failed query now `log_error` and stop with an explicit **"export is INCOMPLETE"** rather than treating an API failure as a clean end-of-pagination (service levels already did this).

### Known issues

- **`export_entity_tags` has the same truncation, unfixed.** It issues a single `entitySearch` and selects `nextCursor` but has no pagination loop at all, so it caps at one page. Left as-is deliberately: `entity-tags` is one of the 8 `--supplemental` types with zero downstream consumers today (no parsing, no conversion — see the DMA parity backlog), and fixing it means restructuring the function rather than moving an argument. Fix it when supplemental types get real downstream code (M6).
- **The PowerShell port carries the identical bug** — `dma-newrelic-export.ps1` v1.0.2 passes `$cursorArg` to `entitySearch(...)` for dashboards (`:278`) and monitors (`:467`). Not fixed here; the `.ps1` is already behind on supplemental + per-account parity and its in-app download stays hidden until that lands.

## [1.3.4] - 2026-08-07

### Fixed

- **Synthetic monitors export with no usable `locations` field.** `NerdGraph`'s `SyntheticMonitorEntity` has no dedicated locations field — a monitor's run location(s) only ever appear as a `publicLocation` tag (verified live against account 8018100: all 9 monitors carry real location values there, e.g. `["Washington, DC, USA", "Dublin, IE"]`). The export previously wrote `tags` straight through and never lifted this into a proper field, so every exported monitor looked location-less downstream even though the data was present in the archive the whole time — `@dma/newrelic-converter`'s `SyntheticConverter` reads `monitor.locations.map(l => l.label)`, a field this shape never populated. `export_synthetics_for_account()` now post-processes the `tags` array into `locations: [{label: "..."}]` right before writing `monitors.json`, matching the label-based shape the converter already expects (labels get remapped to Dynatrace location IDs at publish time, not export time — see `@dma/newrelic-converter`'s `SyntheticApiMapper.ts`). No GraphQL query change, no new NerdGraph field — the underlying data was already being fetched.

## [1.3.3] - 2026-07-06

### Fixed

- **Service level export: query still failed after the v1.3.1 fix** — `actor.account(id:).serviceLevel` is not a valid field on `Account` at all (confirmed via live NerdGraph introspection against account 8018100: `Cannot query field "serviceLevel" on type "Account"`). Service levels are entities (`type = 'SERVICE_LEVEL'`, `domain = 'EXT'`, concrete GraphQL type `ExternalEntity`) — the entity itself IS the SLI, not a sub-object reachable from the account. Rewrote `export_service_levels_for_account()` to use the same two-phase `entitySearch → entities(guids:)` pattern as `export_dashboards_for_account()`/`export_synthetics_for_account()`/`export_workloads_for_account()`: Phase 1 discovers `SERVICE_LEVEL` entity GUIDs via `entitySearch`; Phase 2 batch-fetches `... on ExternalEntity { serviceLevel { indicators { id name description guid entityGuid createdAt updatedAt events{...} objectives{...} } } }` (introspection confirmed `ServiceLevelDefinition.indicators` is a list — the v1.3.1 query's leaf fields for `events`/`objectives`/`timeWindow.rolling` were already correctly shaped; only the top-level path and one nesting level were wrong). Validated live: account 8018100's 5 real SLOs now export correctly with intact `events` + `objectives`.

## [1.3.2] - 2026-07-06

### Fixed

- **`usage()`/`--help` printed literal `\033[1m` escape codes instead of bold/color text.** The `RED`/`GREEN`/`YELLOW`/`BLUE`/`CYAN`/`WHITE`/`GRAY`/`NC`/`BOLD` variables were defined with single-quoted strings (`RED='\033[0;31m'`) — that stores the four literal characters `\`, `0`, `3`, `3`, not a real ESC byte. `print_color()`/`print_header()` (used everywhere except `usage()`) mask this because they print via `echo -e`, which interprets a literal `\033` as an octal escape. `usage()` prints via a plain `cat <<EOF` heredoc, which does no escape interpretation, so it dumped the raw text. Switched all 9 color variables to ANSI-C quoting (`$'\033[0;31m'`) so they hold a real ESC byte — `cat` now renders correctly, and `echo -e` is unaffected (a real ESC byte passes through untouched). Reported after downloading the script via the DMA New Relic App.

## [1.3.1] - 2026-07-06

### Fixed

- **Service level export: broken GraphQL query.** `export_service_levels_for_account()` requested `events { account { id name } ... }` — the `account` sub-field does not exist on the `events` type in NR's SLI schema, causing a GraphQL schema error (HTTP 200 with `errors` array) on every attempt. Removed the invalid field; all other SLI fields (`validEvents`/`goodEvents`/`badEvents` + `objectives`) are unaffected.
- **Failure masking in `nerdgraph_query()` and `nerdgraph_query_vars()`.** After exhausting retries on repeated GraphQL errors, both functions returned exit code 0 (`return 0`) — indistinguishable from success — so callers wrote `[]` and logged `[OK] 0` even on hard failures. Both now `return 1` (and log `ERROR` instead of `WARN`) so callers can detect and surface the failure. The final-attempt body echo in `nerdgraph_query_vars()` is preserved for diagnostics but now also returns 1.
- **Service level caller now detects query failure.** `export_service_levels_for_account()` checks the return code of `nerdgraph_query` on each page; on failure it logs `ERROR`, writes whatever partial data was collected, and itself returns 1 — preventing the false `[OK] 0 indicators` log line.

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
