# CLAUDE.md — newrelic-to-dynatrace

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## This Repo

`newrelic-to-dynatrace` holds the **New Relic export scripts** — the first stage of the DMA New Relic pipeline. The scripts in [`newrelic-export/`](newrelic-export/) (`dma-newrelic-export.sh` / `.ps1`) pull the customer's NR configuration via NerdGraph/REST and produce a **`dma_export_newrelic_<timestamp>.tar.gz`** archive (dashboards, alert policies + NRQL conditions, SLOs, synthetics, workloads, the 8 supplemental object types under `supplemental/` + `manifest.json`). That archive is the input consumed downstream by `@dma/newrelic-converter`, `dma-newrelic-app`, and `dma-server`.

**Track context:** this repo implements step 1 of the GOAL in [`dma-workspace/DMA-NEWRELIC/CLAUDE.md`](../dma-workspace/DMA-NEWRELIC/CLAUDE.md) — read that first for the NR-track directives (knowledge persistence, parity mandate, conversion-quality cautions). The DMA platform rules in [`dma-workspace/CLAUDE.md`](../dma-workspace/CLAUDE.md) apply (never commit/push without explicit instruction; `dynatrace-dma`-adjacent security rules — note this repo lives under `timstewart-dynatrace`, not `dynatrace-dma`).

## Key paths

- **Export scripts**: `newrelic-export/dma-newrelic-export.sh` (canonical, **v1.3.10** — emits **one archive per account** [`dma_export_newrelic_<account_id>_<timestamp>.tar.gz`; account = DT-tenant-equivalent → its own DMA project]; folds in the 8 supplemental object types [v1.2.0] formerly in `nr-supplemental-export.sh`; opt in via `--all`/`--supplemental`/`--<type>`), `.ps1` (Windows port, v1.0.6 — **supplemental + per-account parity are pending follow-ups**; service levels use the same entity-based query as bash since v1.0.4, but its other `entitySearch` collectors still pass the cursor on `entitySearch` [the bash v1.3.5 truncation bug]). The standalone `nr-supplemental-export.sh` was removed in v1.2.0.
- **Docs**: `newrelic-export/docs_markdown/` + `docs_html/` (built via `build-docs.sh`)
- **Decisions / history**: `DECISIONS.md`, `CHANGELOG.md`
- Sample archives (`dma_export_newrelic_*.tar.gz`) at the repo root are test fixtures for downstream converter work

## Conventions

- Credentials come from `.env` (NR account/API keys + DT tenant tokens) — **never commit it** (git-ignored since v1.1.0); the bash script loads it natively with precedence CLI flags > process env > `.env` (cwd, then repo root); see `README.md` § Credential Sources
- Version lives in `README.md` header (must match `SCRIPT_VERSION` in the `.sh`); update `CHANGELOG.md` with every script change; tag releases (`vX.Y.Z`, annotated)
- Branch-per-feature (`feature/…`, `fix/…`); `main` is the stable export script customers receive; abandoned work is archive-tagged (`archive/…`), not left as branches
- **Stacked PRs: confirm the base before merging the upper PR.** A PR based on another feature branch keeps that base if it is merged before GitHub retargets it to `main`. v1.3.8 (#5) merged into `fix/ps1-service-levels` 46 s after #4 landed, so the `v1.3.8` tag pointed at code that was not on `main` until a follow-up PR (#6). Before merging or tagging, check `gh pr view <n> --json baseRefName` shows `main`, and that `git merge-base --is-ancestor <tag> origin/main` succeeds.
- **Tag only after the live run.** Each release's test plan includes a live NerdGraph run, and mocked tests do not catch a rejected field. v1.3.8 was tagged before its live run and shipped a workload field NerdGraph does not have (`remainingEntitiesRuleRollup`), so no workload definitions were exported until v1.3.9.
- **Check new NerdGraph fields against the live schema, not the Go client.** With a key in `.env`, introspect the types you select: `{ __type(name:"<Type>") { fields(includeDeprecated:true) { name isDeprecated deprecationReason } } }`. The schema-generated types in `newrelic-client-go` lag NerdGraph: in November 2026 they lacked `DashboardVariableOptions.hiddenOnVariablesBar` and `workload.collections`, both of which are live. One bad field fails the whole query, so put new selections where a failure degrades (a separate query, or a retry without them), never unguarded inside the core dashboard/alert query.
- Export shape changes ripple downstream: `@dma/newrelic-converter`'s `ArchiveParser`/fixtures and the NR app's import path must be checked against any new/renamed archive entry
- **The scripts are embedded in `dma-newrelic-app` for in-app download** (downloaded from the app's **Import page** — there is no standalone Export Scripts page). After every script release here, regenerate the app's embedded copy: `npm run sync-export-scripts` in `dma-newrelic-app`, then commit the regenerated `ui/app/constants/exportScripts.ts`. The sync reads the **sibling main checkout** (`../newrelic-to-dynatrace/newrelic-export`, not a worktree), so fast-forward that checkout to the release first, or set `DMA_NR_EXPORT_DIR`. Use the `Dynatrace-Customer-Success/dma-newrelic-app` checkout, branched from a fresh `origin/main`. Each embed bumps `app.config.json` and adds an app `CHANGELOG.md` entry. Keep the PowerShell card's known-issue text in `scripts/sync-export-scripts.cjs` in step with the `.ps1`.
