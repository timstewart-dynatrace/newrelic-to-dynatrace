# CLAUDE.md — newrelic-to-dynatrace

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## This Repo

`newrelic-to-dynatrace` holds the **New Relic export scripts** — the first stage of the DMA New Relic pipeline. The scripts in [`newrelic-export/`](newrelic-export/) (`dma-newrelic-export.sh` / `.ps1`, plus `nr-supplemental-export.sh`) pull the customer's NR configuration via NerdGraph/REST and produce a **`dma_export_newrelic_<timestamp>.tar.gz`** archive (dashboards, alert policies + NRQL conditions, SLOs, synthetics, workloads + `manifest.json`). That archive is the input consumed downstream by `@dma/newrelic-converter`, `dma-newrelic-app`, and `dma-server`.

**Track context:** this repo implements step 1 of the GOAL in [`dma-workspace/DMA-NEWRELIC/CLAUDE.md`](../dma-workspace/DMA-NEWRELIC/CLAUDE.md) — read that first for the NR-track directives (knowledge persistence, parity mandate, conversion-quality cautions). The DMA platform rules in [`dma-workspace/CLAUDE.md`](../dma-workspace/CLAUDE.md) apply (never commit/push without explicit instruction; `dynatrace-dma`-adjacent security rules — note this repo lives under `timstewart-dynatrace`, not `dynatrace-dma`).

## Key paths

- **Export scripts**: `newrelic-export/dma-newrelic-export.sh` (canonical, v1.1.0 — `.env` credential support, bash 3.2 region fix), `.ps1` (Windows port, v1.0.2), `nr-supplemental-export.sh` (supplemental 8-category extractor, v0.1.0 — shipped in v1.1.0 / tag `v1.1.0`)
- **Docs**: `newrelic-export/docs_markdown/` + `docs_html/` (built via `build-docs.sh`)
- **Decisions / history**: `DECISIONS.md`, `CHANGELOG.md`
- Sample archives (`dma_export_newrelic_*.tar.gz`) at the repo root are test fixtures for downstream converter work

## Conventions

- Credentials come from `.env` (NR account/API keys + DT tenant tokens) — **never commit it** (git-ignored since v1.1.0); the bash script loads it natively with precedence CLI flags > process env > `.env` (cwd, then repo root); see `README.md` § Credential Sources
- Version lives in `README.md` header (must match `SCRIPT_VERSION` in the `.sh`); update `CHANGELOG.md` with every script change; tag releases (`vX.Y.Z`, annotated)
- Branch-per-feature (`feature/…`, `fix/…`); `main` is the stable export script customers receive; abandoned work is archive-tagged (`archive/…`), not left as branches
- Export shape changes ripple downstream: `@dma/newrelic-converter`'s `ArchiveParser`/fixtures and the NR app's import path must be checked against any new/renamed archive entry
- **The scripts are embedded in `dma-newrelic-app` for in-app download** (Export Scripts page). After every script release here, regenerate the app's embedded copy: `npm run sync-export-scripts` in `dma-newrelic-app` (reads this checkout), commit the regenerated `ui/app/constants/exportScripts.ts`
