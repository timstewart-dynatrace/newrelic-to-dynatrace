# Decision Log

## 2026-04-22 — Use jq instead of python3 for JSON processing

**Chosen:** jq for all JSON in Bash script
**Alternatives:** python3 inline scripts (used in dynabridge-for-newrelic)
**Why:** DMA DataDog export (`dma-datadog-export.sh`) uses jq as the standard. Keeps the ecosystem consistent and eliminates the python3 dependency. jq is widely available (brew/apt) and expressive enough for all JSON operations in the export flow.
**Trade-offs:** jq multiline scripts are less readable than Python for complex logic. Complex manifest generation required careful jq -n construction.
**Revisit if:** A future export type requires JSON transformations too complex for jq (e.g., deep recursive masking).

## 2026-04-22 — Use actor.account.serviceLevel.indicators instead of entity scan

**Chosen:** `actor.account.serviceLevel.indicators` paginated query for SLI export
**Alternatives:** dynabridge-for-newrelic approach: enumerate all entity GUIDs then probe each for `entity.serviceLevel.indicators`
**Why:** The direct indicators query is dramatically more efficient — one paginated API call vs N/25 batched calls for all entities. Discovered via NerdGraph schema exploration.
**Trade-offs:** The direct query may not return SLIs attached to entities outside the account. Edge case for shared SLIs.
**Revisit if:** Customer reports missing SLIs — fall back to entity scan approach.

## 2026-04-22 — Project supersedes dynabridge-for-newrelic

**Chosen:** Create new `newrelic-to-dynatrace` project following DMA naming conventions
**Alternatives:** Rename/restructure dynabridge-for-newrelic in place
**Why:** `dynabridge-for-newrelic` was cloned from the wrong template and carries DynaBridge branding. Creating a fresh project ensures clean DMA conventions throughout (archive name, script names, README format, jq usage).
**Trade-offs:** Existing users of dynabridge-for-newrelic need to migrate. Deprecation notice added to that project.
**Revisit if:** Migration overhead is too high — could re-brand dynabridge in place instead.
